#!/usr/bin/env bash
# Branche le Hermes principal sur les outils de Marcel (/mcp) et installe ses skills, une fois :
# sur le VPS, depuis backend/ :   ./deploy/connect-hermes.sh
# Crée MARCEL_MCP_TOKEN dans .env s'il manque, ajoute le serveur « marcel » au config.yaml de Hermes
# (copie de sauvegarde à côté), copie deploy/hermes-skills/, redémarre marcel-api et Hermes, puis
# affiche ce que Hermes voit. La clé n'est jamais affichée. Relancer ne duplique rien.
set -euo pipefail
cd "$(dirname "$0")/.."

docker() { if command docker info >/dev/null 2>&1; then command docker "$@"; else sudo docker "$@"; fi; }

hermes_home="$HOME/.hermes"
config="$hermes_home/config.yaml"
container=$(grep -E '^MARCEL_HERMES_CONTAINER=' .env | cut -d= -f2- || true)
container=${container:-hermes}
owner=$(sudo stat -c %u:%g "$hermes_home")
stamp=$(date +%Y%m%d-%H%M)

token=$(grep -E '^MARCEL_MCP_TOKEN=' .env | cut -d= -f2- || true)
if [[ -z "$token" ]]; then
  cp .env ".env.bak-$stamp"
  token=$(openssl rand -hex 32)
  if grep -q '^MARCEL_MCP_TOKEN=' .env; then
    sed -i "s/^MARCEL_MCP_TOKEN=.*/MARCEL_MCP_TOKEN=$token/" .env
  else
    printf '\nMARCEL_MCP_TOKEN=%s\n' "$token" >> .env
  fi
  echo "MARCEL_MCP_TOKEN créé dans .env (copie : .env.bak-$stamp)."
fi

if sudo grep -q '^mcp_servers:' "$config"; then
  echo "Hermes a déjà une section mcp_servers : vérifie qu'elle contient « marcel » (deploy/hermes-mcp.config.yaml)."
else
  sudo cp "$config" "$config.bak-$stamp"
  printf '\nmcp_servers:\n  marcel:\n    url: "http://marcel-api:8000/mcp"\n    headers:\n      Authorization: "Bearer %s"\n' \
    "$token" | sudo tee -a "$config" >/dev/null
  sudo chown "$owner" "$config"
  echo "Serveur « marcel » ajouté à $config (copie : config.yaml.bak-$stamp)."
fi

sudo mkdir -p "$hermes_home/skills/marcel"
sudo cp -R deploy/hermes-skills/. "$hermes_home/skills/marcel/"
sudo chown -R "$owner" "$hermes_home/skills/marcel"
echo "Skills copiées : $(sudo ls "$hermes_home/skills/marcel" | tr '\n' ' ')"

docker compose up -d marcel-api
sleep 5
docker restart "$container" >/dev/null
echo "Hermes redémarre…"
sleep 15
docker exec "$container" hermes mcp list || true

if ! grep -qE '^MARCEL_GITHUB_(REPO)=.+' .env || ! grep -qE '^MARCEL_GITHUB_(TOKEN)=.+' .env; then
  echo
  echo "Outils de code : MARCEL_GITHUB_REPO et MARCEL_GITHUB_TOKEN sont vides dans .env."
  echo "Sans eux, marcel_code_* répond « non branchés ». Voir .env.example, puis : docker compose up -d marcel-api"
fi
