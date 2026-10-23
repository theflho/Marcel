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
VIEWS = ("Sem.", "Mois")
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


async def read(debug: bool = False) -> list[dict]:
    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch()
        page = await browser.new_page(locale="fr-FR", timezone_id="Europe/Paris")
        try:
            await page.goto(MISSIONS, wait_until="networkidle", timeout=60_000)
            password = page.locator("input[type=password]")
            if await password.count():
                login = page.locator("input:not([type=password]):not([type=hidden]):visible").first
                await login.fill(LOGIN)
                await password.first.fill(PASSWORD)
                await password.first.press("Enter")
                await page.wait_for_load_state("networkidle", timeout=60_000)
                await page.goto(MISSIONS, wait_until="networkidle", timeout=60_000)
            missions: dict[tuple, dict] = {}
            for view in VIEWS:
                try:
                    # Only the view selector at the top of the list is ever clicked.
                    await page.get_by_text(view, exact=True).first.click(timeout=10_000)
                    await page.wait_for_timeout(2_500)
                except PlaywrightTimeout:
                    print(f"Vue « {view} » introuvable sur la page.")
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
