#!/usr/bin/env bash
# Installe llm-guard sur le VPS, à lancer depuis backend/ :
#   ./deploy/install-guard.sh [tokens par jour]   installe (2 000 000 par défaut)
#   ./deploy/install-guard.sh --annuler <date>    remet les fichiers sauvegardés à cette date
#
# llm-guard devient le seul accès à Scaleway : la vraie clé Scaleway part dans guard.env,
# Hermes, hermes-checks et la mémoire de Marcel reçoivent chacun leur clé llm-guard.
# Chaque fichier modifié est d'abord copié en <fichier>.avant-guard-<date>.
set -euo pipefail
cd "$(dirname "$0")/.."

VAR=HERMES_CUSTOM_API_SCALEWAY_AI_API_KEY
SCALEWAY=https://api.scaleway.ai/v1
GUARD=http://llm-guard:4000/v1
FILES=("$HOME/.hermes/.env" "$HOME/.hermes/config.yaml" "$HOME/.hermes-checks/.env"
       "$HOME/.hermes-checks/config.yaml" "$PWD/.env" "$PWD/compose.yaml")
docker() { if command docker info >/dev/null 2>&1; then command docker "$@"; else sudo docker "$@"; fi; }

restart_all() {
  docker compose up -d --build
  (cd "$HOME/assistant" && docker compose restart hermes)
  docker restart hermes-checks
}

if [[ "${1:-}" == "--annuler" ]]; then
  stamp="${2:?date de la sauvegarde, ex. 20261023-201500}"
  for f in "${FILES[@]}"; do
    sudo cp -p "$f.avant-guard-$stamp" "$f"
  done
  mv guard.env "guard.env.annule-$stamp"
  docker rm -f llm-guard >/dev/null 2>&1 || true
  restart_all
  echo "Retour à l'état du $stamp fait."
  exit 0
fi

budget="${1:-2000000}"
if [[ -f guard.env ]]; then
  echo "guard.env existe déjà : llm-guard est déjà installé." >&2
  exit 1
fi
upstream=$(sudo grep -E "^$VAR=" "$HOME/.hermes/.env" | cut -d= -f2-)
if [[ -z "$upstream" || "$upstream" == guard-* ]]; then
  echo "Clé Scaleway introuvable dans ~/.hermes/.env ($VAR)." >&2
  exit 1
fi
k_hermes="guard-$(openssl rand -hex 24)"
k_checks="guard-$(openssl rand -hex 24)"
k_marcel="guard-$(openssl rand -hex 24)"

stamp=$(date +%Y%m%d-%H%M%S)
for f in "${FILES[@]}"; do
  sudo cp -p "$f" "$f.avant-guard-$stamp"
done

(umask 077; printf 'GUARD_UPSTREAM_URL=%s\nGUARD_UPSTREAM_KEY=%s\nGUARD_KEYS=hermes=%s,checks=%s,marcel=%s\nGUARD_DAILY_TOKENS=%s\nGUARD_CHECKS_SHARE=0.6\n' \
  "$SCALEWAY" "$upstream" "$k_hermes" "$k_checks" "$k_marcel" "$budget" > guard.env)
unset upstream

# Hermes and hermes-checks: their own guard key instead of the Scaleway key, and the guard's URL.
# sed -i writes a new file: give it back the original owner (the container's user) and mode.
edit() {
  sudo sed -i "$1" "$2"
  sudo chown --reference="$2.avant-guard-$stamp" "$2"
  sudo chmod --reference="$2.avant-guard-$stamp" "$2"
}
edit "s|^$VAR=.*|$VAR=$k_hermes|" "$HOME/.hermes/.env"
edit "s|$SCALEWAY|$GUARD|g" "$HOME/.hermes/config.yaml"
edit "s|^$VAR=.*|$VAR=$k_checks|" "$HOME/.hermes-checks/.env"
edit "s|$SCALEWAY|$GUARD|g" "$HOME/.hermes-checks/config.yaml"

sed -i -e '/^MARCEL_MEMORY_LLM_URL=/d' -e '/^MARCEL_MEMORY_LLM_KEY=/d' -e '/^MARCEL_GUARD_URL=/d' .env
printf 'MARCEL_MEMORY_LLM_URL=http://llm-guard:4000\nMARCEL_MEMORY_LLM_KEY=%s\nMARCEL_GUARD_URL=http://llm-guard:4000\n' "$k_marcel" >> .env
unset k_hermes k_checks k_marcel

cp deploy/compose.vps.yaml compose.yaml
restart_all
echo
echo "llm-guard installé, budget : $budget tokens par jour."
echo "Sauvegardes : *.avant-guard-$stamp"
echo "Pour revenir en arrière : ./deploy/install-guard.sh --annuler $stamp"
