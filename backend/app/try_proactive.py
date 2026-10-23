"""Tries proactive Marcel against the real models, on the VPS, without touching Marcel's data.

    docker compose exec marcel-api python -m app.try_proactive            # the filter only
    docker compose exec marcel-api python -m app.try_proactive --check "Trouver un Mac mini"

The filter part sends three sample reports to the memory model and checks that each answer is
valid JSON with a known decision. --check also runs a real check through the checks' Hermes
(MARCEL_CHECK_HERMES_URL) and lists the tools it called, to see that none of them acts outside.
"""

import asyncio
import os
import sys
import tempfile
import time

# A throwaway data directory: importing the app must not mark the real missions as interrupted.
os.environ["MARCEL_DATA_DIR"] = tempfile.mkdtemp(prefix="marcel-try-")
os.environ.setdefault("MARCEL_TOKEN", "try")

from . import main  # noqa: E402

SAMPLES = [
    ("notify", "Trouver un Mac mini", "moins de 700 €",
     "Le Mac mini M4 16 Go est à 599 € chez Boulanger jusqu'à dimanche (prix habituel 719 €). "
     "Stock limité. Source : boulanger.com, vérifié aujourd'hui."),
    ("nothing", "Trouver un Mac mini", "moins de 700 €",
     "Aucun changement : le Mac mini M4 reste à 719 € partout (Apple, Fnac, Amazon). Pas de promotion."),
    ("later", "Préparer le voyage à Lisbonne", "en mai",
     "Les vols Paris-Lisbonne de mai sont autour de 140 € aller-retour, comme la semaine dernière. "
     "Les hôtels du centre commencent à se remplir pour le week-end du 1er mai."),
]
DECISIONS = {"notify", "later", "nothing"}
KEYS = {"decision", "title", "message", "action", "importance", "note"}


async def try_filter() -> bool:
    print(f"Filtre : modèle {main.MEMORY_LLM_MODEL} sur {main.MEMORY_LLM_URL}\n")
    ok = True
    for expected, title, detail, report in SAMPLES:
        user = (f"Objectif : {title} ({detail})\n\nCe qu'on savait déjà :\n(rien)\n\n"
                f"Idées déjà refusées par l'utilisateur :\n(aucune)\n\nCompte rendu de la vérification :\n{report}")
        started = time.monotonic()
        try:
            verdict = await main.llm_json(main.FILTER_PROMPT, user)
        except Exception as error:
            print(f"ÉCHEC « {title} » : {type(error).__name__}: {error}\n")
            ok = False
            continue
        problems = []
        if verdict.get("decision") not in DECISIONS:
            problems.append(f"décision inconnue {verdict.get('decision')!r}")
        if missing := KEYS - verdict.keys():
            problems.append(f"clés manquantes {sorted(missing)}")
        ok = ok and not problems
        print(f"{'OK' if not problems else 'PROBLÈME'} ({time.monotonic() - started:.1f} s) — attendu plutôt "
              f"{expected}, reçu {verdict.get('decision')}" + (f" ; {', '.join(problems)}" if problems else ""))
        print(f"  {verdict}\n")
    return ok


async def try_check(title: str) -> None:
    print(f"Vérification : {main.CHECK_HERMES_URL} (modèle {main.CHECK_HERMES_MODEL or 'par défaut'})\n")
    goal = main.goals.add(title, cadence="manual")
    mission, finished = await main.run_check(goal)
    await finished
    print(f"Statut : {mission.status}" + (f" ({mission.error})" if mission.error else ""))
    print("Outils appelés : " + (", ".join(a.get("name") or "?" for a in mission.actions) or "aucun"))
    print(f"\nCompte rendu :\n{mission.text}\n")
    for check in main.ideas.checks(goal.id):
        print(f"Décision du filtre : {check['decision']} — {check['summary']}")
    for idea in main.ideas.list(goal_id=goal.id):
        print(f"Idée : {idea.title}\n  {idea.body}\n  Action préparée : {idea.action or '(aucune)'}")


async def run() -> int:
    if main.MOCK:
        print("MARCEL_MOCK=1 : rien à essayer avec le vrai modèle.")
        return 1
    ok = await try_filter()
    if "--check" in sys.argv:
        index = sys.argv.index("--check")
        await try_check(sys.argv[index + 1] if len(sys.argv) > index + 1 else "Trouver un Mac mini")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(run()))
