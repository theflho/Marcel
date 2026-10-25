#!/usr/bin/env bash
# Copie les sauvegardes chiffrées du VPS sur ce Mac (ou tout autre ordinateur), à lancer ici :
#   ./deploy/pull-backup.sh <hôte-ssh> [dossier]
# <hôte-ssh> : le VPS tel que tu t'y connectes (nom Tailscale, ou un Host de ~/.ssh/config).
# Seules les sauvegardes absentes d'ici sont copiées, dans ~/MarcelBackups par défaut ; les
# MARCEL_BACKUP_KEEP (30) plus récentes sont gardées. Elles restent chiffrées : ce Mac n'a besoin
# de la clé privée que pour restaurer (deploy/restore.sh).
#
# Chaque jour à 9 h, Mac allumé (crontab -e) :
#   0 9 * * * $HOME/<chemin>/Marcel/backend/deploy/pull-backup.sh <hôte-ssh> >> $HOME/MarcelBackups/pull.log 2>&1
set -euo pipefail

host="${1:?usage : ./deploy/pull-backup.sh <hôte-ssh> [dossier]}"
dest="${2:-$HOME/MarcelBackups}"
keep="${MARCEL_BACKUP_KEEP:-30}"
remote_dir="${MARCEL_REMOTE_BACKUP_DIR:-backups}"
umask 077
mkdir -p "$dest"

# BatchMode: never stops to ask for a password; key or Tailscale SSH only.
remote=$(ssh -o BatchMode=yes "$host" "ls -1 $remote_dir/marcel-*.tar.gz.age 2>/dev/null" || true)
if [[ -z "$remote" ]]; then
  echo "$(date '+%F %T') aucune sauvegarde trouvée sur $host:$remote_dir" >&2
  exit 1
fi
copied=0
while read -r path; do
  name=$(basename "$path")
  [[ -f "$dest/$name" ]] && continue
  scp -q -o BatchMode=yes "$host:$path" "$dest/$name.part" && mv "$dest/$name.part" "$dest/$name"
  copied=$((copied + 1))
done <<< "$remote"

ls -1t "$dest"/marcel-*.tar.gz.age 2>/dev/null | tail -n +"$((keep + 1))" | xargs -r rm --
latest=$(ls -1t "$dest"/marcel-*.tar.gz.age | head -1)
echo "$(date '+%F %T') $copied copiée(s) ; la plus récente : $(basename "$latest")"
