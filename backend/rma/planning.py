"""Reads the user's RMA missions (merchandising planning) and hands them to Marcel. Read only.

It opens the employee portal in an invisible browser, signs in, shows the missions for the week
and the month, reads the cards (store, kind, date, hours, client) and sends them to Marcel.
It never opens a mission and never touches the time clock: clocking in stays the user's own act,
on site, from their phone.

    python planning.py              runs every day at the hour set in the app (Planning assistant,
                                    RMA_HOUR when Marcel can't be reached), once at start, and
                                    whenever the app asks ("Relire maintenant")
    python planning.py --once       one reading, then stops
    python planning.py --debug      one reading, prints what the page shows (no credentials)
                                    and saves a screenshot to /data
"""

import asyncio
import json
import os
import re
import sys
import time
from pathlib import Path

import httpx
from playwright.async_api import TimeoutError as PlaywrightTimeout
from playwright.async_api import async_playwright

PORTAL = "https://ecollaborateurs.rmasa.com/"
HOME = PORTAL + "#/accueil"
MISSIONS = PORTAL + "#/accueil/missions"
OFFERS = PORTAL + "#/accueil/missrecrut"
LOGIN = os.environ.get("RMA_LOGIN", "")
PASSWORD = os.environ.get("RMA_PASSWORD", "")
MARCEL_URL = os.environ.get("MARCEL_URL", "http://marcel-api:8000").rstrip("/")
PLANNING_KEY = os.environ.get("MARCEL_PLANNING_KEY", "")
HOUR = int(os.environ.get("RMA_HOUR") or 19)
DATA = Path(os.environ.get("RMA_DATA_DIR", "/data"))
# The views the portal offers; the week and the month together cover what's coming.
VIEWS = ("Sem.", "Mois", "∞")  # see VIEW_VALUES
# "26/10/2026 20:00 - 23:00 FERRERO FRANCE COMMERCIALE" (the client may be on the next line).
SLOT = re.compile(r"(\d{2}/\d{2}/\d{4})\s+(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})\s*(.*)")


def parse(text: str) -> list[dict]:
    """Missions from the visible text of the list: store and kind are the two lines above the slot."""
    lines = [line.strip() for line in text.splitlines()]
    lines = [line for line in lines if line and len(line) > 1]  # drops lone icons ("I", "€")
    missions = []
    for index, line in enumerate(lines):
        if not (match := SLOT.search(line)):
            continue
        date, start, end, client = match.groups()
        if not client and index + 1 < len(lines) and not SLOT.search(lines[index + 1]):
            client = lines[index + 1]
        missions.append({
            "store": lines[index - 2] if index >= 2 else "",
            "kind": lines[index - 1] if index >= 1 else "",
            "date": date, "start": start, "end": end, "client": client.strip(),
        })
    return missions


# An offer card: the store, then "Le 19 oct. 2026", then the operation, the client and the agency.
# The portal may write the date with non-breaking spaces ("Le\u00a019\u00a0oct.\u00a02026"): any space goes.
OFFER_DAY = re.compile(r"^Le\s+(\d{1,2})\s+(\S+?)\s+(\d{4})$")
# The recruitment page's text at the last reading, shown by --debug.
OFFERS_TEXT: list[str] = [""]


def offer_date(line: str) -> str:
    """ "Le 19 oct. 2026" (whatever the spaces) → "19 oct. 2026"."""
    return " ".join(OFFER_DAY.match(line).groups())


def parse_offers(text: str) -> list[dict]:
    """Offers from the visible text of "Recrutements › Attente de réponse"."""
    lines = [line.strip() for line in text.splitlines()]
    lines = [line for line in lines if line and len(line) > 1]
    days = [i for i, line in enumerate(lines) if OFFER_DAY.match(line)]
    offers = []
    for n, index in enumerate(days):
        # The fields run until the next card's store (the line before its date).
        end = days[n + 1] - 1 if n + 1 < len(days) else min(len(lines), index + 4)
        fields = [part.strip() for line in lines[index + 1:end] for part in re.split(r"\t|\s{2,}", line) if part.strip()]
        fields += [""] * 3
        offers.append({"store": lines[index - 1] if index else "", "date": offer_date(lines[index]),
                       "kind": fields[0], "client": fields[1], "agency": fields[2]})
    return offers


