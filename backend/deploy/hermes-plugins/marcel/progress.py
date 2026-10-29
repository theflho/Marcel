"""Readable previews for Hermes' lazy tool wrappers, using its existing argument redaction."""

import re

TOOL_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_.:-]{0,199}$")


def install_progress_previews(display=None) -> bool:
    if display is None:
        from agent import display
    builders = getattr(display, "_PREVIEW_BUILDERS", None)
    if not isinstance(builders, dict):
        return False

    def clipped(text, limit):
        # Keep bounded output even for an unlimited preview request; explicit Hermes caps stay respected.
        limit = limit or 2000
        return text if len(text) <= limit else text[:limit - 1] + "…"

    def calls_preview(args, limit):
        entries = args.get("calls")
        entries = entries if isinstance(entries, list) else [args]
        lines = []
        for entry in entries[:20]:
            if not isinstance(entry, dict):
                continue
            name = entry.get("name")
            if not isinstance(name, str) or not TOOL_NAME.fullmatch(name):
                continue
            arguments = entry.get("arguments")
            # Never serialize arguments wholesale, or recurse through another wrapper. Let Hermes
            # redact and select its normal display argument for the actual tool (path, search…).
            preview = display.build_tool_preview(name, arguments, max_len=240) if (
                isinstance(arguments, dict) and name not in {"tool_call", "tool_search", "tool_describe"}) else None
            lines.append(name + (" · " + preview if preview else ""))
        return clipped("\n".join(lines), limit) if lines else None

    def describe_preview(args, limit):
        names = args.get("names")
        names = [names] if isinstance(names, str) else names
        if not isinstance(names, list):
            return None
        return clipped("\n".join(n for n in names[:20] if isinstance(n, str) and TOOL_NAME.fullmatch(n)), limit) or None

    def app_target_preview(args, limit):
        # French parameter names are not in Hermes' generic primary-argument table. Only show
        # identifiers/locations, never file contents, replacement text, headers or credentials.
        parts = [f"{key}={str(args[key])[:240]}" for key in
                 ("chemin", "dossier", "debut", "fin", "numero", "bot", "statut", "etat")
                 if isinstance(args.get(key), (str, int)) and not isinstance(args.get(key), bool)]
        return clipped(" · ".join(parts), limit) if parts else None

    extra = {"tool_call": calls_preview, "tool_describe": describe_preview}
    for tool in ("code_lire", "code_ecrire", "code_remplacer", "code_chercher", "code_fichiers", "code_ci",
                 "code_reprendre", "code_fusionner", "code_annuler", "planning", "offres", "historique", "passages"):
        extra[f"mcp__marcel__marcel_{tool}"] = app_target_preview
        extra[f"marcel_{tool}"] = app_target_preview
    changed = False
    for name, builder in extra.items():
        # Preserve future Hermes versions that already provide these builders; registration is idempotent.
        if name not in builders:
            builders[name] = builder
            changed = True
    return changed
