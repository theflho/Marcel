#!/usr/bin/env bash
# Met à jour Marcel sur le VPS : à lancer depuis backend/ (là où sont .env et le compose).
#   ./deploy/update.sh            reconstruit et redémarre marcel-api, puis teste /health
#   ./deploy/update.sh --try      lance aussi l'essai du filtre avec le vrai modèle
set -euo pipefail
cd "$(dirname "$0")/.."

git pull --ff-only
docker compose up -d --build marcel-api

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