async def read_offers(page) -> list[dict] | None:
    """The offers waiting for an answer (first tab, shown by default). Nothing is clicked.
    None when the page didn't show up, so the known offers aren't wiped."""
    await page.goto(OFFERS, wait_until="networkidle", timeout=60_000)
    try:
        await page.get_by_text(re.compile(r"Attente de r[ée]ponse")).first.wait_for(timeout=30_000)
    except PlaywrightTimeout:
        print("Page des recrutements introuvable.")
        return None
    try:
        await page.get_by_text(OFFER_DAY).first.wait_for(timeout=20_000)
    except PlaywrightTimeout:
        pass  # no offer waiting, or slow: the text read below tells
    await scroll_list(page)
    text = await page.locator("body").inner_text()
    OFFERS_TEXT[:] = [text]
    offers = parse_offers(text)
    # Each offer's own page holds its hours, the portal's conflict warning and its address.
    # Reading it presses no button.
    for index, offer in enumerate(offers):
        try:
            await page.get_by_text(OFFER_DAY).nth(index).click()
            await page.wait_for_url(re.compile(r"recrutedet"), timeout=20_000)
            await page.get_by_text(re.compile(r"Accepter la mission|Refuser")).first.wait_for(timeout=20_000)
            offer.update(parse_offer_page(await page.locator("body").inner_text()))
            offer["link"] = page.url.split("#", 1)[1][:300]
            button = answer_button(page, True)
            offer["can_answer"] = bool(await button.count()) and await button.is_enabled()
        except Exception as error:  # the list is still worth having
            print(f"Offre {offer['store']} du {offer['date']} : détail illisible ({type(error).__name__}).")
        await page.goto(OFFERS, wait_until="networkidle", timeout=60_000)
        await page.get_by_text(OFFER_DAY).first.wait_for(timeout=20_000)
        await scroll_list(page)
    return offers


async def scroll_list(page) -> None:
    """Cards may load as the list scrolls."""
    for _ in range(5):
        await page.mouse.wheel(0, 4000)
        await page.wait_for_timeout(800)


HOURS = re.compile(r"de (\d{1,2}:\d{2}) à (\d{1,2}:\d{2})")


def parse_offer_page(text: str) -> dict:
    """An offer's page: "Mar. 3 Nov. de 05:00 à 08:30", and the red "Attention vous avez une autre
    mission déjà prévue à cette période : …" when it clashes."""
    found = {}
    if match := HOURS.search(text):
        found["start"], found["end"] = match.groups()
    if (start := text.find("Attention")) >= 0:
        warning = text[start:].split("\nRefuser")[0].split("\nAccepter")[0]
        found["portal_conflict"] = " ".join(warning.split())[:400]
    return found


def answer_button(page, accept: bool):
    name = re.compile(r"^\s*Accepter la mission\s*$" if accept else r"^\s*Refuser\s*$", re.IGNORECASE)
    return page.get_by_role("button", name=name).first


# A confirmation the portal may ask for after the button: only these are pressed.
CONFIRM = re.compile(r"^\s*(oui|ok|confirmer|valider|accepter|refuser|je confirme)", re.IGNORECASE)
CANCEL = re.compile(r"annuler|non|fermer|retour", re.IGNORECASE)


