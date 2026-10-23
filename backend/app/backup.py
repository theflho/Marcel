"""Writes a consistent copy of a data directory to stdout, as tar.gz:

    docker compose exec -T marcel-api python -m app.backup /data > marcel-data.tar.gz

SQLite databases are copied with SQLite's backup API, safe while Marcel is running; other files
(attachments, the Gmail token) are copied as they are. Used by deploy/backup.sh.
"""

import sqlite3
import sys
import tarfile
import tempfile
from pathlib import Path

# SQLite's side files: the backup API already includes what they hold.
SKIP_SUFFIXES = ("-wal", "-shm", "-journal")


def main() -> int:
    data = Path(sys.argv[1] if len(sys.argv) > 1 else "/data")
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


if __name__ == "__main__":
    sys.exit(main())
