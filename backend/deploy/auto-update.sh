#!/usr/bin/env bash
# Déploie seul ce que Marcel fusionne dans main, et revient en arrière si le serveur ne répond plus.
# Sur le VPS, depuis backend/, toutes les 5 minutes (crontab -e) :
#   */5 * * * * cd ~/marcel/backend && ./deploy/auto-update.sh >> ~/marcel-auto-update.log 2>&1
# Applique aussi les réglages de Hermes que Marcel a changés (deploy/hermes-overrides.yaml, voir
# app/hermes_config.py) et ses skills, redémarre Hermes et remet l'ancienne config s'il ne répond
# plus. Où est Hermes, dans .env : MARCEL_HERMES_HOME (son dossier, /home/hermes/.hermes s'il existe,
# sinon ~/.hermes) et MARCEL_HERMES_SERVICE (service systemd de l'utilisateur à qui appartient ce
# dossier, hermes-gateway par défaut), ou MARCEL_HERMES_CONTAINER pour un Hermes en conteneur. Hermes redémarre
# après chaque déploiement : il se reconnecte ainsi au serveur MCP de Marcel, qui vient de redémarrer
# (sinon il peut perdre tous les outils marcel_*). Les missions en cours, elles, sont déjà coupées
# par le redémarrage de marcel-api.
# Rien ne part pendant l'arrêt d'urgence. Une version qui a raté n'est plus retentée
# (.auto-update-refused) ; la suivante, oui. Ce script est protégé : Marcel ne peut pas le modifier.
set -euo pipefail
cd "$(dirname "$0")/.."

exec 9>.auto-update.lock
flock -n 9 || exit 0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

docker() { if command docker info >/dev/null 2>&1; then command docker "$@"; else sudo docker "$@"; fi; }

token=$(grep -E '^MARCEL_TOKEN=' .env | cut -d= -f2-)
api=${MARCEL_API:-http://127.0.0.1:8000}

report() {  # status commit message [log]
  python3 -c 'import json,sys; print(json.dumps({"status":sys.argv[1],"commit":sys.argv[2],"message":sys.argv[3][:500],
    "log":(sys.argv[4] if len(sys.argv) > 4 else "")[-20000:]}))' "$@" > "$work/report.json"
  curl -fsS -m 10 -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    --data-binary "@$work/report.json" "$api/v1/deploy/report" >/dev/null || true
}

healthy() {
  for _ in $(seq 1 "${HEALTH_TRIES:-60}"); do
    curl -fsS -m 5 -H "Authorization: Bearer $token" "$api/health" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

setting() { grep -E "^$1=" .env | tail -n 1 | cut -d= -f2- || true; }

hermes_home=$(setting MARCEL_HERMES_HOME)
if [[ -z "$hermes_home" ]]; then
  if sudo test -d /home/hermes/.hermes; then hermes_home=/home/hermes/.hermes; else hermes_home=$HOME/.hermes; fi
fi
hermes_container=$(setting MARCEL_HERMES_CONTAINER)
hermes_service=$(setting MARCEL_HERMES_SERVICE)
hermes_service=${hermes_service:-hermes-gateway}
# Its folder belongs to Hermes' user (hermes, or 10000 in a container), not to ubuntu.
hermes_owner=$(sudo stat -c %u:%g "$hermes_home")

skills() {  # Les skills de Marcel pour Hermes (skills/marcel/ du profil principal et de ceux des bots).
  local home
  for home in "$hermes_home" $(sudo find "$hermes_home/profiles" -mindepth 1 -maxdepth 1 -type d -name 'marcel-*' 2>/dev/null); do
    sudo mkdir -p "$home/skills/marcel"
    sudo cp -R deploy/hermes-skills/. "$home/skills/marcel/"
    sudo chown -R "$hermes_owner" "$home/skills/marcel"
  done
}

restart_hermes() {  # its container if there is one, else its user's systemd service
  if [[ -n "$hermes_container" ]]; then
    docker restart "$hermes_container" >/dev/null
  else
    local user
    user=$(sudo stat -c %U "$hermes_home")
    sudo systemctl --machine="$user@" --user restart "$hermes_service"
  fi
}

hermes_logs() {
  if [[ -n "$hermes_container" ]]; then
    docker logs --tail 80 "$hermes_container" 2>&1 || true
  else
    sudo journalctl --no-pager -n 80 _UID="$(sudo stat -c %u "$hermes_home")" 2>&1 || true
  fi
}

hermes_cli() {  # une commande hermes, sous l'utilisateur de Hermes (ou dans son conteneur)
  if [[ -n "$hermes_container" ]]; then
    docker exec "$hermes_container" hermes "$@"
  else
    local bin
    bin=$(setting MARCEL_HERMES_BIN)
    bin=${bin:-$hermes_home/hermes-agent/.hermes/bin/hermes}
    sudo -u "$(sudo stat -c %U "$hermes_home")" env HERMES_HOME="$hermes_home" "$bin" "$@"
  fi
}

profiles_tool() {  # plan|prepare : app/hermes_profiles.py, avec la liste voulue et le dossier de Hermes montés
  docker compose run --rm --no-deps -T --user "$hermes_owner" -v "$hermes_home:/hermes" -v "$work:/work:ro" \
    marcel-api python -m app.hermes_profiles "$1" /work/profiles.json /hermes
}

profiles_sync() {  # Un profil Hermes par bot (app/hermes_profiles.py) : créés, finis, retirés.
  # Hermes les sert à chaud (gateway.multiplex_profiles) : aucun redémarrage.
  curl -fsS -m 10 -H "Authorization: Bearer $token" "$api/v1/hermes/profiles" -o "$work/profiles.json" 2>/dev/null \
    || return 0  # serveur arrêté, ou trop ancien pour les profils
  chmod 755 "$work" && chmod 644 "$work/profiles.json"
  local digest plan action name
  digest=$(cat "$work/profiles.json" <(sudo cat "$hermes_home/config.yaml") | sha256sum | cut -d' ' -f1)
  [[ "$digest" == "$(cat .hermes-profiles-applied 2>/dev/null)" ]] && return 0
  plan=$(profiles_tool plan 2>"$work/profiles.err") || { echo "$(date '+%F %T') profils : $(tail -n 2 "$work/profiles.err")"; return 0; }
  while read -r action name; do
    case "$action" in
      create) hermes_cli profile create "$name" --clone-from default --no-alias >/dev/null \
                && echo "$(date '+%F %T') profil Hermes créé : $name" ;;
      delete) hermes_cli profile delete -y "$name" >/dev/null \
                && echo "$(date '+%F %T') profil Hermes retiré : $name" ;;
    esac
  done <<< "$plan"
  profiles_tool prepare >/dev/null 2>>"$work/profiles.err" || { echo "$(date '+%F %T') profils : $(tail -n 2 "$work/profiles.err")"; return 0; }
  echo "$digest" > .hermes-profiles-applied
}

