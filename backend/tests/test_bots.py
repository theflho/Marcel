"""The bots, like Grok Bot's: a standing task, tasks taught once, shared skills, reachable on Telegram."""

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)  # no `with`: the background loops stay off
AUTH = {"Authorization": "Bearer test"}
CONVERSATION = "C0FFEE00-0000-4000-8000-0000000000B0"


def mcp_call(name: str, arguments: dict) -> dict:
    reply = client.post("/mcp", headers={"Authorization": "Bearer mcp-test"},
                        json={"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                              "params": {"name": name, "arguments": arguments}})
    return reply.json()["result"]


def test_a_task_taught_once_is_kept_shown_and_told_to_the_bot():
    from app.main import ChatRequest, Message, apply_blocks, assistants, bot_context

    request = ChatRequest(conversation_id=CONVERSATION, assistant="recrutements",
                          messages=[Message(role="user", content="apprends à trier mes offres")])
    text = ('C\'est retenu.\n\n```recette\n{"titre": "Trier les offres", "etapes": ["lister les offres", '
            '"écarter les conflits", "garder les plus proches"]}\n```')
    card = apply_blocks(request, text)[0]
    assert card["status"] == "done" and "Trier les offres" in card["detail"]
    assert card["undo"] == {"kind": "recette", "assistant": "recrutements", "id": card["undo"]["id"]}
    shown = client.get("/v1/assistants", headers=AUTH).json()
    offers = next(a for a in shown if a["id"] == "recrutements")
    assert offers["recipes"][0]["steps"] == ["lister les offres", "écarter les conflits", "garder les plus proches"]
    assert "lister les offres → écarter les conflits" in bot_context(assistants.find("recrutements"))[0]

    # Taught again under the same title: replaced, not doubled. Then edited and erased by the user.
    apply_blocks(request, text.replace("garder les plus proches", "garder les mieux payées"))
    assert len(assistants.recipes("recrutements")) == 1
    recipe_id = card["undo"]["id"]
    edited = client.put(f"/v1/assistants/recrutements/recipes/{recipe_id}", headers=AUTH,
                        json={"title": "Trier les offres", "steps": ["tout lire"]}).json()
    assert edited["recipes"][0]["steps"] == ["tout lire"]
    assert client.put(f"/v1/assistants/recrutements/recipes/{recipe_id}", headers=AUTH,
                      json={"title": "x", "steps": []}).status_code == 400
    assert client.delete(f"/v1/assistants/recrutements/recipes/{recipe_id}", headers=AUTH).json()["recipes"] == []

    # Only in a bot's conversation.
    marcel = ChatRequest(conversation_id=CONVERSATION, messages=[Message(role="user", content="apprends")])
    assert apply_blocks(marcel, text)[0]["status"] == "cancelled"


def test_shared_skills_are_ticked_per_bot():
    from app.main import assistants, bot_context

    made = client.post("/v1/bot-skills", headers=AUTH,
                       json={"title": "Ton RMA", "text": "Toujours poli et bref avec RMA."}).json()
    assert client.post("/v1/bot-skills", headers=AUTH, json={"title": "ton rma", "text": "doublon"}).status_code == 400
    ticked = client.patch("/v1/assistants/planning", headers=AUTH, json={"skills": [made["id"]]}).json()
    assert next(s for s in ticked["skills"] if s["id"] == made["id"])["on"]
    assert "Toujours poli et bref avec RMA." in bot_context(assistants.find("planning"))[0]
    assert "Toujours poli" not in bot_context(assistants.find("pointage"))[0]
    assert client.get("/v1/bot-skills", headers=AUTH).json()[-1]["bots"] == ["planning"]
    assert client.patch("/v1/assistants/planning", headers=AUTH, json={"skills": ["inconnue"]}).status_code == 400

    client.put(f"/v1/bot-skills/{made['id']}", headers=AUTH, json={"title": "Ton RMA", "text": "Vouvoie RMA."})
    assert "Vouvoie RMA." in bot_context(assistants.find("planning"))[0]
    client.delete(f"/v1/bot-skills/{made['id']}", headers=AUTH)
    assert assistants.chosen_skills("planning") == []


def test_a_bot_has_a_standing_task_with_its_next_wake_up():
    set_task = client.put("/v1/assistants/recrutements/task", headers=AUTH,
                          json={"prompt": "Regarde les nouvelles offres et dis lesquelles prendre.",
                                "trigger": "offre", "conversation_id": CONVERSATION.lower()}).json()
    task = set_task["task"]
    assert task["schedule"] == "À chaque nouvelle offre" and task["next"] == "À chaque nouvelle offre"
    assert task["conversation_id"] == CONVERSATION and task["last_run"] is None

    # Changed in place (one task per bot), at an hour this time.
    changed = client.put("/v1/assistants/recrutements/task", headers=AUTH,
                         json={"prompt": "Fais le point des offres.", "days": "0", "at": "07:30"}).json()["task"]
    assert changed["id"] == task["id"] and changed["schedule"] == "Chaque lundi à 7 h 30"
    assert changed["next_run"] and changed["next"].startswith("lun.")
    paused = client.put("/v1/assistants/recrutements/task", headers=AUTH,
                        json={"prompt": "Fais le point des offres.", "status": "paused"}).json()["task"]
    assert paused["next"] == "En pause"
    assert client.put("/v1/assistants/recrutements/task", headers=AUTH,
                      json={"prompt": "Fais le point.", "trigger": "pluie"}).status_code == 400
    assert client.delete("/v1/assistants/recrutements/task", headers=AUTH).json()["task"] is None


def test_a_task_ends_with_an_action_of_its_bot_only():
    from app.main import assistants, routines, task_cards

    routine = routines.add("Tâche de Planning RMA", "Vérifie l'heure de lecture.", assistant="planning",
                           conversation_id=CONVERSATION, task=True)
    before = assistants.value("planning", "hour")
    text = ('Je lis plus tôt.\n```reglage\n{"changes": {"hour": 7}, "actions": [], "consigne": "", '
            '"mascotte": "", "resume": "lecture à 7 h"}\n```\n```routine\n{"titre": "Encore", "consigne": "x"}\n```')
    cards = task_cards(routine, text)
    assert [c["status"] for c in cards] == ["done"] and assistants.value("planning", "hour") == 7
    assistants.save("planning", {"hour": before})

    # After an e-mail, the user applies it himself.
    routine = routines.update(routine.id, trigger="email")
    assert task_cards(routine, text)[0]["status"] == "cancelled"
    assert assistants.value("planning", "hour") == before
    assert task_cards(routine, "Rien à signaler.") == []
    routines.delete(routine.id)


def test_a_bot_answers_on_telegram_and_the_app_gets_the_exchange(monkeypatch):
    from app import main

    told = []

    async def quick(request, facts=()):
        told.append([m.content for m in request.messages])
        yield "Trois missions cette semaine.\n```suivi\n[\"Et demain ?\"]\n```"

    monkeypatch.setattr(main, "mock_stream", quick)
    reply = mcp_call("marcel_bot", {"bot": "/planning", "message": "mes missions de la semaine ?"})
    assert not reply["isError"] and reply["content"][0]["text"] == "Trois missions cette semaine."
    pending = client.get("/v1/bot-messages", headers=AUTH).json()
    entry = next(e for e in pending if e["question"] == "mes missions de la semaine ?")
    assert entry["assistant"] == "planning" and entry["via"] == "Telegram" and entry["text"]
    assert client.post(f"/v1/bot-messages/{entry['id']}/delivered", headers=AUTH).status_code == 200
    assert all(e["id"] != entry["id"] for e in client.get("/v1/bot-messages", headers=AUTH).json())

    # The same conversation next time.
    mcp_call("marcel_bot", {"bot": "planningrma", "message": "et demain ?"})
    again = next(e for e in client.get("/v1/bot-messages", headers=AUTH).json() if e["question"] == "et demain ?")
    assert again["conversation_id"] == entry["conversation_id"]
    # It remembers what was said before on Telegram.
    assert told[-1] == ["mes missions de la semaine ?", "Trois missions cette semaine.", "et demain ?"]

    refused = mcp_call("marcel_bot", {"bot": "mails", "message": "quoi de neuf ?"})
    assert refused["isError"] and "reste dans l'app" in refused["content"][0]["text"]
    assert mcp_call("marcel_bot", {"bot": "/inconnu", "message": "?"})["isError"]


def test_a_routine_says_when_it_runs_next():
    made = client.post("/v1/routines", headers=AUTH, json={"title": "Point", "prompt": "Fais le point.",
                                                           "days": "0", "at": "08:00"}).json()
    listed = next(r for r in client.get("/v1/routines", headers=AUTH).json() if r["id"] == made["id"])
    assert listed["next"].startswith("lun.") and listed["next_run"] and listed["task"] is False
    paused = client.patch(f"/v1/routines/{made['id']}", headers=AUTH, json={"status": "paused"}).json()
    assert paused["next"] == "En pause" and paused["next_run"] is None
    client.delete(f"/v1/routines/{made['id']}", headers=AUTH)
