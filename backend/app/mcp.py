"""A small MCP server (Model Context Protocol, "streamable HTTP" transport, JSON answers only), so
Hermes can query Marcel's data instead of guessing from the extracts joined to each mission.

Most tools read. Some act, and say so (readOnlyHint false): create a goal or a routine, remember
a fact, and Marcel's code tools (change his code, open and merge a pull request). None deletes
anything. Hermes reaches it on the internal Docker network at http://marcel-api:8000/mcp with its
own key (MARCEL_MCP_TOKEN); everything stops during the emergency stop.
"""

import inspect
import json
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

log = logging.getLogger("marcel.mcp")

PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")
SERVER_INFO = {"name": "marcel", "version": "1.0"}
INSTRUCTIONS = ("Données et mains de Marcel : planning RMA (missions passées sur 45 jours et à venir), offres de "
                "recrutement, comptes rendus du robot RMA, réponses passées, mémoire, objectifs, idées et routines "
                "(lire et créer), son propre code (lire, modifier, proposer, CI, fusionner, annuler : le déploiement suit) "
                "et les journaux du serveur. "
                "À utiliser plutôt que deviner ou chercher dans le terminal.")
# A tool's answer is cut beyond this, to keep the model's context sane.
MAX_RESULT_CHARS = 12_000


@dataclass
class Tool:
    name: str
    description: str
    schema: dict
    run: Callable[[dict], str | Awaitable[str]]
    read_only: bool = True


class MCPServer:
    def __init__(self) -> None:
        self.tools: dict[str, Tool] = {}

    def tool(self, name: str, description: str, properties: dict | None = None, required: tuple = (),
             read_only: bool = True):
        """Registers a function (or coroutine) taking the call's arguments (a dict), returning text."""
        schema = {"type": "object", "properties": properties or {}, "required": list(required)}

        def register(run):
            self.tools[name] = Tool(name, description, schema, run, read_only)
            return run
        return register

    async def handle(self, message: dict) -> dict | None:
        """One JSON-RPC message → its response, or None for a notification."""
        method, params, msg_id = message.get("method"), message.get("params") or {}, message.get("id")
        if msg_id is None:
            return None  # notifications/initialized, notifications/cancelled…
        try:
            result = await self._dispatch(method, params)
        except RPCError as error:
            return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": error.code, "message": str(error)}}
        return {"jsonrpc": "2.0", "id": msg_id, "result": result}

    async def _dispatch(self, method: str | None, params: dict) -> dict:
        if method == "initialize":
            asked = params.get("protocolVersion")
            return {"protocolVersion": asked if asked in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0],
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": SERVER_INFO, "instructions": INSTRUCTIONS}
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": [{"name": t.name, "description": t.description, "inputSchema": t.schema,
                               "annotations": {"readOnlyHint": t.read_only, "destructiveHint": False,
                                               "openWorldHint": not t.read_only and t.name.startswith("marcel_code")}}
                              for t in self.tools.values()]}
        if method == "tools/call":
            tool = self.tools.get(params.get("name", ""))
            if not tool:
                raise RPCError(-32602, f"Outil inconnu : {params.get('name')}")
            arguments = params.get("arguments") or {}
            try:
                text = tool.run(arguments)
                if inspect.isawaitable(text):
                    text = await text
                is_error = False
            except ToolError as error:
                text, is_error = str(error), True
            except Exception:
                log.exception("MCP tool %s failed with %s", tool.name, json.dumps(arguments)[:200])
                text, is_error = "L'outil a échoué côté serveur Marcel.", True
            if len(text) > MAX_RESULT_CHARS:
                text = text[:MAX_RESULT_CHARS] + "\n… (coupé : précise la demande)"
            return {"content": [{"type": "text", "text": text}], "isError": is_error}
        raise RPCError(-32601, f"Méthode inconnue : {method}")


class RPCError(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code


class ToolError(Exception):
    """A wrong argument or an unavailable piece of data: told to the model, not a crash."""
