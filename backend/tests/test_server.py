"""What must keep working whatever Marcel changes: the token, the health check, the MCP tools."""

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)  # no `with`: the background loops stay off
AUTH = {"Authorization": "Bearer test"}


def test_token_required():
    assert client.get("/health").status_code == 401
    assert client.get("/health", headers={"Authorization": "Bearer faux"}).status_code == 401


def test_health():
    reply = client.get("/health", headers=AUTH)
    assert reply.status_code == 200
    assert reply.json()["status"] == "ok"


def test_models():
    assert client.get("/v1/models", headers=AUTH).json()["models"]


def mcp(method: str, params: dict | None = None, token: str = "mcp-test"):
    return client.post("/mcp", headers={"Authorization": f"Bearer {token}"},
                       json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})


def test_mcp_needs_its_own_token():
    assert mcp("tools/list", token="test").status_code == 401


def test_mcp_tools_never_delete():
    tools = mcp("tools/list").json()["result"]["tools"]
    names = {t["name"] for t in tools}
    assert {"marcel_chercher", "marcel_retenir", "marcel_code_proposer", "marcel_code_fusionner"} <= names
    assert not any(word in name for name in names for word in ("supprim", "epingl", "delete", "pin"))
    reading = {t["name"] for t in tools if t["annotations"]["readOnlyHint"]}
    assert "marcel_code_lire" in reading and "marcel_code_ecrire" not in reading


def test_mcp_remember_and_routine():
    text = mcp("tools/call", {"name": "marcel_retenir", "arguments": {"texte": "Aime le café serré."}})
    assert "Retenu" in text.json()["result"]["content"][0]["text"]
    made = mcp("tools/call", {"name": "marcel_creer_routine",
                              "arguments": {"titre": "Point", "consigne": "Résume.", "jours": ["lundi"]}})
    assert "Chaque lundi" in made.json()["result"]["content"][0]["text"]


def test_assistant_relance_comes_back_in_its_conversation(tmp_path):
    from app.main import ChatRequest, Message, apply_blocks
    from app.routines import RoutineStore

    request = ChatRequest(conversation_id="C0FFEE00-0000-4000-8000-000000000000", assistant="planning",
                          messages=[Message(role="user", content="relance-moi mardi")])
    text = ('C\'est noté.\n\n```routine\n{"titre": "Relance", "consigne": "Demande si le planning va", '
            '"jours": ["mardi"], "heure": "09:00", "une_fois": true}\n```')
    card = apply_blocks(request, text)[0]
    assert card["status"] == "done" and card["detail"].startswith("Je te relancerai ici : une fois, mardi")
    from app.main import routines
    routine = routines.get(card["undo"]["id"])
    assert routine.assistant == "planning" and routine.once
    assert routine.conversation_id == request.conversation_id
    routines.delete(routine.id)

    # Old databases get the new columns.
    store = RoutineStore(tmp_path / "r.db", None)
    assert store.add("Point", "Fais le point").assistant == ""


def test_slash_commands_name_the_skill():
    from app.main import slash_note

    assert "marcel-code" in slash_note("/code ajoute un bouton")
    assert "« pdf »" in slash_note("/pdf résume")
    assert "web" in slash_note("/web météo")
    assert slash_note("pas de commande /code") == ""


def test_routine_waits_for_a_new_offer(monkeypatch):
    import asyncio

    from app import main

    routine = main.routines.add("Nouvelle offre", "Dis-moi si elle vaut le coup", trigger="offre")
    assert routine.schedule == "À chaque nouvelle offre"
    assert routine not in main.routines.due(10**10)
    started = []

    async def fake_run(r, event=""):
        started.append((r.id, event))

    monkeypatch.setattr(main, "run_routine", fake_run)
    assert asyncio.run(main.fire_routines("offre", "- nouvelle offre : Carrefour")) == 1
    assert started == [(routine.id, "- nouvelle offre : Carrefour")]
    assert asyncio.run(main.fire_routines("planning", "")) == 0
    main.routines.delete(routine.id)


def test_a_mission_going_in_circles_asks_for_help(tmp_path):
    import asyncio

    from app.missions import FAILED, STUCK_PREFIX, MissionStore

    async def circles():
        for n in range(5):
            yield {"id": f"t{n}", "name": "terminal", "detail": '{"cmd": "ls"}', "status": "running"}
            yield {"id": f"t{n}", "status": "done"}

    async def go():
        store = MissionStore(tmp_path / "m.db")
        mission = store.start("C", circles)
        await mission.task
        return mission

    mission = asyncio.run(go())
    assert mission.status == FAILED and mission.error.startswith(STUCK_PREFIX)
    assert len(mission.actions) == 3


def test_a_routine_says_what_it_looked_at():
    from app.main import looked_at

    said = looked_at(planning="Missions à venir", goals="Objectifs :\n- Courir\n- Lire", mail="", event="")
    assert "ton planning" in said and "2 objectifs" in said
    assert "aucune donnée" in looked_at(planning="", goals="", mail="", event="")


