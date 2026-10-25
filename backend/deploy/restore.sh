#!/usr/bin/env bash
# Ouvre une sauvegarde de Marcel et vérifie qu'elle est complète, sans rien toucher au VPS :
#   ./deploy/restore.sh <sauvegarde.tar.gz.age> [dossier]
# À lancer sur le Mac, depuis backend/, avec la clé privée age (AGE_KEY, ~/hermes-backup.key par
# défaut ; age demande lui-même sa phrase secrète si elle en a une). Le contenu arrive dans
# [dossier] (./restauration-<date> par défaut) : data/ (base, pièces jointes), guard-data/,
# les réglages (.env…) et .hermes-checks. Puis chaque base est vérifiée et comptée.
#
# Pour voir l'app sur ces données, sans le VPS :
#   MARCEL_TOKEN=essai MARCEL_MOCK=1 MARCEL_DATA_DIR=<dossier>/data .venv/bin/uvicorn app.main:app --port 8001
#
# Remettre une sauvegarde EN PLACE sur un VPS (nouveau ou réparé) reste un geste à faire toi-même :
# copier <dossier>/data dans le volume de marcel-api, les réglages à côté du compose, puis
# ./deploy/update.sh. Ce script ne le fait jamais.
set -euo pipefail
cd "$(dirname "$0")/.."

backup="${1:?usage : ./deploy/restore.sh <sauvegarde.tar.gz.age> [dossier]}"
dest="${2:-restauration-$(date +%Y%m%d-%H%M%S)}"
key="${AGE_KEY:-$HOME/hermes-backup.key}"

if ! command -v age >/dev/null; then
  echo "age n'est pas installé : brew install age" >&2
  exit 1
fi
if [[ ! -f "$key" ]]; then
  echo "Clé privée introuvable ($key) : indique-la avec AGE_KEY=<chemin>." >&2
  exit 1
fi
if [[ -e "$dest" ]]; then
  echo "$dest existe déjà : choisis un autre dossier." >&2
  exit 1
fi
umask 077
mkdir -p "$dest"
# Nothing half-restored is left behind if the key is wrong or the file damaged.
trap 'rm -rf "$dest"; echo "Restauration impossible : rien n'"'"'est gardé." >&2' ERR
age -d -i "$key" "$backup" | tar -xz -C "$dest"

mkdir -p "$dest/data"
tar -xzf "$dest/marcel-data.tar.gz" -C "$dest/data" && rm "$dest/marcel-data.tar.gz"
if [[ -f "$dest/guard-data.tar.gz" ]]; then
  mkdir -p "$dest/guard-data"
  tar -xzf "$dest/guard-data.tar.gz" -C "$dest/guard-data" && rm "$dest/guard-data.tar.gz"
fi
if [[ -f "$dest/hermes-checks.tar.gz" ]]; then
  tar -xzf "$dest/hermes-checks.tar.gz" -C "$dest" && rm "$dest/hermes-checks.tar.gz"
fi

trap - ERR

python=python3
[[ -x .venv/bin/python ]] && python=.venv/bin/python
echo "Contenu de la sauvegarde ($(basename "$backup")) :"
status=0
"$python" -m app.backup check "$dest/data" || status=$?
if [[ -d "$dest/guard-data" ]]; then "$python" -m app.backup check "$dest/guard-data" || status=$?; fi
for file in .env guard.env rma.env compose.yaml; do
  [[ -f "$dest/$file" ]] && echo "réglages : $file"
done
[[ -d "$dest/.hermes-checks" ]] && echo "réglages : .hermes-checks"
echo "Restauré dans $dest (contient des secrets : supprime-le une fois l'essai fini)."
exit $status
