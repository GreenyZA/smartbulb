#!/usr/bin/env bash
# backup-projects-daily.sh — daily backup of acer:/projects to /backup/projects
#
# Design notes:
#   - rsync failure (rc != 0) is a HARD failure; never snapshot a partial tree.
#   - After rsync we verify every project dir is present in CURRENT.
#   - The daily snapshot is only created after the current set is verified complete.
#
# NOTE on REQUIRED_PROJECT_DIRS: stout-build-vm is intentionally excluded from
# the rsync (--exclude='stout*/'), so it must NOT be listed here; otherwise the
# daily snapshot is never written (a prior version listed it and always failed
# with "missing project dir stout-build-vm").
set -euo pipefail

BACKUP_ROOT=/backup
BU_NAME=projects
BASE="$BACKUP_ROOT/$BU_NAME"
CURRENT="$BASE/current"
LOG="$BACKUP_ROOT/metadata/backup.log"
STAMP="$(date +%Y-%m-%d_%H%M)"
DAILY_SNAP="$BASE/daily-$STAMP"
WEEKLY_SNAP="$BASE/weekly-$(date +%Y-%V)"

# Project directories that must be present in the current tree.
REQUIRED_PROJECT_DIRS=(
  clarity
  warpuppy
  ollama
  extractx
  clarity-token
  smear-token.bak-20260826-045748
  backups
)

mkdir -p "$BASE" "$BACKUP_ROOT/metadata"
EXCLUDES=(
  --exclude='*.raw'
  --exclude='ollama-host/'   # copied separately by backup-models-daily.sh (root sender)
  --exclude='*.iso'
  --exclude='stout/'
  --exclude='stout*/'
  --exclude='Games/'
  --exclude='games/'
  --exclude='.cache/'
  --exclude='**/.cache/'
  --exclude='node_modules/'
  --exclude='target/'
  --exclude='extractx/arch/boot/'
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
rsync --archive --delete --delete-excluded --one-file-system --partial --partial-dir=.rsync-partial \
  "${EXCLUDES[@]}" \
  acer:/projects/ "$CURRENT/"
rsync_rc=$?
set -e

if [ "$rsync_rc" -ne 0 ]; then
  log "ERROR rsync rc=$rsync_rc"
  exit "$rsync_rc"
fi
log "rsync completed rc=0"

# Verify the complete set was captured before snapshotting.
for d in "${REQUIRED_PROJECT_DIRS[@]}"; do
  if [ ! -d "$CURRENT/$d" ]; then
    log "ERROR missing project dir $d in $CURRENT after rsync"
    exit 1
  fi
done
log "projects rsync verified: all project dirs present in $CURRENT"

# Copy current -> daily snapshot. --link-dest makes unchanged files hardlinks
# into current (which is static during this copy), so the snapshot is a full
# point-in-time tree at negligible cost; rsync falls back to copying anything
# it cannot hardlink, so nothing is silently dropped. Verify before publishing.
rsync -a --link-dest="$CURRENT" --delete --exclude='ollama-host/' "$CURRENT/" "$DAILY_SNAP/"
if [ "$?" -ne 0 ]; then
  log "ERROR rsync to $DAILY_SNAP failed"
  exit 1
fi

# Verify the daily snapshot is complete before publishing it as latest.
for d in "${REQUIRED_PROJECT_DIRS[@]}"; do
  if [ ! -d "$DAILY_SNAP/$d" ]; then
    log "ERROR daily snapshot $DAILY_SNAP missing required dir $d after copy"
    exit 1
  fi
done
log "daily snapshot verified: $DAILY_SNAP contains all project dirs"
# rsync -a preserves the source dir's mtime, and current/ is old — without
# this the -mtime +7 retention prune deletes the snapshot just created.
touch "$DAILY_SNAP"
if [ "$(date +%u)" = "7" ]; then
  cp -al "$DAILY_SNAP" "$WEEKLY_SNAP"
fi

find "$BASE" -maxdepth 1 -type d -name 'daily-*' -mtime +7 -print -exec chmod -R u+w {} \; -exec rm -rf {} + >> "$LOG" 2>&1 || true
find "$BASE" -maxdepth 1 -type d -name 'weekly-*' -mtime +28 -print -exec chmod -R u+w {} \; -exec rm -rf {} + >> "$LOG" 2>&1 || true

ln -sfn "daily-$STAMP" "$BASE/latest"
log "OK snapshot $DAILY_SNAP from acer"
