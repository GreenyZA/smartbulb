#!/usr/bin/env bash
# backup-models-daily.sh — off-box copy of acer's ollama model store.
#
# The models live in /projects/ollama-host on acer, owned by the `ollama` service
# user with mode 600. Depending on an ACL to survive every `ollama pull` is
# fragile, so the remote rsync runs as root (--rsync-path="sudo rsync") and reads
# them regardless. This is a restore copy, kept separate from the nightly
# projects backup (which excludes ollama-host).
set -euo pipefail

SRC="acer:/projects/ollama-host/"
DST="/backup/models/ollama-host"
LOG="/backup/metadata/backup.log"
STAMP="$(date '+%F %T')"

mkdir -p "$DST"
set +e
rsync -a --delete --rsync-path="sudo rsync" "$SRC" "$DST/" >> "$LOG" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  printf '%s models: ERROR rsync rc=%s\n' "$STAMP" "$rc" >> "$LOG"
  exit "$rc"
fi
printf '%s models: OK %s -> %s\n' "$STAMP" "$SRC" "$DST" >> "$LOG"
