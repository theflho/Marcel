"""The actual Chat Completions wire contract: key scopes memory, id resumes the transcript."""

import asyncio
import json

import httpx
import pytest

from app import main
from app.hermes_sessions import HermesSessions


CONVERSATION = "C0FFEE00-0000-4000-8000-0000000000D1"


@pytest.fixture
def hermes(monkeypatch, tmp_path):
    real_client = httpx.AsyncClient
    calls = []
    replies = []

    async def respond(request):
        await asyncio.sleep(0)  # let overlapping turns reach the transport while the first is pending
        body = json.loads(request.content)
        calls.append((request, body))
        if replies:
            return replies.pop(0)
        return answer(request.headers.get("X-Hermes-Session-Id", f"api-{len(calls)}"))

    transport = httpx.MockTransport(respond)
    monkeypatch.setattr(main, "hermes_sessions", HermesSessions(tmp_path / "marcel.db"))
    monkeypatch.setattr(main.httpx, "AsyncClient", lambda **kwargs: real_client(transport=transport, **kwargs))
    monkeypatch.setattr(main, "CHECK_HERMES_URL", "http://checks:8642")
    return calls, replies, tmp_path / "marcel.db"


def answer(session_id=None, text="Réponse.", *, done=True):
    chunk = {"choices": [{"delta": {"content": text}}]}
    stream = "data: " + json.dumps(chunk) + "\n\n" + ("data: [DONE]\n\n" if done else "")
    return httpx.Response(200, headers={"X-Hermes-Session-Id": session_id} if session_id else {}, text=stream)


def chat(conversation=CONVERSATION, **extra):
    return main.ChatRequest(conversation_id=conversation, messages=[
        main.Message(role="user", content="Je prépare mon voyage."),
        main.Message(role="assistant", content="Pour quelle date ?"),
        main.Message(role="user", content="Le 15 novembre.")], **extra)


def followup(**extra):
    request = chat(**extra)
    request.messages += [main.Message(role="assistant", content="Entendu."),
                         main.Message(role="user", content="Et pour le retour ?")]
    return request


async def collect(request, **kwargs):
    return [item async for item in main.hermes_stream(request, "model", "Consignes.", key="test-key", **kwargs)]


def test_bootstrap_then_resume_last_message_even_after_restart(hermes, monkeypatch):
    calls, _, path = hermes

    async def go():
        request = chat()
        assert await collect(request) == ["Réponse."]
        # A backend restart retains the transport id, not a copy of Hermes' transcript.
        monkeypatch.setattr(main, "hermes_sessions", HermesSessions(path))
        request.messages += [main.Message(role="assistant", content="Entendu."),
                             main.Message(role="user", content="Et pour le retour ?")]
        await collect(request)

    asyncio.run(go())
    first, second = calls
    assert first[0].headers["X-Hermes-Session-Key"] == CONVERSATION
    assert "X-Hermes-Session-Id" not in first[0].headers
    assert [m["role"] for m in first[1]["messages"]] == ["system", "user", "assistant", "user"]
    assert "user" not in first[1]
    assert second[0].headers["X-Hermes-Session-Id"] == "api-1"
    assert second[0].headers["X-Hermes-Session-Key"] == CONVERSATION
    assert second[1]["messages"] == [{"role": "system", "content": "Consignes."},
                                       {"role": "user", "content": "Et pour le retour ?"}]


def test_conversations_with_the_same_opening_do_not_share_a_fingerprint(hermes):
    calls, _, _ = hermes

    async def go():
        await collect(chat())
        await collect(chat(conversation="ANOTHER-CONVERSATION"))

    asyncio.run(go())
    assert calls[0][1]["messages"][0] != calls[1][1]["messages"][0]
    assert all("X-Hermes-Session-Id" not in request.headers for request, _ in calls)


def test_profiles_and_fallback_never_share_session_ids(hermes, monkeypatch):
    calls, _, _ = hermes

    async def profile_url(bot):
        return f"{main.HERMES_URL}/p/marcel-{bot}"

    monkeypatch.setattr(main, "profile_url", profile_url)

    async def go():
        await collect(chat(assistant="planning"), profile="planning")
        await collect(chat(assistant="veille"), profile="veille")
        await collect(followup(assistant="planning"), profile="planning")

        async def fallback(bot):
            return main.HERMES_URL

        monkeypatch.setattr(main, "profile_url", fallback)
        await collect(chat(assistant="planning"), profile="planning")
        await collect(chat())

    asyncio.run(go())
    assert str(calls[0][0].url).startswith(f"{main.HERMES_URL}/p/marcel-planning/")
    assert calls[2][0].headers["X-Hermes-Session-Id"] == "api-1"
    assert all("X-Hermes-Session-Id" not in calls[i][0].headers for i in (0, 1, 3, 4))
    assert calls[3][1]["messages"][0] != calls[4][1]["messages"][0]


