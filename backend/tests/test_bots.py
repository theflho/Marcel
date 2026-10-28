"""The bots, like Grok Bot's: a standing task, tasks taught once, shared skills, reachable on Telegram."""

import pytest
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


def test_rules_have_three_levels_and_a_bot_can_have_its_own():
    from app.main import ChatRequest, Message, rule

    general = client.put("/v1/rules", headers=AUTH, json={"rules": {"routine": "off"}}).json()
    try:
        check_levels(general, rule, ChatRequest, Message)
    finally:
        client.put("/v1/rules", headers=AUTH, json={"rules": {"routine": "auto"}})
        client.put("/v1/rules", headers=AUTH, json={"assistant": "planning", "rules": {"routine": ""}})


def check_levels(general, rule, ChatRequest, Message):
    assert general["rules"]["routine"] == "off"
    assert client.put("/v1/rules", headers=AUTH, json={"rules": {"routine": ""}}).status_code == 400

    # Planning may do it by itself; the others stay blocked.
    mine = client.put("/v1/rules", headers=AUTH,
                      json={"assistant": "planning", "rules": {"routine": "auto"}}).json()
    assert mine["bots"]["planning"] == {"routine": "auto"}
    assert rule("routine", "planning") == "auto" and rule("routine", "pointage") == "off"
    assert client.put("/v1/rules", headers=AUTH,
                      json={"assistant": "inconnu", "rules": {"routine": "auto"}}).status_code == 404

    # Blocked: the block gives a card saying so, nothing is created.
    from app import main
    request = ChatRequest(conversation_id=CONVERSATION, assistant="pointage",
                          messages=[Message(role="user", content="relance-moi")])
    before = len(main.routines.list())
    text = 'Ok.\n```routine\n{"titre": "Relance", "consigne": "x", "une_fois": true}\n```'

    async def run():
        cards = []

        async def reply(*_):
            yield text

        async for item in main.with_memory(request, reply, [], [], learn=False):
            if isinstance(item, dict):
                cards.append(item)
        return cards

    import asyncio
    cards = asyncio.run(run())
    assert any(c["id"] == "auto-off-routine-0" and "Bloqué" in c["detail"] for c in cards)
    assert len(main.routines.list()) == before

    client.put("/v1/rules", headers=AUTH, json={"assistant": "planning", "rules": {"routine": ""}})
    assert "planning" not in client.get("/v1/rules", headers=AUTH).json()["bots"]


def test_a_bot_asks_the_iphone_under_the_rules():
    from app.main import iphone_card, iphone_request

    asked = iphone_request('Je regarde.\n```iphone\n{"lire": "contacts", "chercher": "Paul  Martin"}\n```')
    assert asked == {"lire": "contacts", "chercher": "Paul Martin"}
    assert iphone_request('```iphone\n{"lire": "contacts"}\n```') is None
    assert iphone_request('```iphone\n{"lire": "photos"}\n```') is None
    assert iphone_request('```iphone\n{"lire": "agenda", "jours": 90}\n```') == {"lire": "agenda", "jours": 14}
    reminder = iphone_request('```iphone\n{"ajouter_rappel": {"titre": "Appeler Paul", "quand": "2026-10-28T09:00"}}\n```')
    assert reminder == {"ajouter_rappel": {"titre": "Appeler Paul", "quand": "2026-10-28T09:00"}}

    assert iphone_card(asked, "auto", outside=False)["id"] == "iphone-0"
    assert iphone_card(asked, "ask", outside=False)["id"] == "auto-ask-iphone-0"
    # Built on an e-mail: never by itself.
    assert iphone_card(asked, "auto", outside=True)["id"] == "auto-ask-iphone-0"
    assert iphone_card(reminder, "off", outside=False)["id"] == "auto-off-iphone_ecriture-0"


def test_a_bots_runs_are_read_then_done():
    from app.main import routines

    routine = routines.add("Point offres", "Fais le point.", assistant="recrutements",
                           conversation_id=CONVERSATION, task=True)
    run_id = routines.start_run(routine.id, "")
    routines.finish_run(run_id, "done")
    listed = client.get("/v1/assistants/recrutements/runs", headers=AUTH).json()
    run = next(r for r in listed if r["id"] == run_id)
    assert run["title"] == "Point offres" and run["task"] and not run["seen"] and not run["done"]
    seen = client.post(f"/v1/routine-runs/{run_id}/mark", headers=AUTH, json={"seen": True}).json()
    assert seen["seen"] and not seen["done"]
    done = client.post(f"/v1/routine-runs/{run_id}/mark", headers=AUTH, json={"done": True}).json()
    assert done["seen"] and done["done"]
    assert client.post("/v1/routine-runs/999999/mark", headers=AUTH, json={"seen": True}).status_code == 404
    assert client.get("/v1/assistants/inconnu/runs", headers=AUTH).status_code == 404
    routines.delete(routine.id)


