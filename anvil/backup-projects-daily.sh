#!/usr/bin/env bash
# backup-projects-daily.sh — daily backup of acer:/projects to /backup/projects
set -euo pipefail

BACKUP_ROOT=/backup
BU_NAME=projects
BASE="$BACKUP_ROOT/$BU_NAME"
CURRENT="$BASE/current"
LOG="$BACKUP_ROOT/metadata/backup.log"
STAMP="$(date +%Y-%m-%d_%H%M)"
DAILY_SNAP="$BASE/daily-$STAMP"
WEEKLY_SNAP="$BASE/weekly-$(date +%Y-%V)"

mkdir -p "$BASE" "$BACKUP_ROOT/metadata"
EXCLUDES=(
  --exclude='*.raw'
  --exclude='*.iso'
  --exclude='stout/'
  --exclude='stout*/'
  --exclude='Games/'
  --exclude='games/'
  --exclude='.cache/'
  --exclude='**/.cache/'
  --exclude='node_modules/'
  --exclude='target/'
  --exclude='__pycache__/'
  --exclude='*.tmp'
  --exclude='*.sock'
  --exclude='*.lock'
)

log() { printf '%s %s: %s\n' "$(date '+%F %T')" "$BU_NAME" "$*" >> "$LOG"; }

if ! mountpoint -q "$BACKUP_ROOT"; then
  log "ERROR backup_root not mounted"
  exit 1
fi

set +e
rsync --archive --delete --one-file-system --partial --partial-dir=.rsync-partial \
  "${EXCLUDES[@]}" \
  acer:/projects/ "$CURRENT/"
rc=$?
set -e

if [ "$rc" -ne 0 ] && [ "$rc" -ne 23 ]; then
  log "ERROR rsync rc=$rc"
  exit "$rc"
fi
log "rsync completed rc=$rc"

cp -al "$CURRENT" "$DAILY_SNAP"
if [ "$(date +%u)" = "7" ]; then
  cp -al "$DAILY_SNAP" "$WEEKLY_SNAP"
fi

find "$BASE" -maxdepth 1 -type d -name 'daily-*' -mtime +7 -print -exec rm -rf {} + >> "$LOG" 2>&1 || true
find "$BASE" -maxdepth 1 -type d -name 'weekly-*' -mtime +28 -print -exec rm -rf {} + >> "$LOG" 2>&1 || true

ln -sfn "daily-$STAMP" "$BASE/latest"
log "OK snapshot $DAILY_SNAP from acer"
