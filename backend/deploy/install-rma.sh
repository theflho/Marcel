#!/usr/bin/env bash
# Installe le robot de lecture du planning RMA, à lancer depuis backend/ :
#   ./deploy/install-rma.sh
# Demande l'identifiant et le mot de passe RMA (le mot de passe ne s'affiche pas), les range
# dans rma.env (lisible par toi seul), donne au robot sa propre clé pour remettre le planning
# à Marcel, démarre le robot puis fait une première lecture d'essai, sans rien envoyer.
set -euo pipefail
cd "$(dirname "$0")/.."
docker() { if command docker info >/dev/null 2>&1; then command docker "$@"; else sudo docker "$@"; fi; }

if [[ -f rma.env ]]; then
  echo "rma.env existe déjà : identifiants gardés (supprime rma.env pour les changer)."
else
  read -r -p "Identifiant RMA : " login
  read -r -s -p "Mot de passe RMA (invisible) : " password; echo
  if [[ "$password$login" == *"'"* ]]; then
    echo "Une apostrophe (') dans l'identifiant ou le mot de passe n'est pas gérée : arrêt." >&2
    exit 1
  fi
  key=$(openssl rand -hex 32)
  # Single quotes: Compose takes the values as they are, even with $ or spaces.
  (umask 077; printf "RMA_LOGIN='%s'\nRMA_PASSWORD='%s'\nMARCEL_PLANNING_KEY=%s\n" "$login" "$password" "$key" > rma.env)
  sed -i '/^MARCEL_PLANNING_KEY=/d' .env
  echo "MARCEL_PLANNING_KEY=$key" >> .env
  unset login password key
fi

cp deploy/compose.vps.yaml compose.yaml
docker compose up -d --build marcel-api rma
echo
echo "Première lecture d'essai (rien n'est envoyé à Marcel) :"
docker compose run --rm rma python planning.py --debug
echo
echo "Si les missions affichées sont justes : docker compose run --rm rma python planning.py --once"
echo "Ensuite le robot relit le planning tout seul chaque jour à 19 h."