async def answer_offer(page, request: dict) -> tuple[bool, str]:
    """Gives the user's answer to one offer, after their "Oui" in the app (one per offer).
    Checks it is the same offer, presses its one button, confirms the portal's own confirmation if
    it asks; backs off, and says why, if the portal wants anything else (a reason…)."""
    accept = request["answer"] == "accept"
    await page.goto(PORTAL + "#" + request["link"], wait_until="networkidle", timeout=60_000)
    try:
        await page.get_by_text(re.compile(r"Accepter la mission|Refuser")).first.wait_for(timeout=30_000)
    except PlaywrightTimeout:
        return False, "L'offre n'est plus dans le portail (déjà répondue ou retirée)."
    text = await page.locator("body").inner_text()
    if request["store"].lower() not in text.lower():
        return False, "Le portail montre une autre offre à cette adresse : rien n'a été fait."
    button = answer_button(page, accept)
    if not await button.count() or not await button.is_enabled():
        return False, "Le portail bloque la réponse (conflit avec une autre mission) : rien n'a été fait."
    await button.click()
    await page.wait_for_timeout(2_000)
    dialog = page.locator("mat-dialog-container, [role=dialog], [role=alertdialog]").last
    if await dialog.count() and await dialog.is_visible():
        if await dialog.locator("textarea, select, mat-select, input[type=text], input[type=radio]").count():
            cancel = dialog.get_by_role("button", name=CANCEL).first
            if await cancel.count():
                await cancel.click()
            return False, "Le portail demande des précisions (motif…) : réponds dans le portail. Rien n'a été envoyé."
        buttons = dialog.locator("button")
        names = [" ".join((await buttons.nth(i).inner_text()).split()) for i in range(await buttons.count())]
        choice = next((i for i, name in enumerate(names) if CONFIRM.search(name)), None)
        if choice is None:
            return False, f"Confirmation du portail non reconnue ({', '.join(names)}) : réponds dans le portail."
        await buttons.nth(choice).click()
        await page.wait_for_timeout(2_000)
    # Proof: the offer left the list of those waiting for an answer.
    remaining = await read_waiting_list(page)
    if any(o["store"] == request["store"] and o["date"] == request["date"] for o in remaining):
        return False, "Le portail n'a pas confirmé la réponse : vérifie dans le portail."
    return True, "Mission acceptée dans le portail." if accept else "Offre refusée dans le portail."


async def read_waiting_list(page) -> list[dict]:
    await page.goto(OFFERS, wait_until="networkidle", timeout=60_000)
    await page.get_by_text(re.compile(r"Attente de r[ée]ponse")).first.wait_for(timeout=30_000)
    try:
        await page.get_by_text(OFFER_DAY).first.wait_for(timeout=15_000)
    except PlaywrightTimeout:
        pass
    await scroll_list(page)
    return parse_offers(await page.locator("body").inner_text())


ACCEPT = re.compile(r"accept|j.accepte|valider|^ok$|continuer|j.ai lu|compris|confirmer", re.IGNORECASE)


async def accept_terms_window(page) -> None:
    """The terms window the portal may show at sign-in ("Instructions et engagements…"):
    scroll it to the end (some accept controls wait for that), tick its box if it has one,
    then press its accept button."""
    title = page.get_by_text(re.compile(r"Instructions et engagements", re.IGNORECASE)).first
    if not await title.count() or not await title.is_visible():
        return
    window = page.locator("mat-dialog-container, [role=dialog], .cdk-overlay-pane").filter(
        has_text=re.compile(r"Instructions et engagements", re.IGNORECASE)).last
    if not await window.count():
        window = page.locator("body")
    await window.evaluate("w => w.querySelectorAll('*').forEach(e => {"
                          " if (e.scrollHeight > e.clientHeight) e.scrollTop = e.scrollHeight; })")
    await page.wait_for_timeout(1_000)
    boxes = window.get_by_role("checkbox")
    for index in range(await boxes.count()):
        if not await boxes.nth(index).is_checked():
            await boxes.nth(index).check(force=True)
    await page.wait_for_timeout(500)
    controls = window.locator("button, a, [role=button], .mat-button, .mat-raised-button, .mat-flat-button")
    names = []
    for index in range(await controls.count()):
        control = controls.nth(index)
        names.append(" ".join(((await control.inner_text()) or (await control.get_attribute("aria-label")) or "").split()))
    print(f"Fenêtre des CGU, boutons : {names}")
    for index, name in enumerate(names):
        if ACCEPT.search(name):
            await controls.nth(index).click(force=True)
            await page.wait_for_timeout(1_500)
            return
    html = await window.evaluate("w => w.outerHTML")
    print("--- Fin du code de la fenêtre des CGU ---")
    print(re.sub(r"\s+", " ", html)[-2500:])
    raise RuntimeError(f"Fenêtre des CGU : aucun bouton d'acceptation reconnu parmi {names}.")


