#!/usr/bin/env bash
# Sauvegarde chiffrée de Marcel sur le VPS, à lancer depuis backend/ :
#   ./deploy/backup.sh
# Contenu : base de Marcel (mémoire, objectifs, idées, missions), pièces jointes, accès Gmail,
# compteur de llm-guard, réglages (.env, guard.env, compose.yaml) et ~/.hermes-checks.
# Chiffrée pour la clé publique de ~/.age-recipient (la même que les sauvegardes de Hermes) :
# seule ~/hermes-backup.key (ou sa copie dans ton gestionnaire de mots de passe) peut l'ouvrir.
# Les 14 dernières sont gardées dans ~/backups (MARCEL_BACKUP_DIR, MARCEL_BACKUP_KEEP).
#
# Chaque nuit à 3 h 30 (crontab -e) :
#   30 3 * * * cd $HOME/marcel/backend && ./deploy/backup.sh >> $HOME/backups/marcel-backup.log 2>&1
# Restaurer : age -d -i ~/hermes-backup.key marcel-<date>.tar.gz.age | tar -xz -C <dossier>
set -euo pipefail
cd "$(dirname "$0")/.."

recipient="$HOME/.age-recipient"
dest="${MARCEL_BACKUP_DIR:-$HOME/backups}"
keep="${MARCEL_BACKUP_KEEP:-14}"
docker() { if command docker info >/dev/null 2>&1; then command docker "$@"; else sudo docker "$@"; fi; }

if [[ ! -s "$recipient" ]]; then
  echo "Clé publique introuvable ($recipient) : sauvegarde annulée, rien n'est écrit en clair." >&2
  exit 1
fi
umask 077
mkdir -p "$dest"
work=$(mktemp -d)
trap 'sudo rm -rf "$work"' EXIT

docker compose exec -T marcel-api python -m app.backup /data > "$work/marcel-data.tar.gz"
if docker compose ps --services --status running | grep -qx llm-guard; then
  docker compose exec -T llm-guard python -m app.backup /data > "$work/guard-data.tar.gz"
fi
for file in .env guard.env rma.env compose.yaml; do
  if [[ -f "$file" ]]; then cp "$file" "$work/"; fi
done
if [[ -d "$HOME/.hermes-checks" ]]; then
  sudo tar -czf "$work/hermes-checks.tar.gz" -C "$HOME" .hermes-checks
fi

out="$dest/marcel-$(date +%Y%m%d-%H%M%S).tar.gz.age"
sudo tar -czf - -C "$work" . | age -R "$recipient" > "$out"
echo "Sauvegarde : $out ($(du -h "$out" | cut -f1))"

# Only the most recent ones are kept.
ls -1t "$dest"/marcel-*.tar.gz.age 2>/dev/null | tail -n +"$((keep + 1))" | xargs -r rm --
