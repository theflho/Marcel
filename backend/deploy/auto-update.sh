#!/usr/bin/env bash
# Déploie seul ce que Marcel fusionne dans main, et revient en arrière si le serveur ne répond plus.
# Sur le VPS, depuis backend/, toutes les 5 minutes (crontab -e) :
#   */5 * * * * cd ~/marcel/backend && ./deploy/auto-update.sh >> ~/marcel-auto-update.log 2>&1
# Applique aussi les réglages de Hermes que Marcel a changés (deploy/hermes-overrides.yaml, voir
# app/hermes_config.py) et ses skills, redémarre Hermes et remet l'ancienne config s'il ne répond
# plus. Conteneur de Hermes : MARCEL_HERMES_CONTAINER dans .env (hermes par défaut).
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

skills() {  # Les skills de Marcel pour Hermes (~/.hermes/skills/marcel/), lues au prochain lancement.
  # ~/.hermes appartient à l'utilisateur du conteneur Hermes (10000) : copie avec sudo, puis à lui.
  local owner
  owner=$(stat -c %u:%g "$HOME/.hermes")
  sudo mkdir -p "$HOME/.hermes/skills/marcel"
  sudo cp -R deploy/hermes-skills/. "$HOME/.hermes/skills/marcel/"
  sudo chown -R "$owner" "$HOME/.hermes/skills/marcel"
}

hermes_container=$(grep -E '^MARCEL_HERMES_CONTAINER=' .env | cut -d= -f2- || true)
hermes_container=${hermes_container:-hermes}

config_tool() {  # apply|restore … : app/hermes_config.py, avec ~/.hermes et deploy/ montés, sous l'utilisateur ubuntu
  docker compose run --rm --no-deps -T --user "$(id -u):$(id -g)" -v "$HOME/.hermes:/hermes" \
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
    [[ $skills_changed == 1 ]] || return 0
  elif ! applied=$(config_tool apply /deploy/hermes-overrides.yaml /hermes/config.yaml 2>"$work/config.err"); then
    local why
    why=$(grep -v -E '^ *(Container|Network|Volume) ' "$work/config.err" | tail -n 3)
    echo "$(date '+%F %T') config de Hermes non appliquée : $why"
    echo "$overlay" >> .hermes-overrides-refused
    report skipped "$target" "Config de Hermes non appliquée : ${why:0:400}"
    return 0
  fi
  [[ "$(tail -n 1 <<< "${applied:-}")" == changed ]] && config_changed=1
  [[ $config_changed == 1 || $skills_changed == 1 ]] || return 0
  echo "$(date '+%F %T') Hermes redémarre (config changée : $config_changed, skills changées : $skills_changed)."
  docker restart "$hermes_container" >/dev/null
  if hermes_answers; then
    report deployed "$target" "Hermes redémarré avec sa nouvelle config"
    return 0
  fi
  local hermes_log
  hermes_log=$(docker logs --tail 80 "$hermes_container" 2>&1 || true)
  if [[ $config_changed == 1 ]]; then
    config_tool restore /hermes/config.yaml >/dev/null 2>&1 || true
    echo "$overlay" >> .hermes-overrides-refused
    docker restart "$hermes_container" >/dev/null
    hermes_answers && report rolled_back "$target" "Hermes ne répondait plus avec la nouvelle config : ancienne remise" "$hermes_log" \
      || report failed "$target" "Hermes ne répond plus, même avec l'ancienne config" "$hermes_log"
  else
    report failed "$target" "Hermes ne répond plus après le changement de skills" "$hermes_log"
  fi
}

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
