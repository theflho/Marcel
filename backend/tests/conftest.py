"""The server in test mode: fake replies (MARCEL_MOCK), its data in a temporary folder."""

import os
import sys
import tempfile
from pathlib import Path

os.environ.update(MARCEL_MOCK="1", MARCEL_TOKEN="test", MARCEL_MCP_TOKEN="mcp-test", MARCEL_PLANNING_KEY="planning-test",
                  MARCEL_DATA_DIR=tempfile.mkdtemp(prefix="marcel-tests-"),
                  GUARD_DATA_DIR=tempfile.mkdtemp(prefix="guard-tests-"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