def test_done_is_checked_against_what_ran():
    from app.missions import verification

    claim = verification("C'est fait, j'ai envoyé le mail.", [], [])
    assert claim["status"] == "cancelled" and "aucune action" in claim["detail"]
    cut = verification("Voilà.", [{"id": "t1", "name": "browser_click", "status": "cancelled"}], [])
    assert cut["status"] == "cancelled" and "browser_click" in cut["detail"]
    ok = verification("J'ai créé la routine.", [{"id": "auto-routine-0", "name": "Nouvelle routine", "status": "done"}], [])
    assert ok["status"] == "done"
    assert verification("Bonjour !", [{"id": "memory", "name": "Mémoire", "status": "done"}], []) is None


def test_private_conversation_learns_nothing_and_is_forgotten():
    import asyncio

    from app import main

    request = main.ChatRequest(conversation_id="C0FFEE00-0000-4000-8000-0000000000AA", private=True, style="concis",
                               messages=[main.Message(role="user", content="Que sais-tu de moi ?")])

    async def go():
        started = await main.start_mission(request)
        mission = main.missions.get(started["id"])
        await mission.task
        return mission

    mission = asyncio.run(go())
    assert any(a["id"] == "private" for a in mission.actions) and main.from_outside(mission)
    assert not any(a["id"] == "memory" for a in mission.actions)
    main.missions.forget(mission.id)
    assert main.missions.get(mission.id) is None
    assert client.post("/v1/missions", headers=AUTH, json={
        "conversation_id": "C0FFEE00-0000-4000-8000-0000000000AA", "style": "bavard",
        "messages": [{"role": "user", "content": "x"}]}).status_code == 422


def test_rules_ask_first_then_validate():
    import asyncio

    from app import main

    saved = main.assistants.state("rules", {})
    try:
        put = client.put("/v1/rules", headers=AUTH, json={"rules": {"routine": "ask"}})
        assert put.json()["rules"]["routine"] == "ask"
        assert client.put("/v1/rules", headers=AUTH, json={"rules": {"supprimer": "auto"}}).status_code == 400
        text = ('Je te propose ça.\n\n```routine\n{"titre": "Point du soir", "consigne": "Résume ma journée", '
                '"jours": [], "heure": "20:00"}\n```')
        request = main.ChatRequest(conversation_id="C0FFEE00-0000-4000-8000-0000000000BB",
                                   messages=[main.Message(role="user", content="fais-le")])

        async def inner():
            yield text

        async def go():
            mission = main.missions.start(request.conversation_id,
                                          lambda: main.with_memory(request, inner, [], [], learn=False))
            await mission.task
            return mission

        mission = asyncio.run(go())
        waiting = [a for a in mission.actions if a["id"].startswith("auto-ask-routine")]
        assert waiting and waiting[0]["status"] == "cancelled"
        assert not any(r.title == "Point du soir" for r in main.routines.list())
        done = client.post(f"/v1/missions/{mission.id}/approve", headers=AUTH, json={"card": waiting[0]["id"]})
        assert done.status_code == 200 and done.json()["status"] == "done"
        routine = main.routines.get(done.json()["undo"]["id"])
        assert routine.title == "Point du soir"
        main.routines.delete(routine.id)
        again = client.post(f"/v1/missions/{mission.id}/approve", headers=AUTH, json={"card": waiting[0]["id"]})
        assert again.status_code == 404
    finally:
        main.assistants.set_state("rules", saved)


def test_routine_waits_for_an_email(monkeypatch):
    import asyncio

    from app import main
    from app.routines import valid_trigger

    assert valid_trigger("email") and valid_trigger("email:ecole.fr") and not valid_trigger("email:a b")
    routine = main.routines.add("Urgent", "Préviens-moi si c'est urgent", trigger="email:ecole.fr")
    assert routine.schedule == "À chaque e-mail de ecole.fr"
    inbox = [{"id": "1", "from": "Ecole <dir@ecole.fr>", "subject": "Réunion", "date": "", "snippet": "demain"}]
    started = []

    async def recent(limit=20, query=""):
        return inbox

    async def fake_run(r, event=""):
        started.append(event)

    monkeypatch.setattr(main.gmail, "recent", recent)
    monkeypatch.setattr(type(main.gmail), "connected", property(lambda self: True))
    monkeypatch.setattr(main, "MEMORY_LLM_URL", "http://model.test")
    monkeypatch.setattr(main, "run_routine", fake_run)
    main.assistants.set_state("mail_seen", None)
    try:
        assert asyncio.run(main.watch_mail()) == 0  # the first look only notes what is there
        inbox.insert(0, {"id": "2", "from": "pub@shop.com", "subject": "Promo", "date": "", "snippet": "-50 %"})
        inbox.insert(0, {"id": "3", "from": "dir@ecole.fr", "subject": "Urgent", "date": "", "snippet": "appelez"})
        assert asyncio.run(main.watch_mail()) == 1
        assert "Urgent" in started[0] and "Promo" not in started[0]
    finally:
        main.routines.delete(routine.id)
        main.assistants.set_state("mail_seen", None)



