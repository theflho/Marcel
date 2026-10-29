"""Native tool previews distinguish dispatch wrappers and keep their display/redaction contract."""

import importlib.util
from pathlib import Path
from types import SimpleNamespace


def progress_module():
    path = Path(__file__).parents[1] / "deploy/hermes-plugins/marcel/progress.py"
    spec = importlib.util.spec_from_file_location("progress_previews", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_wrapper_preview_names_the_real_tool_without_dumping_arguments():
    builders = {}
    def preview(name, args, max_len=None):
        if name in builders:
            return builders[name](args, max_len)
        return args.get("path")  # a stand-in for Hermes' existing safe preview, never raw arguments
    display = SimpleNamespace(_PREVIEW_BUILDERS=builders, build_tool_preview=preview)
    install = progress_module().install_progress_previews
    assert install(display) and not install(display)
    text = preview("tool_call", {"calls": [
        {"name": "read_file", "arguments": {"path": "/work/report.md", "password": "secret-never-display"}},
        {"name": "mcp__marcel__marcel_planning", "arguments": {"headers": {"Authorization": "secret-never-display"}}},
        {"name": "tool_call", "arguments": {"name": "tool_call"}},
        {"name": "invalid\nname", "arguments": {}}]})
    assert text.splitlines() == ["read_file · /work/report.md", "mcp__marcel__marcel_planning", "tool_call"]
    assert "secret" not in text
    assert len(preview("tool_call", {"name": "read_file", "arguments": {"path": "x" * 200}}, 40)) == 40
    assert preview("tool_describe", {"names": ["read_file", "mcp__marcel__marcel_planning"]}).splitlines() == [
        "read_file", "mcp__marcel__marcel_planning"]
    text = preview("mcp__marcel__marcel_code_remplacer", {"chemin": "backend/app/main.py", "debut": 10,
        "ancien": "secret-before", "nouveau": "secret-after", "password": "secret-password"})
    assert text == "chemin=backend/app/main.py · debut=10" and "secret" not in text


def test_installer_preserves_future_native_preview_builders():
    existing = lambda args, limit: "native builder"
    display = SimpleNamespace(_PREVIEW_BUILDERS={"tool_call": existing, "tool_describe": existing})
    install = progress_module().install_progress_previews
    assert install(display) and not install(display)
    assert display._PREVIEW_BUILDERS["tool_call"] is existing
    assert not progress_module().install_progress_previews(SimpleNamespace())
