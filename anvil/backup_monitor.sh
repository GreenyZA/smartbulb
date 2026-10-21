#!/usr/bin/env bash
# backup_monitor.sh — post-backup health check on anvil (Lenovo)
set -uo pipefail

BACKUP_ROOT=/backup
LOG="$BACKUP_ROOT/metadata/backup.log"
STATUS_JSON="$BACKUP_ROOT/metadata/backup-status.json"
TODAY="$(date +%Y-%m-%d)"
DISK_THRESHOLD=85

log() { printf '%s monitor: %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

lenovo_ok=false; acer_ok=false; projects_ok=false
lenovo_errors=""; acer_errors=""; projects_errors=""
key_files_ok=true; key_files_missing=""
drive_ok=true; drive_errors=""

if grep -q "lenovo: OK snapshot" "$LOG" 2>/dev/null; then
  last_lenovo=$(grep "lenovo: OK snapshot" "$LOG" | tail -1)
  if echo "$last_lenovo" | grep -q "$TODAY"; then
    lenovo_ok=true
  else
    lenovo_errors="last lenovo backup not today"
  fi
else
  lenovo_errors="no lenovo OK snapshot found in log"
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
  else
    acer_errors="last acer backup not today"
  fi
else
  acer_errors="no acer OK snapshot found in log"
fi

if grep -q "projects: OK snapshot" "$LOG" 2>/dev/null; then
  last_projects=$(grep "projects: OK snapshot" "$LOG" | tail -1)
  if echo "$last_projects" | grep -q "$TODAY"; then
    projects_ok=true
  else
    projects_errors="last projects backup not today"
  fi
else
  projects_errors="no projects OK snapshot found in log"
fi

acer_latest="$BACKUP_ROOT/acer/latest"
for f in ".bashrc" ".ssh/" ".hermes/" ".config/" "Projects/" "Documents/" "Work/"; do
  fp="${f%/}"
  if [ ! -e "$acer_latest/$fp" ] && [ ! -L "$acer_latest/$fp" ]; then
    key_files_ok=false
    key_files_missing="$key_files_missing $f"
  fi
done

projects_latest="$BACKUP_ROOT/projects/latest"
if [ -d "$projects_latest" ]; then
  for f in "clarity" "warpuppy"; do
    if [ ! -e "$projects_latest/$f" ] && [ ! -L "$projects_latest/$f" ]; then
      key_files_ok=false
      key_files_missing="$key_files_missing projects:$f"
    fi
  done
else
  key_files_ok=false
  key_files_missing="$key_files_missing projects:root"
fi

use_pct=$(df /backup | awk 'NR==2{print $5}' | tr -d '%')
if [ "$use_pct" -ge "$DISK_THRESHOLD" ]; then
  drive_ok=false
  drive_errors="backup disk usage ${use_pct}% >= ${DISK_THRESHOLD}%"
fi

status="healthy"
if [ "$lenovo_ok" != "true" ] || [ "$acer_ok" != "true" ] || [ "$projects_ok" != "true" ] || [ "$key_files_ok" != "true" ] || [ "$drive_ok" != "true" ]; then
  status="degraded"
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

BULB_BROKER="http://localhost:9130"
if [ "$status" = "healthy" ]; then
  curl -sS -m 5 "$BULB_BROKER/set/idle" > /dev/null 2>&1 || true
  log "smartbulb: idle (healthy)"
else
  curl -sS -m 5 "$BULB_BROKER/set/backup_fail" > /dev/null 2>&1 || true
  log "smartbulb: backup_fail (degraded)"
fi

echo "$status"
