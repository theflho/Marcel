"""Writes a consistent copy of a data directory to stdout, as tar.gz, and checks one:

    docker compose exec -T marcel-api python -m app.backup /data > marcel-data.tar.gz
    python -m app.backup check marcel-data.tar.gz      (or a folder, or - for stdin)

SQLite databases are copied with SQLite's backup API, safe while Marcel is running; other files
(attachments, the Gmail token) are copied as they are. Used by deploy/backup.sh and restore.sh.

The check opens every database of the copy, runs SQLite's integrity check and counts what
matters (memories, missions, planning…): a backup that can't be read is said at once, not on
the day it's needed.
"""

import sqlite3
import sys
import tarfile
import tempfile
from pathlib import Path

# SQLite's side files: the backup API already includes what they hold.
SKIP_SUFFIXES = ("-wal", "-shm", "-journal")
# What the check counts, by table, with the words it prints.
COUNTED = {"memories": "souvenirs", "missions": "réponses", "planning": "missions RMA", "goals": "objectifs",
           "ideas": "idées", "routines": "routines", "custom_assistants": "assistants créés", "offers": "offres",
           "vectors": "vecteurs", "usage": "lignes de consommation"}


def write(data: Path) -> int:
    with tempfile.TemporaryDirectory() as tmp, tarfile.open(fileobj=sys.stdout.buffer, mode="w|gz") as tar:
        for path in sorted(data.rglob("*")):
            if not path.is_file() or path.name.endswith(SKIP_SUFFIXES):
                continue
            name = str(path.relative_to(data))
            if path.suffix == ".db":
                copy = Path(tmp) / path.name
                source, target = sqlite3.connect(path), sqlite3.connect(copy)
                source.backup(target)
                target.close()
                source.close()
                tar.add(copy, arcname=name)
            else:
                tar.add(path, arcname=name)
    return 0


def check_folder(folder: Path) -> list[str]:
    """Problems found in the folder's databases (empty if all is well); prints what they hold."""
    problems = []
    databases = sorted(folder.rglob("*.db"))
    if not databases:
        return ["aucune base de données dans la sauvegarde"]
    for path in databases:
        try:
            db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            (verdict,) = db.execute("PRAGMA integrity_check").fetchone()
            tables = {name for (name,) in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
            counts = [f"{db.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0]} {label}"
                      for table, label in COUNTED.items() if table in tables]
            db.close()
        except sqlite3.Error as error:
            problems.append(f"{path.name} illisible : {error}")
            continue
        if verdict != "ok":
            problems.append(f"{path.name} abîmée : {verdict}")
        print(f"{path.relative_to(folder)} : {verdict}" + (f" — {', '.join(counts)}" if counts else ""))
    return problems


def check(source: str) -> int:
    with tempfile.TemporaryDirectory() as tmp:
        if source != "-" and Path(source).is_dir():
            folder = Path(source)
        else:
            stream = sys.stdin.buffer if source == "-" else open(source, "rb")
            with stream, tarfile.open(fileobj=stream, mode="r|gz") as tar:
                tar.extractall(tmp, filter="data")
            folder = Path(tmp)
        problems = check_folder(folder)
    for problem in problems:
        print(f"PROBLÈME : {problem}", file=sys.stderr)
    return 1 if problems else 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "check":
        return check(sys.argv[2] if len(sys.argv) > 2 else "-")
    return write(Path(sys.argv[1] if len(sys.argv) > 1 else "/data"))


if __name__ == "__main__":
    sys.exit(main())