def test_hermes_stream_shows_a_tool_call_a_few_times_and_says_clear_errors():
    from app.main import hermes_chunk, hermes_refusal
    from app.missions import verification

    tools, shown = {}, {}

    def worth(index, tool):
        name, length = shown.get(index, ("", -100))
        if tool["name"] != name or len(tool["detail"]) - length >= 60:
            shown[index] = (tool["name"], len(tool["detail"]))
            return True
        return False

    pieces = [{"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "call-1",
                                                      "function": {"name": "terminal", "arguments": ""}}]}}]}]
    pieces += [{"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": "x" * 5}}]}}]}] * 40
    updates = [item for chunk in pieces for item in hermes_chunk(chunk, tools, lambda: [], worth, True)]
    assert 1 < len(updates) <= 5 and updates[0]["name"] == "terminal"

    assert "quota" in hermes_refusal(429, '{"error": {"message": "rate limited"}}')
    assert "clé refusée" in hermes_refusal(401, "")
    assert "planté" in hermes_refusal(502, "<html>")

    # Marcel's own cards are no unfinished step.
    cards = [{"id": "auto-ask-routine-0", "name": "Créer une routine", "status": "cancelled"},
             {"id": "iphone-0", "name": "iPhone", "status": "pending"},
             {"id": "search", "name": "Recherche web", "status": "cancelled"}]
    assert verification("Voilà.", cards, []) is None


def test_a_bot_of_the_user_carries_the_automations_and_gives_them_back():
    from app.main import assistants, bot_context
    made = client.post("/v1/assistants", headers=AUTH,
                       json={"name": "Cockpit test", "mission": "Réunir planning, pointage et offres", "mood": "tree"}).json()
    cockpit = made["id"]
    try:
        client.patch("/v1/assistants/planning", headers=AUTH, json={"changes": {"hour": 7}})
        client.patch("/v1/assistants/pointage", headers=AUTH, json={"changes": {"lead_minutes": 12}})
        # Only from the app, and only to one of the user's bots (or back to its own).
        assert client.put("/v1/automations/lecture", headers=AUTH, json={"assistant": "mails"}).status_code == 400
        assert client.put("/v1/automations/inconnu", headers=AUTH, json={"assistant": cockpit}).status_code == 400
        for key in ("lecture", "pointage", "offres"):
            assert client.put(f"/v1/automations/{key}", headers=AUTH, json={"assistant": cockpit}).status_code == 200

        bots_now = {b["id"]: b for b in client.get("/v1/assistants", headers=AUTH).json()}
        mine = {s["key"]: s["value"] for s in bots_now[cockpit]["settings"]}
        # Same values as before the move: nothing changes but who carries it.
        assert mine["hour"] == 7 and mine["lead_minutes"] == 12 and mine["notify"] is True and "role" in mine
        assert all(a["carried"] for a in bots_now[cockpit]["automations"])
        # The system bots lost them: no second reading, no double notification.
        assert "hour" not in {s["key"] for s in bots_now["planning"]["settings"]}
        assert not {s["key"] for s in bots_now["pointage"]["settings"]} & {"lead_minutes", "start_text"}
        assert "notify" not in {s["key"] for s in bots_now["recrutements"]["settings"]}
        assert bots_now["planning"]["automations"][0]["owner"] == cockpit
        assert assistants.actions("planning") == {} and "relire" in assistants.actions(cockpit)
        assert client.patch("/v1/assistants/planning", headers=AUTH, json={"changes": {"hour": 9}}).status_code == 400

        # Same bounds as the system bots, and the robot reads the hour from the bot that carries it.
        assert client.patch(f"/v1/assistants/{cockpit}", headers=AUTH, json={"changes": {"hour": 3}}).status_code == 400
        client.patch(f"/v1/assistants/{cockpit}", headers=AUTH, json={"changes": {"hour": 8}, "actions": ["relire"]})
        assert assistants.automation_value("hour") == 8
        assert "Lecture du portail RMA" in bot_context(assistants.find(cockpit))[0]
        assert "ne le règles plus" in bot_context(assistants.find("planning"))[0]

        # Taken back with the values it had in the meantime.
        assert client.put("/v1/automations/lecture", headers=AUTH, json={"assistant": "planning"}).status_code == 200
        assert assistants.value("planning", "hour") == 8 and "relire" in assistants.actions("planning")
    finally:
        client.delete(f"/v1/assistants/{cockpit}", headers=AUTH)
    # Deleting the bot gives back what it carried.
    assert assistants.owners() == {"lecture": "planning", "pointage": "pointage", "offres": "recrutements"}
    assert assistants.value("pointage", "lead_minutes") == 12
    client.patch("/v1/assistants/planning", headers=AUTH, json={"changes": {"hour": 19}})
    client.patch("/v1/assistants/pointage", headers=AUTH, json={"changes": {"lead_minutes": 5}})