async def sign_in(page, password) -> None:
    """The portal's sign-in form: login, password, the terms box (required at each sign-in,
    the same one the user ticks), then "Valider"."""
    login = page.locator("input[type=text], input[type=email], input:not([type])").first
    await login.fill(LOGIN)
    await password.first.fill(PASSWORD)
    # The box itself, not its label: the label holds a link that opens the terms instead.
    boxes = page.get_by_role("checkbox")
    terms = page.get_by_role("checkbox", name=re.compile(r"accepte", re.IGNORECASE))
    box = terms.first if await terms.count() else boxes.last
    if await boxes.count():
        await box.check(force=True)
        await page.wait_for_timeout(1_000)
    # Ticking the box may open the terms window: accept it like the user does.
    await accept_terms_window(page)
    button = page.get_by_role("button", name=re.compile(r"Valider", re.IGNORECASE)).first
    for _ in range(20):
        if await button.count() and await button.is_enabled():
            break
        await page.wait_for_timeout(500)
    else:
        filled = {"identifiant": bool(await login.input_value()), "mot de passe": bool(await password.first.input_value()),
                  "case CGU": await box.is_checked() if await boxes.count() else False}
        missing = ", ".join(name for name, ok in filled.items() if not ok) or "aucun champ vide repéré"
        raise RuntimeError(f"Le bouton Valider reste grisé ({missing}).")
    await button.click()
    # The portal can take a while: the terms window may appear late, then the form goes away.
    for _ in range(30):
        await page.wait_for_timeout(1_000)
        await accept_terms_window(page)
        if not await page.locator("input[type=password]:visible").count():
            await page.wait_for_load_state("networkidle", timeout=60_000)
            return
    raise RuntimeError("Connexion refusée ou trop lente (30 s) : vérifie l'identifiant et le mot de passe "
                       "dans rma.env, ou réessaie.")


# The value behind each view of the portal's list.
VIEW_VALUES = {"Sem.": "S", "Mois": "M", "∞": "TOUS"}


async def show(page, view: str) -> bool:
    """Selects a view of the list ("Sem.", "Mois", "∞"). The real radio input is hidden behind
    its drawing (Angular Material), so the drawn button around it is clicked."""
    radio = page.locator(f"input[type=radio][value='{VIEW_VALUES[view]}']").first
    if not await radio.count():
        return False
    if not await radio.is_checked():
        await radio.locator("xpath=ancestor::mat-radio-button[1]").click()
        await page.wait_for_timeout(500)
    if not await radio.is_checked():
        await radio.dispatch_event("click")
        await page.wait_for_timeout(500)
    if not await radio.is_checked():
        print(f"Vue « {view} » : impossible de la sélectionner.")
        return False
    await page.wait_for_load_state("networkidle", timeout=30_000)
    await page.wait_for_timeout(1_500)
    return True


async def wait_for_missions(page, seconds: int = 30) -> bool:
    """Waits until a mission's time slot ("26/10/2026 20:00 - 23:00") is on the page."""
    try:
        await page.get_by_text(SLOT).first.wait_for(timeout=seconds * 1000)
        return True
    except PlaywrightTimeout:
        return False


async def signed_in(page) -> None:
    """Opens the portal and signs in when it asks."""
    await page.goto(MISSIONS, wait_until="networkidle", timeout=60_000)
    password = page.locator("input[type=password]")
    if await password.count():
        await sign_in(page, password)
        await page.goto(HOME, wait_until="networkidle", timeout=60_000)
        await page.wait_for_timeout(5_000)


async def pending_answers() -> list[dict]:
    """Answers the user confirmed in the app ("Oui"), waiting to be given in the portal."""
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(f"{MARCEL_URL}/v1/offers/answers", headers={"X-Planning-Key": PLANNING_KEY})
        resp.raise_for_status()
        return resp.json()


async def give_answers(requests: list[dict]) -> None:
    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch()
        page = await browser.new_page(locale="fr-FR", timezone_id="Europe/Paris")
        try:
            await signed_in(page)
            for request in requests:
                try:
                    ok, message = await answer_offer(page, request)
                except Exception as error:
                    ok, message = False, f"Réponse impossible ({type(error).__name__}) : réponds dans le portail."
                print(f"Offre {request['store']} du {request['date']} : {message}")
                async with httpx.AsyncClient(timeout=10) as client:
                    await client.post(f"{MARCEL_URL}/v1/offers/{request['id']}/answered",
                                      json={"ok": ok, "message": message}, headers={"X-Planning-Key": PLANNING_KEY})
        finally:
            await browser.close()


