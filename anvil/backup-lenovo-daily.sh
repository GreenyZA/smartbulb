#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT=/backup
SRC=/home/warpuppy
BU_NAME=lenovo
BASE="$BACKUP_ROOT/$BU_NAME"
CURRENT="$BASE/current"
LOG="$BACKUP_ROOT/metadata/backup.log"
STAMP="$(date +%Y-%m-%d_%H%M)"
DAILY_SNAP="$BASE/daily-$STAMP"
WEEKLY_SNAP="$BASE/weekly-$(date +%Y-%V)"

mkdir -p "$BASE" "$BACKUP_ROOT/metadata"
EXCLUDES=(
  --exclude='.cache/'
  --exclude='**/.cache/'
  --exclude='.local/share/Trash/'
  --exclude='**/.Trash/'
  --exclude='Games/'
  --exclude='games/'
  --exclude='stout/'
  --exclude='*/airootfs/etc/credstore'
  --exclude='*/airootfs/etc/cryptsetup-keys.d'
  --exclude='*.tmp'
  --exclude='*.sock'
  --exclude='*.lock'
  --exclude='*.iso'
)

log() { printf '%s %s: %s\n' "$(date '+%F %T')" "$BU_NAME" "$*" >> "$LOG"; }
if ! mountpoint -q "$BACKUP_ROOT"; then
  log "ERROR backup_root not mounted"
  exit 1
fi

set +e
rsync --archive --delete --one-file-system --partial --partial-dir=.rsync-partial \
  "${EXCLUDES[@]}" \
  "$SRC/" "$CURRENT/"
rc=$?
set -e
# 23 = partial (permission-denied rootfs/cache pieces; rest sync succeeds)
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
log "OK snapshot $DAILY_SNAP"