def test_hermes_reads_the_bots_and_sets_one_by_the_rules():
    from app.main import assistants
    listed = mcp_call("marcel_bots", {})
    assert not listed["isError"] and "[planning] Planning RMA" in listed["content"][0]["text"]
    assert "hour" in listed["content"][0]["text"] and "relire" in listed["content"][0]["text"]
    for name in ("marcel_idees", "marcel_passages", "marcel_regles"):
        assert not mcp_call(name, {})["isError"], name
    before = client.get("/v1/rules", headers=AUTH).json()["rules"]["reglage"]
    try:
        client.put("/v1/rules", headers=AUTH, json={"rules": {"reglage": "auto"}})
        done = mcp_call("marcel_regler_bot", {"bot": "planning", "reglages": {"hour": 8}, "actions": ["relire"]})
        assert not done["isError"] and assistants.value("planning", "hour") == 8
        # Same bounds as the app; nothing else than settings, instructions and the bot's actions.
        assert mcp_call("marcel_regler_bot", {"bot": "planning", "reglages": {"hour": 2}})["isError"]
        assert mcp_call("marcel_regler_bot", {"bot": "planning", "actions": ["supprimer"]})["isError"]
        assert mcp_call("marcel_regler_bot", {"bot": "inconnu", "reglages": {"hour": 8}})["isError"]
        # "Ask first" and "blocked": it doesn't do it.
        for level, said in (("ask", "demande d'abord"), ("off", "bloqué")):
            client.put("/v1/rules", headers=AUTH, json={"rules": {"reglage": level}})
            refused = mcp_call("marcel_regler_bot", {"bot": "planning", "reglages": {"hour": 10}})
            assert refused["isError"] and said in refused["content"][0]["text"]
        assert assistants.value("planning", "hour") == 8
        # A bot's own level wins over the general one.
        client.put("/v1/rules", headers=AUTH, json={"rules": {"reglage": "auto"}, "assistant": "planning"})
        assert not mcp_call("marcel_regler_bot", {"bot": "planning", "reglages": {"hour": 9}})["isError"]
    finally:
        client.put("/v1/rules", headers=AUTH, json={"rules": {"reglage": ""}, "assistant": "planning"})
        client.put("/v1/rules", headers=AUTH, json={"rules": {"reglage": before}})
        client.patch("/v1/assistants/planning", headers=AUTH, json={"changes": {"hour": 19}})
        assistants.set_state("read_now", False)


def test_a_deployment_report_keeps_the_end_of_its_log():
    sent = client.post("/v1/deploy/report", headers=AUTH,
                       json={"status": "failed", "commit": "abc1234", "message": "test", "log": "x" * 15000})
    assert sent.status_code == 200


def test_a_bot_hands_to_marcel_what_it_cannot_do():
    from app.main import assistants, bot_context, plain_reply
    made = client.post("/v1/assistants", headers=AUTH,
                       json={"name": "Relais test", "mission": "Aider sur le planning", "mood": "tree"}).json()
    try:
        told = bot_context(assistants.find(made["id"]))[0]
        assert "```pour-marcel" in told and "Demander à Marcel" in told and "Théo doit" not in told
        reply = 'Je ne peux pas.\n```pour-marcel\n{"demande": "Ajoute un bouton"}\n```'
        assert "pour-marcel" not in plain_reply(reply) and "depuis l'app" in plain_reply(reply)
    finally:
        client.delete(f"/v1/assistants/{made['id']}", headers=AUTH)


def test_a_hand_over_is_only_proposed_and_waits_for_the_user():
    from app.main import APP_PROMPT, assistants, bot_context, plain_reply
    made = client.post("/v1/assistants", headers=AUTH,
                       json={"name": "Accord test", "mission": "Réunir le RMA", "mood": "tree"}).json()
    try:
        assert "```automatisme" in bot_context(assistants.find(made["id"]))[0]
        assert "```automatisme" in APP_PROMPT
        reply = 'Je te le propose.\n```automatisme\n{"automatisme": "pointage", "bot": "ici"}\n```'
        assert "valider dans l'app" in plain_reply(reply)
        # Nothing moved: only the app's « Confier » (PUT /v1/automations) does it.
        assert assistants.owner("pointage") == "pointage"
    finally:
        client.delete(f"/v1/assistants/{made['id']}", headers=AUTH)


