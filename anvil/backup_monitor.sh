#!/usr/bin/env bash
# backup_monitor.sh — post-backup health check on anvil (Lenovo)
set -uo pipefail

BACKUP_ROOT=/backup
LOG="$BACKUP_ROOT/metadata/backup.log"
STATUS_JSON="$BACKUP_ROOT/metadata/backup-status.json"
TODAY="$(date +%Y-%m-%d)"
DISK_THRESHOLD=85
# The backup window ends at 03:45, when the monitor normally runs.
NOW_MIN=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
WINDOW_END=225
# The models copy job runs at 03:35; give it its own window end so an
# overrun is 'pending', not a failure.
MODELS_WINDOW_END=245

log() { printf '%s monitor: %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

lenovo_ok=false; acer_ok=false; projects_ok=false
lenovo_errors=""; acer_errors=""; projects_errors=""
key_files_ok=true; key_files_missing=""
models_ok=false; models_errors=""
pending=false
drive_ok=true; drive_errors=""
prune_ok=true; prune_errors=""
snap_ok=true; snap_errors=""

# --- Source status: use the log line but only to confirm the backup ran today. ---
if grep -q "lenovo: OK snapshot" "$LOG" 2>/dev/null; then
  last_lenovo=$(grep "lenovo: OK snapshot" "$LOG" | tail -1)
  if echo "$last_lenovo" | grep -q "$TODAY"; then
    lenovo_ok=true
  elif [ "$NOW_MIN" -lt "$WINDOW_END" ]; then
    pending=true
  else
    lenovo_errors="last lenovo backup not today"
  fi
else
  if [ "$NOW_MIN" -lt "$WINDOW_END" ]; then
    pending=true
  else
    lenovo_errors="no lenovo OK snapshot found in log"
  fi
fi

if grep -q "acer: OK snapshot" "$LOG" 2>/dev/null; then
  last_acer=$(grep "acer: OK snapshot" "$LOG" | tail -1)
  if echo "$last_acer" | grep -q "$TODAY"; then
    if grep -q "acer: ERROR" "$LOG" 2>/dev/null; then
      last_acer_error=$(grep "acer: ERROR" "$LOG" | tail -1)
      if echo "$last_acer_error" | grep -q "$TODAY"; then
        acer_errors="$last_acer_error"
      fi
    fi
    acer_ok=true
  elif [ "$NOW_MIN" -lt "$WINDOW_END" ]; then
    pending=true
  else
    acer_errors="last acer backup not today"
  fi
else
  if [ "$NOW_MIN" -lt "$WINDOW_END" ]; then
    pending=true
  else
    acer_errors="no acer OK snapshot found in log"
  fi
fi

if grep -q "projects: OK snapshot" "$LOG" 2>/dev/null; then
  last_projects=$(grep "projects: OK snapshot" "$LOG" | tail -1)
  if echo "$last_projects" | grep -q "$TODAY"; then
    projects_ok=true
  elif [ "$NOW_MIN" -lt "$WINDOW_END" ]; then
    pending=true
  else
    projects_errors="last projects backup not today"
  fi
else
  if [ "$NOW_MIN" -lt "$WINDOW_END" ]; then
    pending=true
  else
    projects_errors="no projects OK snapshot found in log"
  fi
fi

if grep -q "models: OK" "$LOG" 2>/dev/null; then
  last_models=$(grep "models: OK" "$LOG" | tail -1)
  if echo "$last_models" | grep -q "$TODAY"; then
    models_ok=true
  elif [ "$NOW_MIN" -lt "$MODELS_WINDOW_END" ]; then
    pending=true
  else
    models_errors="last models copy not today"
  fi
else
  if [ "$NOW_MIN" -lt "$MODELS_WINDOW_END" ]; then
    pending=true
  else
    models_errors="no models OK found in log"
  fi
fi

# --- Key-files check: verify ACTUAL snapshot contents (not the log line). ---
acer_latest="$BACKUP_ROOT/acer/latest"
for f in ".bashrc" ".ssh/" ".hermes/" ".config/" "Projects/" "Documents/" "Work/"; do
  fp="${f%/}"
  if [ ! -e "$acer_latest/$fp" ] && [ ! -L "$acer_latest/$fp" ]; then
    key_files_ok=false
    key_files_missing="$key_files_missing $f"
  fi
done

# The 'projects/latest' is a SYMLINK to a dated daily snapshot. Use test -L to
# detect the symlink and resolve it; then verify the real snapshot holds the
# required key dirs (clarity, warpuppy). This catches a partial snapshot even
# when the log line claims "OK".
projects_latest="$BACKUP_ROOT/projects/latest"
if [ -L "$projects_latest" ]; then
  projects_target="$(readlink "$projects_latest" 2>/dev/null)"
  if [ -n "$projects_target" ]; then
    for f in "clarity" "warpuppy"; do
      if [ ! -d "/backup/projects/$projects_target/$f" ]; then
        key_files_ok=false
        key_files_missing="$key_files_missing projects:$f"
      fi
    done
  else
    key_files_ok=false
    key_files_missing="$key_files_missing projects:symlink_broken"
  fi
else
  key_files_ok=false
  key_files_missing="$key_files_missing projects:root"
fi

use_pct=$(df /backup | awk 'NR==2{print $5}' | tr -d '%')
if [ "$use_pct" -ge "$DISK_THRESHOLD" ]; then
  drive_ok=false
  drive_errors="backup disk usage ${use_pct}% >= ${DISK_THRESHOLD}%"
fi

# --- Retention hygiene: prune failures + snapshot count ---
# Count 'cannot remove' only after the last success marker, so the historical
# backlog from the resolved read-only-tree incident is not read as a live fault.
last_ok=$(grep -n "OK snapshot" "$LOG" 2>/dev/null | tail -1 | cut -d: -f1)
if [ -z "$last_ok" ]; then
  live_rm=$(grep -c "cannot remove" "$LOG" 2>/dev/null || true)
else
  live_rm=$(tail -n "+$((last_ok + 1))" "$LOG" 2>/dev/null | grep -c "cannot remove" || true)
fi
if [ -n "$live_rm" ] && [ "$live_rm" -gt 0 ]; then
  prune_ok=false
  prune_errors="prune failing now: ${live_rm} 'cannot remove' since last successful backup"
fi

# Retention policy is 7 daily snapshots per source; degrade above 2x that.
for base in acer lenovo projects; do
  n=$(find "$BACKUP_ROOT/$base" -maxdepth 1 -type d -name 'daily-*' 2>/dev/null | wc -l)
  if [ "$n" -gt 21 ]; then
    snap_ok=false
    snap_errors="$snap_errors $base=$n"
  fi
done

status="healthy"
if [ "$lenovo_ok" != "true" ] || [ "$acer_ok" != "true" ] || [ "$projects_ok" != "true" ] || [ "$key_files_ok" != "true" ] || [ "$drive_ok" != "true" ] || [ "$prune_ok" != "true" ] || [ "$snap_ok" != "true" ] || [ "$models_ok" != "true" ]; then
  # A source not having run yet is only "pending" before the window closes; it
  # is not a failure unless the log shows a real error for it.
  if [ "$pending" = "true" ] && [ -z "$lenovo_errors$acer_errors$projects_errors$models_errors" ] && [ "$key_files_ok" = "true" ] && [ "$drive_ok" = "true" ] && [ "$prune_ok" = "true" ] && [ "$snap_ok" = "true" ]; then
    status="healthy"
  else
    status="degraded"
  fi
fi

cat > "$STATUS_JSON" <<ENDJSON
{
  "timestamp": "$(date -Iseconds)",
  "status": "$status",
  "lenovo": {"ok": $lenovo_ok, "errors": "$lenovo_errors"},
  "acer": {"ok": $acer_ok, "errors": "$acer_errors"},
  "projects": {"ok": $projects_ok, "errors": "$projects_errors"},
  "key_files": {"ok": $key_files_ok, "missing": "$key_files_missing"},
  "drive_space": {"ok": $drive_ok, "errors": "$drive_errors", "use_percent": $use_pct},
  "retention": {"prune_ok": $prune_ok, "prune_errors": "$prune_errors", "snapshot_count_ok": $snap_ok, "snapshot_count_errors": "$snap_errors"},
  "models": {"ok": $models_ok, "errors": "$models_errors"},
  "pending": $pending,
  "backup_disk": {
    "total": "$(df -h /backup | awk 'NR==2{print $2}')",
    "used": "$(df -h /backup | awk 'NR==2{print $3}')",
    "available": "$(df -h /backup | awk 'NR==2{print $4}')",
    "use_percent": "$(df -h /backup | awk 'NR==2{print $5}')"
  }
}
ENDJSON

if [ "$status" = "healthy" ]; then
  log "HEALTHY lenovo=$lenovo_ok acer=$acer_ok projects=$projects_ok keyfiles=$key_files_ok drive=$drive_ok"
else
  log "DEGRADED lenovo=$lenovo_ok acer=$acer_ok projects=$projects_ok keyfiles=$key_files_ok missing=[$key_files_missing] drive=[$drive_errors] lenovo_err=[$lenovo_errors] acer_err=[$acer_errors] projects_err=[$projects_errors]"
fi

BULB_BROKER="http://192.168.1.10:9130"   # canonical writer is acer (RFC-2026-001)
if [ "$status" = "healthy" ]; then
  curl -sS -m 5 "$BULB_BROKER/set/idle" > /dev/null 2>&1 || true
  log "smartbulb: idle (healthy)"
else
  curl -sS -m 5 "$BULB_BROKER/set/backup_fail" > /dev/null 2>&1 || true
  log "smartbulb: backup_fail (degraded)"
fi

echo "$status"
