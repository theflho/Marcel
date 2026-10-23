"""Reads the user's RMA missions (merchandising planning) and hands them to Marcel. Read only.

It opens the employee portal in an invisible browser, signs in, shows the missions for the week
and the month, reads the cards (store, kind, date, hours, client) and sends them to Marcel.
It never opens a mission and never touches the time clock: clocking in stays the user's own act,
on site, from their phone.

    python planning.py              runs every day at RMA_HOUR (and once at start)
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
MISSIONS = PORTAL + "#/accueil/missions"
LOGIN = os.environ.get("RMA_LOGIN", "")
PASSWORD = os.environ.get("RMA_PASSWORD", "")
MARCEL_URL = os.environ.get("MARCEL_URL", "http://marcel-api:8000").rstrip("/")
PLANNING_KEY = os.environ.get("MARCEL_PLANNING_KEY", "")
HOUR = int(os.environ.get("RMA_HOUR") or 19)
DATA = Path(os.environ.get("RMA_DATA_DIR", "/data"))
# The views the portal offers; the week and the month together cover what's coming.
VIEWS = ("Sem.", "Mois", "∞")
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


async def show(page, view: str) -> bool:
    """Selects a view of the list ("Sem.", "Mois", "∞"): the radio button itself, not its text."""
    radio = page.get_by_role("radio", name=view, exact=True)
    if await radio.count():
        await radio.first.check(force=True)
    else:
        option = page.locator("mat-radio-button, label").filter(has_text=re.compile(rf"^\s*{re.escape(view)}\s*$"))
        if not await option.count():
            return False
        await option.first.click(force=True)
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


async def read(debug: bool = False) -> list[dict]:
    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch()
        page = await browser.new_page(locale="fr-FR", timezone_id="Europe/Paris")
        try:
            await page.goto(MISSIONS, wait_until="networkidle", timeout=60_000)
            password = page.locator("input[type=password]")
            if await password.count():
                await sign_in(page, password)
                await page.goto(MISSIONS, wait_until="networkidle", timeout=60_000)
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
            if debug:
                DATA.mkdir(parents=True, exist_ok=True)
                await page.screenshot(path=str(DATA / "rma-debug.png"), full_page=True)
                print("--- Texte visible de la page (sans les identifiants) ---")
                print(text[:4000])
                print("--- Capture : /data/rma-debug.png ---")
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


async def send(missions: list[dict]) -> None:
    async with httpx.AsyncClient(timeout=20) as client:
        resp = await client.put(f"{MARCEL_URL}/v1/planning", json={"missions": missions},
                                headers={"X-Planning-Key": PLANNING_KEY})
        resp.raise_for_status()
        print(f"Marcel a enregistré {resp.json().get('count', len(missions))} mission(s).")


async def once(debug: bool = False) -> int:
    if not LOGIN or not PASSWORD or not PLANNING_KEY:
        print("RMA_LOGIN, RMA_PASSWORD et MARCEL_PLANNING_KEY sont nécessaires (rma.env).")
        return 1
    missions = await read(debug)
    print(f"{len(missions)} mission(s) lue(s) :")
    for mission in sorted(missions, key=lambda m: (m["date"][6:], m["date"][3:5], m["date"][:2], m["start"])):
        print(f"- {mission['date']} {mission['start']}-{mission['end']} · {mission['store']} · {mission['client']}")
    if debug and "--send" not in sys.argv:
        print("(--debug : rien n'est envoyé à Marcel ; ajoute --send pour envoyer)")
        return 0
    if not missions:
        print("Aucune mission lue : rien n'est envoyé, pour ne pas effacer le planning connu.")
        return 1
    await send(missions)
    return 0


async def forever() -> None:
    while True:
        try:
            await once()
        except Exception as error:  # the next run tries again
            print(f"Lecture du planning impossible : {type(error).__name__}: {error}")
        now = time.localtime()
        target = time.mktime((now.tm_year, now.tm_mon, now.tm_mday, HOUR, 0, 0, 0, 0, -1))
        if target <= time.time():
            target += 86_400
        await asyncio.sleep(target - time.time())


if __name__ == "__main__":
    if "--once" in sys.argv or "--debug" in sys.argv:
        sys.exit(asyncio.run(once(debug="--debug" in sys.argv)))
    asyncio.run(forever())