def test_marcel_codes_big_work_himself_unless_an_agent_is_chosen():
    from app.main import app_context, assistants
    shown = client.get("/v1/code-requests", headers=AUTH).json()
    assert shown["agents"][0] == {"id": "marcel", "name": "Marcel lui-même"}
    before = assistants.state("code_agent", None)
    try:
        assistants.set_state("code_agent", "marcel")
        assert "tu le fais toi-même" in app_context(False) and "si tu le juges mieux" not in app_context(False)
        assert client.put("/v1/code-requests/agent", headers=AUTH, json={"agent": "claude"}).status_code == 200
        assert "si tu le juges mieux" in app_context(False)
        assert client.put("/v1/code-requests/agent", headers=AUTH, json={"agent": "marcel"}).status_code == 200
        assert client.put("/v1/code-requests/agent", headers=AUTH, json={"agent": "autre"}).status_code == 400
    finally:
        assistants.set_state("code_agent", before or "marcel")


def test_bots_always_get_marcels_tools_never_with_mails():
    from app.main import assistants, bot_context, bot_tools, mail_needed, rules
    planning = assistants.find("planning")
    assert bot_tools(planning) and bot_tools(assistants.find("mails"))
    assert not bot_tools(planning, mail="un e-mail") and not bot_tools(assistants.find("mails"), mail="un e-mail")
    # The Mails bot reads the e-mails (without tools), except for a request for tools only.
    assert mail_needed("mails", "quoi de neuf ?") and mail_needed("mails", "un script pour trier mes mails")
    assert not mail_needed("mails", "écris-moi un script Python") and not mail_needed("planning", "quoi de neuf ?")
    with_tools, web = bot_context(planning, tools=True)
    assert "les mêmes outils que Marcel" in with_tools and "```pour-marcel" not in with_tools and not web
    assert "```pour-marcel" in bot_context(planning)[0]
    # No rule turns them off: a bot is a Hermes profile.
    assert bot_tools(planning) and bot_tools(assistants.find("pointage")) and "outils" not in rules()


def test_a_bot_has_its_own_memory(tmp_path):
    from app.memory import MemoryStore
    store = MemoryStore(tmp_path / "m.db")
    store.add("L'utilisateur habite à Lyon")
    store.add("Budget concerts : 80 euros maximum", owner="billets")
    store.add("Budget concerts : 80 euros maximum par place")  # not a duplicate of the bot's own
    note, facts = store.context("budget concerts", owner="billets")
    assert "Ce que tu as appris toi-même" in note and any(f.owner == "billets" for f in facts)
    marcel, _ = store.context("budget concerts")
    assert "80 euros maximum par place" in marcel and "Ce que tu as appris toi-même" not in marcel
    assert {f.owner for f in store.active()} == {"", "billets"}
    assert all(f.owner == "" for f in store.active(owner="planning"))



def test_a_fact_is_remembered_for_a_bot_and_moved():
    from app.main import ToolError, assistants, bot_context, tool_remember
    planning = assistants.find("planning")
    assert f"mémoire de {planning.name}" in tool_remember({"texte": "Préfère les créneaux du matin", "bot": "planning"})
    assert '"bot": "planning"' in bot_context(planning, tools=True)[0]
    fact = next(f for f in client.get("/v1/memory", headers=AUTH, params={"q": "créneaux matin"}).json()["items"]
                if f["owner"] == "planning")
    assert client.patch(f"/v1/memory/{fact['id']}", headers=AUTH, json={"owner": ""}).json()["owner"] == ""
    assert client.patch(f"/v1/memory/{fact['id']}", headers=AUTH, json={"owner": "inconnu"}).status_code == 404
    try:
        tool_remember({"texte": "Quelque chose", "bot": "inconnu"})
        raise AssertionError("an unknown bot is refused")
    except ToolError:
        pass