def test_routine_waits_for_an_email_in_marcels_mailbox(monkeypatch):
    import asyncio

    from app import main
    from app.routines import reads_mail, valid_trigger

    assert valid_trigger("boite") and valid_trigger("boite:ticketmaster") and not valid_trigger("boite:a b")
    assert reads_mail("boite:ticketmaster") and not reads_mail("offre")
    routine = main.routines.add("Places HYROX", "Préviens-moi si des places se libèrent", trigger="boite:ticketmaster")
    assert routine.schedule == "À chaque e-mail de ticketmaster reçu par Marcel"
    box = [{"id": "1", "from": "Ticketmaster <alertes@ticketmaster.fr>", "subject": "Bienvenue", "at": "",
            "preview": "", "unread": True}]
    started = []

    async def messages(limit=10):
        return box

    async def fake_run(r, event=""):
        started.append(event)

    monkeypatch.setattr(main, "mailbox", main.Mailbox("cle-test", "marcel@agentmail.to"))
    monkeypatch.setattr(main.mailbox, "messages", messages)
    monkeypatch.setattr(main, "MEMORY_LLM_URL", "http://model.test")
    monkeypatch.setattr(main, "run_routine", fake_run)
    main.assistants.set_state("box_seen", None)
    try:
        assert asyncio.run(main.watch_box()) == 0  # the first look only notes what is there
        box.insert(0, {"id": "2", "from": "pub@shop.com", "subject": "Promo", "at": "", "preview": "", "unread": True})
        box.insert(0, {"id": "3", "from": "alertes@ticketmaster.fr", "subject": "Places dispo", "at": "",
                       "preview": "HYROX Paris", "unread": True})
        assert asyncio.run(main.watch_box()) == 1
        assert "Places dispo" in started[0] and "Promo" not in started[0]
    finally:
        main.routines.delete(routine.id)
        main.assistants.set_state("box_seen", None)

def test_robot_screen_is_shown_and_hands_held():
    from app import main

    key = {"X-Planning-Key": main.PLANNING_KEY}
    if not main.PLANNING_KEY:
        return
    assert client.post("/v1/robot/screen", headers=key, content=b"pas une image").status_code == 400
    assert client.post("/v1/robot/screen?step=Lecture", headers=key, content=b"\xff\xd8\xff\xe0jpeg").status_code == 200
    shown = client.get("/v1/robot/screen", headers=AUTH).json()
    assert shown["live"] and shown["step"] == "Lecture" and shown["image"]
    assert client.post("/v1/robot/hands", headers=AUTH, json={"hold": True}).json()["hands"]
    assert client.get("/v1/planning/config", headers=key).json()["hands"]
    client.post("/v1/robot/hands", headers=AUTH, json={"hold": False})
    client.post("/v1/robot/screen/end", headers=key)


def test_routine_trigger_chosen_in_the_app():
    made = client.post("/v1/routines", headers=AUTH,
                       json={"title": "E-mail de RMA", "prompt": "Dis-moi si c'est urgent", "trigger": "email:rma.fr"})
    assert made.status_code == 200 and made.json()["trigger"] == "email:rma.fr"
    assert made.json()["schedule"] == "À chaque e-mail de rma.fr"
    routine_id = made.json()["id"]
    try:
        assert client.patch(f"/v1/routines/{routine_id}", headers=AUTH, json={"trigger": "n'importe"}).status_code == 400
        back = client.patch(f"/v1/routines/{routine_id}", headers=AUTH, json={"trigger": ""})
        assert back.json()["trigger"] == "" and back.json()["schedule"].startswith("Chaque jour")
        assert client.post("/v1/routines", headers=AUTH,
                           json={"title": "Faux", "prompt": "rien", "trigger": "meteo"}).status_code == 400
    finally:
        client.delete(f"/v1/routines/{routine_id}", headers=AUTH)


def test_bot_reads_and_page():
    from app import main

    saved = main.assistants.state("reads", {})
    try:
        bots = {a["id"]: a for a in client.get("/v1/assistants", headers=AUTH).json()}
        reads = {r["key"]: r["on"] for r in bots["veille"]["reads"]}
        assert reads["objectifs"] and not reads["planning"]
        changed = client.patch("/v1/assistants/veille", headers=AUTH, json={"reads": ["planning"]})
        assert {r["key"] for r in changed.json()["reads"] if r["on"]} == {"planning"}
        assert client.patch("/v1/assistants/veille", headers=AUTH, json={"reads": ["mails"]}).status_code == 400
        page = client.get("/v1/assistants/planning/page", headers=AUTH).json()
        assert page["title"] == "Missions des 7 prochains jours" and page["markdown"]
        assert client.get("/v1/assistants/mails/page", headers=AUTH).json()["markdown"] == ""
    finally:
        main.assistants.set_state("reads", saved)


def test_bots_speak_as_marcel():
    for bot in client.get("/v1/assistants", headers=AUTH).json():
        assert bot["welcome"].startswith("Ici **Marcel**"), bot["id"]
