"""Connects Marcel to Gmail, read only, from the VPS:

    docker compose exec marcel-api python -m app.gmail_auth            # connect
    docker compose exec marcel-api python -m app.gmail_auth --check    # 3 latest subjects
    docker compose exec marcel-api python -m app.gmail_auth --revoke   # disconnect

Needs MARCEL_GOOGLE_CLIENT_ID and MARCEL_GOOGLE_CLIENT_SECRET (a "Desktop app" OAuth client
of your own Google Cloud project) in Marcel's .env.
"""

import asyncio
import os
import sys
from pathlib import Path

from .gmail import Gmail


async def run() -> int:
    gmail = Gmail(Path(os.environ.get("MARCEL_DATA_DIR", "/data")),
                  os.environ.get("MARCEL_GOOGLE_CLIENT_ID", ""), os.environ.get("MARCEL_GOOGLE_CLIENT_SECRET", ""))
    if not gmail.configured:
        print("MARCEL_GOOGLE_CLIENT_ID et MARCEL_GOOGLE_CLIENT_SECRET manquent dans .env.")
        return 1
    if "--revoke" in sys.argv:
        await gmail.disconnect()
        print("Accès à Gmail retiré.")
        return 0
    if "--check" in sys.argv:
        if not gmail.connected:
            print("Gmail n'est pas connecté.")
            return 1
        mails = await gmail.recent(limit=3)
        print(f"Connecté en lecture seule. {len(mails)} e-mail(s) récent(s) :")
        for mail in mails:
            print(f"- {mail['subject']}")
        return 0

    print("1. Ouvre cette adresse dans le navigateur de ton Mac (compte Google concerné) :\n")
    print(gmail.auth_url())
    print("\n2. Accepte « Afficher vos e-mails et vos paramètres » (lecture seule).")
    print("3. La page suivante ne s'ouvre pas (localhost) : c'est normal.")
    print("   Copie toute l'adresse de cette page et colle-la ici.\n")
    pasted = input("Adresse : ")
    try:
        await gmail.connect(pasted)
    except (ValueError, FileNotFoundError) as error:
        print(f"\nÉchec : {error}")
        return 1
    mails = await gmail.recent(limit=3)
    print(f"\nGmail connecté en lecture seule. Derniers sujets : {', '.join(m['subject'] for m in mails) or 'aucun'}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(run()))