@pytest.mark.parametrize("case", ["private", "protected", "model", "check"])
def test_protected_private_and_check_requests_stay_stateless(hermes, case):
    calls, _, _ = hermes
    request = chat(private=case == "private")
    target = {"protected": f"{main.HERMES_URL}/p/{main.PROTECTED_PROFILE}",
              "model": "http://guard:4000", "check": main.CHECK_HERMES_URL}.get(case, main.HERMES_URL)

    async def go():
        await collect(request, url=target)
        await collect(request, url=target)

    asyncio.run(go())
    for sent, body in calls:
        assert "X-Hermes-Session-Key" not in sent.headers and "X-Hermes-Session-Id" not in sent.headers
        assert len(body["messages"]) == 4


def test_goal_checks_never_resume_even_when_checks_url_defaults_to_main(hermes, monkeypatch):
    calls, _, _ = hermes
    monkeypatch.setattr(main, "CHECK_HERMES_URL", main.HERMES_URL)

    async def go():
        await collect(chat(conversation="goal-123"))
        await collect(chat(conversation="goal-123"))

    asyncio.run(go())
    assert all("X-Hermes-Session-Id" not in request.headers for request, _ in calls)


def test_hermes_without_api_auth_keeps_the_full_history(hermes):
    calls, _, _ = hermes

    async def go():
        for request in (chat(), followup()):
            assert [item async for item in main.hermes_stream(request, "model", key="")] == ["Réponse."]

    asyncio.run(go())
    assert len(calls[-1][1]["messages"]) == 5
    assert all("X-Hermes-Session-Key" not in request.headers for request, _ in calls)


def test_unavailable_session_header_or_incomplete_stream_keeps_bootstrap_history(hermes):
    calls, replies, _ = hermes
    replies.extend([answer(), answer("api-incomplete", done=False)])

    async def go():
        await collect(chat())
        with pytest.raises(main.MissionError, match="incomplète"):
            await collect(chat())
        await collect(chat())

    asyncio.run(go())
    assert all("X-Hermes-Session-Id" not in request.headers for request, _ in calls)
    assert all(len(body["messages"]) == 4 for _, body in calls)


def test_overlapping_turns_wait_for_the_first_session_id(hermes):
    calls, _, _ = hermes

    async def go():
        await asyncio.gather(collect(chat()), collect(followup()))

    asyncio.run(go())
    assert "X-Hermes-Session-Id" not in calls[0][0].headers
    assert calls[1][0].headers["X-Hermes-Session-Id"] == "api-1"


def test_resumed_turn_keeps_new_attachments_but_does_not_reopen_old_ones(hermes, monkeypatch):
    calls, _, _ = hermes
    opened = []

    def load(file_id):
        opened.append(file_id)
        return {"mime_type": "image/png"}, b"image-bytes"

    monkeypatch.setattr(main, "load_file", load)

    async def go():
        request = chat()
        request.messages[0].attachments = ["old"]
        await collect(request)
        opened.clear()
        request.messages += [main.Message(role="assistant", content="Entendu."),
                             main.Message(role="user", content="Et pour le retour ?")]
        request.messages[-1].attachments = ["new"]
        await collect(request)

    asyncio.run(go())
    assert opened == ["new"]
    parts = calls[-1][1]["messages"][-1]["content"]
    assert parts[0] == {"type": "text", "text": "Et pour le retour ?"}
    assert parts[1]["image_url"]["url"].startswith("data:image/png;base64,")


def test_browser_guard_still_stops_the_stream_without_recording_a_success(hermes):
    calls, replies, _ = hermes
    chunk = {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "t1",
              "function": {"name": "browser_navigate", "arguments": "{}"}}]}}]}
    replies.append(httpx.Response(200, headers={"X-Hermes-Session-Id": "api-blocked"},
                                 text="data: " + json.dumps(chunk) + "\n\ndata: [DONE]\n\n"))

    async def go():
        with pytest.raises(main.MissionError, match="Navigateur"):
            await collect(chat(), browser=False)
        await collect(chat())

    asyncio.run(go())
    assert "X-Hermes-Session-Id" not in calls[-1][0].headers


@pytest.mark.parametrize("change", ["edit", "regenerate", "trim"])
def test_edited_or_regenerated_messages_start_a_new_transcript(hermes, change):
    calls, _, _ = hermes

    async def go():
        await collect(chat())
        request = chat() if change == "regenerate" else followup()
        if change == "edit":
            request.messages[0].content = "Je prépare un autre voyage."
        if change == "trim":
            request.messages = request.messages[-1:]
        await collect(request)

    asyncio.run(go())
    assert "X-Hermes-Session-Id" not in calls[-1][0].headers
    assert calls[0][1]["messages"][0] != calls[1][1]["messages"][0]


@pytest.mark.parametrize("identity", ["", "x\r\nHeader: injected", "échange", "x" * 201])
def test_conversation_id_is_safe_to_use_as_a_header(identity):
    with pytest.raises(ValueError):
        chat(conversation=identity)