config_tool() {  # apply|restore … : app/hermes_config.py, avec le dossier de Hermes et deploy/ montés, sous son utilisateur
  docker compose run --rm --no-deps -T --user "$hermes_owner" -v "$hermes_home:/hermes" \
    -v "$PWD/deploy:/deploy:ro" marcel-api python -m app.hermes_config "$@"
}

hermes_answers() {
  for _ in $(seq 1 "${HEALTH_TRIES:-30}"); do
    docker compose exec -T marcel-api python -m app.hermes_config ping >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

hermes_update() {  # après un déploiement réussi de $current → $target
  local skills_changed=0 config_changed=0 applied overlay
  git diff --quiet "$current" "$target" -- deploy/hermes-skills || skills_changed=1
  skills
  # A config Hermes already refused isn't tried again; the next change of the file is.
  overlay=$(git hash-object deploy/hermes-overrides.yaml)
  if grep -qx "$overlay" .hermes-overrides-refused 2>/dev/null; then
    :
  elif ! applied=$(config_tool apply /deploy/hermes-overrides.yaml /hermes/config.yaml 2>"$work/config.err"); then
    local why
    why=$(grep -v -E '^ *(Container|Network|Volume) ' "$work/config.err" | tail -n 3)
    echo "$(date '+%F %T') config de Hermes non appliquée : $why"
    echo "$overlay" >> .hermes-overrides-refused
    report skipped "$target" "Config de Hermes non appliquée : ${why:0:400}"
  fi
  [[ "$(tail -n 1 <<< "${applied:-}")" == changed ]] && config_changed=1
  echo "$(date '+%F %T') Hermes redémarre (config changée : $config_changed, skills changées : $skills_changed)."
  restart_hermes
  if hermes_answers; then
    [[ $config_changed == 1 ]] && report deployed "$target" "Hermes redémarré avec sa nouvelle config"
    return 0
  fi
  local hermes_log
  hermes_log=$(hermes_logs)
  if [[ $config_changed == 1 ]]; then
    config_tool restore /hermes/config.yaml >/dev/null 2>&1 || true
    echo "$overlay" >> .hermes-overrides-refused
    restart_hermes
    hermes_answers && report rolled_back "$target" "Hermes ne répondait plus avec la nouvelle config : ancienne remise" "$hermes_log" \
      || report failed "$target" "Hermes ne répond plus, même avec l'ancienne config" "$hermes_log"
  else
    report failed "$target" "Hermes ne répond plus après le changement de skills" "$hermes_log"
  fi
}

profiles_sync || echo "$(date '+%F %T') profils : synchronisation ratée"

git fetch --quiet origin main
current=$(git rev-parse HEAD)
target=$(git rev-parse origin/main)
[[ "$current" == "$target" ]] && exit 0
if grep -qx "$target" .auto-update-refused 2>/dev/null; then exit 0; fi

if curl -fsS -m 10 -H "Authorization: Bearer $token" "$api/v1/emergency" 2>/dev/null | grep -q '"active": *true'; then
  echo "$(date '+%F %T') arrêt d'urgence actif : $target attendra."
  exit 0
fi

subject=$(git log -1 --format=%s "$target")
echo "$(date '+%F %T') déploiement de $target : $subject"
if git merge --ff-only --quiet "$target" && docker compose up -d --build > "$work/build.log" 2>&1 && healthy; then
  echo "$(date '+%F %T') déployé."
  report deployed "$target" "$subject"
  hermes_update
  exit 0
fi

echo "$(date '+%F %T') raté : retour à $current."
# What went wrong, for Marcel (marcel_journaux): the end of the build, then of the server's own log.
failure="$(tail -n 40 "$work/build.log" 2>/dev/null)
--- marcel-api ---
$(docker compose logs --no-color --tail 80 marcel-api 2>&1 || true)"
echo "$target" >> .auto-update-refused
git reset --hard --quiet "$current"
docker compose up -d --build
if healthy; then
  report rolled_back "$target" "$subject (revenu à ${current:0:7})" "$failure"
else
  echo "$(date '+%F %T') le serveur ne répond toujours pas après le retour arrière."
  report failed "$target" "$subject : le serveur ne répond plus, même revenu à ${current:0:7}" "$failure"
fi
exit 1