def test_accounts_and_purchases_follow_the_rules_and_the_cap():
    from app.main import MissionError, autonomy_note, hermes_chunk, vault_open

    vault = {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "v", "function": {"name": "browser_vault"}}]}}]}
    try:
        state = client.put("/v1/rules", headers=AUTH,
                           json={"rules": {"compte": "off", "achat": "ask"}, "purchase_cap": 80}).json()
        assert state["purchase_cap"] == 80 and state["rules"]["achat"] == "ask"
        assert not vault_open("Réserve-moi une table") and vault_open("Vas-y")
        with pytest.raises(MissionError):
            list(hermes_chunk(vault, {}, lambda: [], lambda i, t: True, True, vault_open("Réserve")))
        assert "tu ne crées aucun compte" in autonomy_note() and "80 €" in autonomy_note()

        client.put("/v1/rules", headers=AUTH, json={"rules": {"achat": "auto"}})
        assert vault_open("Réserve-moi une table") and "seul, jusqu'à 80 €" in autonomy_note()
        assert list(hermes_chunk(vault, {}, lambda: [], lambda i, t: True, True, True))
        assert client.put("/v1/rules", headers=AUTH, json={"purchase_cap": -1}).status_code == 422
    finally:
        client.put("/v1/rules", headers=AUTH, json={"rules": {"compte": "auto", "achat": "ask"}, "purchase_cap": 50})


def test_mcp_stays_connected_during_the_emergency_stop_but_runs_no_tool():
    import asyncio

    from app.main import missions

    def rpc(method: str, params: dict | None = None, key: str = "mcp-test"):
        return client.post("/mcp", headers={"Authorization": f"Bearer {key}"},
                           json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})

    assert rpc("ping", key="faux").status_code == 401
    assert client.get("/health", headers=AUTH).json()["mcp"]["refused"]
    asyncio.run(missions.emergency_stop())
    try:
        assert rpc("ping").status_code == 200
        assert any(t["name"] == "marcel_boite" for t in rpc("tools/list").json()["result"]["tools"])
        called = rpc("tools/call", {"name": "marcel_resume", "arguments": {}}).json()["result"]
        assert called["isError"] and "Arrêt d'urgence" in called["content"][0]["text"]
    finally:
        missions.emergency_resume()
    assert client.get("/health", headers=AUTH).json()["mcp"]["seen"]
    assert not mcp_call("marcel_regles", {})["isError"]


def test_each_bot_has_a_hermes_profile_and_its_tools_follow_its_rules():
    profiles = client.get("/v1/hermes/profiles", headers=AUTH).json()
    names = {p["bot"]: p["name"] for p in profiles["profiles"]}
    assert names["planning"] == "marcel-planning" and all(n.startswith(profiles["prefix"]) for n in names.values())
    assert "Planning RMA" in next(p["soul"] for p in profiles["profiles"] if p["bot"] == "planning")

    client.put("/v1/rules", headers=AUTH, json={"assistant": "planning", "rules": {"objectif": "off"}})
    try:
        call = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": {"name": "marcel_creer_objectif", "arguments": {"titre": "Suivre un prix"}}}
        as_planning = client.post("/mcp", headers={"Authorization": "Bearer mcp-test", "X-Marcel-Bot": "planning"},
                                  json=call).json()["result"]
        assert as_planning["isError"] and "bloqué" in as_planning["content"][0]["text"]
    finally:
        client.put("/v1/rules", headers=AUTH, json={"assistant": "planning", "rules": {"objectif": ""}})


def test_what_hermes_sends_on_its_own_reaches_the_bot_in_the_app():
    """The « marcel » platform plugin: a cron job's result, each profile to its own bot."""
    deliver = lambda body, key="mcp-test": client.post(  # noqa: E731
        "/v1/hermes/deliver", headers={"Authorization": f"Bearer {key}"}, json=body)
    assert deliver({"bot": "planning", "text": "x"}, key="test").status_code == 401  # the app's key is not Hermes'
    assert deliver({"bot": "nobody", "text": "x"}).status_code == 404
    first = deliver({"bot": "planning", "text": "**Point du matin** : deux missions."}).json()["id"]
    second = deliver({"bot": "planning", "text": "Point du soir."}).json()["id"]
    main = deliver({"bot": "marcel", "text": "Rappel : facture EDF."}).json()["id"]
    pending = {e["id"]: e for e in client.get("/v1/bot-messages", headers=AUTH).json()}
    entry = pending[first]
    assert entry["assistant"] == "planning" and entry["via"] == "Hermes" and entry["question"] == ""
    assert entry["text"] == "**Point du matin** : deux missions." and entry["status"] == "done"
    assert pending[second]["conversation_id"] == entry["conversation_id"]  # one conversation per bot
    assert pending[main]["assistant"] == "" and pending[main]["assistant_name"] == "Marcel"
    for entry_id in (first, second, main):
        assert client.post(f"/v1/bot-messages/{entry_id}/delivered", headers=AUTH).status_code == 200
