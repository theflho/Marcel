"""The user's budget change persists, controls spending, and stays out of agent tools."""

import time

import httpx
import pytest
from fastapi.testclient import TestClient

from app import llm_guard as guard, main

AUTH = {"Authorization": "Bearer test"}
client = TestClient(main.app)


@pytest.fixture
def budget(monkeypatch, tmp_path):
    store = guard.Usage(tmp_path / "guard.db")
    monkeypatch.setattr(guard, "usage", store)
    monkeypatch.setattr(guard, "DAILY_TOKENS", 2_000_000)
    monkeypatch.setattr(guard, "CHECKS_SHARE", 0.6)
    monkeypatch.setattr(guard, "KEYS", {"backend-key": "marcel", "agent-key": "hermes", "checks-key": "checks"})
    monkeypatch.setattr(main, "GUARD_URL", "http://guard")
    monkeypatch.setattr(main, "MEMORY_LLM_KEY", "backend-key")
    monkeypatch.setattr(main, "_guard_cache", (0.0, None))
    real_client = httpx.AsyncClient
    monkeypatch.setattr(main.httpx, "AsyncClient", lambda **kw: real_client(transport=httpx.ASGITransport(app=guard.app), **kw))
    return store


def test_app_change_persists_and_updates_health_without_resetting_spending(budget, tmp_path):
    budget.add("hermes", prompt=700, completion=300, requests=1)
    # An already cached health report must immediately reflect the saved budget.
    main._guard_cache = (time.monotonic(), budget.report())
    assert client.get("/v1/tokens/budget", headers=AUTH).json() == {"today": 1000, "budget": 2_000_000}
    response = client.put("/v1/tokens/budget", headers=AUTH, json={"budget": 1500})
    assert response.status_code == 200 and response.json() == {"today": 1000, "budget": 1500}
    assert client.get("/health", headers=AUTH).json()["tokens"] == response.json()
    assert guard.Usage(tmp_path / "guard.db").daily_budget() == 1500
    assert budget.spent() == 1000 and budget.report()["clients"]["hermes"]["requests"] == 1
    assert budget.report()["checks_budget"] == 900
    assert guard.refusal("checks") and guard.refusal("hermes") is None
    assert client.put("/v1/tokens/budget", headers=AUTH, json={"budget": 500}).status_code == 200
    assert guard.refusal("hermes")
    guard_client = TestClient(guard.app)
    assert guard_client.post("/v1/chat/completions", headers={"Authorization": "Bearer agent-key"},
                             json={"messages": []}).status_code == 429
    assert client.put("/v1/tokens/budget", headers=AUTH, json={"budget": 5000}).status_code == 200
    assert guard.refusal("hermes") is None and guard.refusal("checks") is None


@pytest.mark.parametrize("value", [0, -1, 1_000_000_001, 1.5, True, "2000", None])
def test_invalid_limits_are_refused_by_both_layers(budget, value):
    assert client.put("/v1/tokens/budget", headers=AUTH, json={"budget": value}).status_code == 422
    guard_client = TestClient(guard.app)
    assert guard_client.put("/budget", headers={"Authorization": "Bearer backend-key"},
                            json={"daily_tokens": value}).status_code == 422
    assert budget.daily_budget() == 2_000_000


def test_only_the_user_app_and_backend_key_can_change_the_budget(budget):
    for headers in [{}, {"Authorization": "Bearer mcp-test"}]:
        assert client.get("/v1/tokens/budget", headers=headers).status_code == 401
        assert client.put("/v1/tokens/budget", headers=headers, json={"budget": 5000}).status_code == 401
    guard_client = TestClient(guard.app)
    assert guard_client.put("/budget", json={"daily_tokens": 5000}).status_code == 401
    for key in ["agent-key", "checks-key"]:
        headers = {"Authorization": f"Bearer {key}"}
        assert guard_client.get("/usage", headers=headers).status_code == 200
        assert guard_client.put("/budget", headers=headers, json={"daily_tokens": 5000}).status_code == 403
    assert budget.daily_budget() == 2_000_000


def test_guard_unavailable_reports_failure_without_a_fake_success(budget, monkeypatch):
    def unavailable(**kwargs):
        raise httpx.ConnectError("private upstream configuration")
    monkeypatch.setattr(main.httpx, "AsyncClient", unavailable)
    assert client.get("/v1/tokens/budget", headers=AUTH).status_code == 503
    response = client.put("/v1/tokens/budget", headers=AUTH, json={"budget": 5000})
    assert response.status_code == 502 and "private" not in response.text
    assert budget.daily_budget() == 2_000_000
    monkeypatch.setattr(main, "GUARD_URL", "")
    assert client.put("/v1/tokens/budget", headers=AUTH, json={"budget": 5000}).status_code == 503


def test_daily_counter_rollover_keeps_the_selected_budget(budget, monkeypatch):
    monkeypatch.setattr(guard.Usage, "today", staticmethod(lambda: "2026-10-29"))
    budget.add("hermes", prompt=1000)
    budget.set_daily_budget(7000)
    monkeypatch.setattr(guard.Usage, "today", staticmethod(lambda: "2026-10-30"))
    assert budget.report()["tokens"] == 0 and budget.report()["budget"] == 7000
