"""Read the tools/skills exposed by the running Hermes API; no model call or secret in the result."""

import asyncio

import httpx


async def capabilities(url: str, key: str) -> dict:
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    async with httpx.AsyncClient(timeout=10) as client:
        async def listing(kind):
            try:
                response = await client.get(f"{url}/v1/{kind}", headers=headers)
                response.raise_for_status()
                data = response.json().get("data")
                if not isinstance(data, list) or any(not isinstance(row, dict) for row in data):
                    raise ValueError("invalid list")
                return data, None
            except httpx.HTTPStatusError as error:
                return [], f"Hermes ne peut pas lister {kind} (HTTP {error.response.status_code})."
            except (httpx.HTTPError, ValueError, AttributeError):
                return [], f"Liste {kind} indisponible auprès de Hermes."

        tools, skills = await asyncio.gather(listing("toolsets"), listing("skills"))
    # Allowlist fields: upstream diagnostics/configuration never reach the app.
    toolsets = [{"name": str(t.get("name", "")), "label": str(t.get("label") or t.get("name", "")),
                 "enabled": bool(t.get("enabled")), "configured": bool(t.get("configured")),
                 "tools": [name for name in t.get("tools", []) if isinstance(name, str)]}
                for t in tools[0] if isinstance(t.get("tools", []), list)]
    catalog = [{"name": str(s.get("name", "")), "description": str(s.get("description") or ""),
                "category": str(s.get("category") or "")} for s in skills[0]]
    return {"toolsets": toolsets, "skills": catalog, "issues": [error for _, error in (tools, skills) if error]}
