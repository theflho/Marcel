#!/usr/bin/env bash
# Met à jour Marcel sur le VPS : à lancer depuis backend/ (là où sont .env et le compose).
#   ./deploy/update.sh            reconstruit et redémarre Marcel (et llm-guard), puis teste /health
#   ./deploy/update.sh --try      lance aussi l'essai du filtre avec le vrai modèle
set -euo pipefail
cd "$(dirname "$0")/.."

# Docker may need sudo depending on how the session was opened.
docker() { if command docker info >/dev/null 2>&1; then command docker "$@"; else sudo docker "$@"; fi; }

git pull --ff-only
docker compose up -d --build

token=$(grep -E '^MARCEL_TOKEN=' .env | cut -d= -f2-)
for _ in $(seq 1 30); do
  if curl -fsS -H "Authorization: Bearer $token" http://127.0.0.1:8000/health; then
    echo
    echo "Marcel répond."
    break
  fi
  sleep 1
done

if [[ "${1:-}" == "--try" ]]; then
  docker compose exec marcel-api python -m app.try_proactive
fi