async def read(debug: bool = False) -> list[dict]:
    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch()
        page = await browser.new_page(locale="fr-FR", timezone_id="Europe/Paris")
        exchanges: list[str] = []
        if debug:
            # What the portal asks its server (path and status only: no tokens, no content).
            def note(response):
                if response.request.resource_type in ("xhr", "fetch"):
                    path = response.url.split("?")[0].replace(PORTAL, "/")
                    exchanges.append(f"{response.request.method} {path} → {response.status}")
            page.on("response", note)
        try:
            await page.goto(MISSIONS, wait_until="networkidle", timeout=60_000)
            password = page.locator("input[type=password]")
            if await password.count():
                await sign_in(page, password)
                # Like a person: the home page first, which lets the portal sync the missions.
                await page.goto(HOME, wait_until="networkidle", timeout=60_000)
                await page.wait_for_timeout(8_000)
                await page.goto(MISSIONS, wait_until="networkidle", timeout=60_000)
                await page.wait_for_timeout(3_000)
            if debug:
                radios = page.get_by_role("radio")
                names = [await radios.nth(i).get_attribute("aria-label") or await radios.nth(i).get_attribute("value")
                         for i in range(await radios.count())]
                print(f"Choix de vue trouvés : {names}")
            missions: dict[tuple, dict] = {}
            for view in VIEWS:
                # Only the view selector at the top of the list is ever clicked.
                if not await show(page, view):
                    print(f"Vue « {view} » introuvable sur la page.")
                    continue
                # A new browser first downloads the missions (the portal works offline).
                if not await wait_for_missions(page, 20):
                    print(f"Vue « {view} » : aucune mission affichée.")
                text = await page.locator("body").inner_text()
                for mission in parse(text):
                    missions[(mission["date"], mission["start"], mission["store"])] = mission
            try:
                OFFERS_READ[:] = [await read_offers(page)]
            except Exception as error:  # the planning still goes through
                print(f"Lecture des recrutements impossible : {type(error).__name__}: {error}")
                OFFERS_READ[:] = [None]
            if debug:
                DATA.mkdir(parents=True, exist_ok=True)
                await page.screenshot(path=str(DATA / "rma-debug.png"), full_page=True)
                print("--- Texte visible de la page (sans les identifiants) ---")
                print(text[:4000])
                print("--- Texte de la page des recrutements ---")
                print(OFFERS_TEXT[0][:3000] or "(page non lue)")
                print("--- Capture : /data/rma-debug.png ---")
                print("--- Échanges du portail avec son serveur ---")
                print("\n".join(exchanges[-60:]) or "(aucun)")
            return list(missions.values())
        except Exception:
            if debug:
                DATA.mkdir(parents=True, exist_ok=True)
                await page.screenshot(path=str(DATA / "rma-debug.png"), full_page=True)
                print("--- Texte visible au moment de l'échec ---")
                print((await page.locator("body").inner_text())[:4000])
            raise
        finally:
            await browser.close()


# What read() found on the recruitment page (None: not read), handed to once().
OFFERS_READ: list = [None]


async def send_offers(offers: list[dict]) -> None:
    async with httpx.AsyncClient(timeout=20) as client:
        resp = await client.put(f"{MARCEL_URL}/v1/offers", json={"offers": offers},
                                headers={"X-Planning-Key": PLANNING_KEY})
        resp.raise_for_status()
        print(f"Marcel a enregistré {resp.json().get('count', len(offers))} offre(s) en attente.")


async def send(missions: list[dict]) -> None:
    async with httpx.AsyncClient(timeout=20) as client:
        resp = await client.put(f"{MARCEL_URL}/v1/planning", json={"missions": missions},
                                headers={"X-Planning-Key": PLANNING_KEY})
        resp.raise_for_status()
        print(f"Marcel a enregistré {resp.json().get('count', len(missions))} mission(s).")


# How many missions the last reading found, for the report to Marcel.
LAST_COUNT: list = [None]


async def once(debug: bool = False) -> int:
    if not LOGIN or not PASSWORD or not PLANNING_KEY:
        print("RMA_LOGIN, RMA_PASSWORD et MARCEL_PLANNING_KEY sont nécessaires (rma.env).")
        return 1
    missions = await read(debug)
    LAST_COUNT[:] = [len(missions)]
    print(f"{len(missions)} mission(s) lue(s) :")
    for mission in sorted(missions, key=lambda m: (m["date"][6:], m["date"][3:5], m["date"][:2], m["start"])):
        print(f"- {mission['date']} {mission['start']}-{mission['end']} · {mission['store']} · {mission['client']}")
    offers = OFFERS_READ[0]
    if offers is not None:
        print(f"{len(offers)} offre(s) de recrutement en attente :")
        for offer in offers:
            hours = f" {offer['start']}-{offer['end']}" if offer.get("start") else ""
            clash = " · ⚠️ conflit" if offer.get("portal_conflict") else ""
            print(f"- {offer['date']}{hours} · {offer['store']} · {offer['kind']} · {offer['client']}{clash}")
    if debug and "--send" not in sys.argv:
        print("(--debug : rien n'est envoyé à Marcel ; ajoute --send pour envoyer)")
        return 0
    if not missions:
        print("Aucune mission lue : rien n'est envoyé, pour ne pas effacer le planning connu.")
        return 1
    await send(missions)
    if offers is not None:
        await send_offers(offers)
    return 0


async def config() -> dict:
    """The reading hour set in the app (Planning assistant; RMA_HOUR when Marcel can't be
    reached) and whether a reading was asked for right now."""
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(f"{MARCEL_URL}/v1/planning/config", headers={"X-Planning-Key": PLANNING_KEY})
            resp.raise_for_status()
            data = resp.json()
            return {"hour": int(data["hour"]), "read_now": bool(data.get("read_now"))}
    except Exception:
        return {"hour": HOUR, "read_now": False}


async def report(ok: bool, message: str = "", missions: int | None = None, offers: int | None = None) -> None:
    """Tells Marcel how the reading went: the assistants can then explain it to the user."""
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            await client.post(f"{MARCEL_URL}/v1/robot/report", headers={"X-Planning-Key": PLANNING_KEY},
                              json={"ok": ok, "message": message[:500], "missions": missions, "offers": offers})
    except Exception as error:
        print(f"Compte rendu non transmis à Marcel : {type(error).__name__}")


async def run() -> None:
    OFFERS_READ[:] = [None]
    try:
        code = await once()
    except Exception as error:  # the next run tries again
        print(f"Lecture du planning impossible : {type(error).__name__}: {error}")
        await report(False, f"{type(error).__name__} : {error}")
        return
    offers = OFFERS_READ[0]
    await report(code == 0, "" if code == 0 else "aucune mission lue sur le portail (planning connu gardé)",
                 LAST_COUNT[0], None if offers is None else len(offers))


async def forever() -> None:
    """Once at start, then every day at the hour set in the app, and at once when the app asks
    (an assistant's "Relire maintenant"). Every minute it also gives in the portal the answers to
    offers the user confirmed in the app."""
    await run()
    settings = await config()
    now = time.localtime()
    read_on = now.tm_yday if now.tm_hour >= settings["hour"] else None
    while True:
        await asyncio.sleep(60)
        # Answers to offers the user confirmed in the app, then a new reading (planning updated).
        try:
            if requests := await pending_answers():
                await give_answers(requests)
                await run()
        except Exception as error:
            print(f"Réponses aux offres impossibles : {type(error).__name__}: {error}")
        settings = await config()
        now = time.localtime()
        if settings["read_now"]:
            print("Relecture demandée depuis l'app.")
            await run()
        elif now.tm_hour >= settings["hour"] and read_on != now.tm_yday:
            read_on = now.tm_yday
            await run()


if __name__ == "__main__":
    if "--once" in sys.argv or "--debug" in sys.argv:
        sys.exit(asyncio.run(once(debug="--debug" in sys.argv)))
    asyncio.run(forever())
