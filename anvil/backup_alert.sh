#!/usr/bin/env bash
# backup_alert.sh — check backup health and alert on failure
# Runs every 15 minutes via cron on anvil.
set -uo pipefail

BACKUP_ROOT=/backup
STATUS_JSON="$BACKUP_ROOT/metadata/backup-status.json"
LOG="$BACKUP_ROOT/metadata/backup.log"
VAULT_INBOX="/home/warpuppy/Documents/Clarity/00-Inbox/email-alerts.md"
BULB_BROKER="http://localhost:9130"
ACER="acer"
PYTHON="$(command -v python3 || echo /usr/bin/python3)"

# Run monitor to get fresh status
/home/warpuppy/bin/backup_monitor.sh > /dev/null 2>&1

if [ ! -f "$STATUS_JSON" ]; then
  curl -sS -m 5 "$BULB_BROKER/set/error" > /dev/null 2>&1 || true
  echo "$(date -Iseconds) CRITICAL: backup-status.json missing" >> "$LOG"
  exit 1
fi

# Parse JSON with python (robust, no grep tail bugs)
parse() {
  "$PYTHON" - "$STATUS_JSON" "$1" <<'PYEOF'
import json, sys
path = sys.argv[2].split(".")
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("UNREADABLE")
    sys.exit(0)
cur = d
for p in path:
    if isinstance(cur, dict) and p in cur:
        cur = cur[p]
    else:
        cur = None
        break
if cur is None:
    print("")
elif isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print(cur)
PYEOF
}

status=$(parse "status")
if [ "$status" = "UNREADABLE" ] || [ -z "$status" ]; then
  curl -sS -m 5 "$BULB_BROKER/set/error" > /dev/null 2>&1 || true
  echo "$(date '+%F %T') ALERT: backup status unreadable" >> "$LOG"
  # try vault inbox on acer
  msg="backup status unreadable — health unknown"
  printf -- '- %s **backup_alert** %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$msg" | ssh -o BatchMode=yes -o ConnectTimeout=5 "$ACER" "mkdir -p $(dirname $VAULT_INBOX) && cat >> $VAULT_INBOX" 2>/dev/null || true
  exit 1
fi

lenovo_ok=$(parse "lenovo.ok")
acer_ok=$(parse "acer.ok")
projects_ok=$(parse "projects.ok")
key_files_ok=$(parse "key_files.ok")
drive_ok=$(parse "drive_space.ok")
missing=$(parse "key_files.missing")
drive_err=$(parse "drive_space.errors")

if [ "$status" != "healthy" ]; then
  curl -sS -m 5 "$BULB_BROKER/set/error" > /dev/null 2>&1 || true

  {
    echo ""
    echo "## BACKUP ALERT — $(date -Iseconds)"
    echo ""
    echo "- **Status:** $status"
    echo "- **Lenovo backup:** $lenovo_ok"
    echo "- **Acer backup:** $acer_ok"
    echo "- **Projects backup:** $projects_ok"
    echo "- **Key files:** $key_files_ok (missing:$missing)"
    echo "- **Drive space:** $drive_ok ($drive_err)"
    echo "- **Action required:** Check backup system immediately"
  } >> "$LOG"

  # Write to vault inbox on acer (where the vault lives)
  {
    echo ""
    echo "## BACKUP ALERT — $(date -Iseconds)"
    echo ""
    echo "- **Status:** $status"
    echo "- **Lenovo backup:** $lenovo_ok"
    echo "- **Acer backup:** $acer_ok"
    echo "- **Projects backup:** $projects_ok"
    echo "- **Key files:** $key_files_ok (missing:$missing)"
    echo "- **Drive space:** $drive_ok ($drive_err)"
  } | ssh -o BatchMode=yes -o ConnectTimeout=5 "$ACER" "mkdir -p $(dirname $VAULT_INBOX) && cat >> $VAULT_INBOX" 2>/dev/null || true

  echo "$(date '+%F %T') ALERT: backup status=$status lenovo=$lenovo_ok acer=$acer_ok projects=$projects_ok keyfiles=$key_files_ok drive=$drive_ok" >> "$LOG"

  email_body="From: johannvdventer@gmail.com
To: johannvdventer@gmail.com
Subject: [Clarity Backup Alert] ${status}

Backup status: ${status}
Lenovo backup: ${lenovo_ok}
Acer backup: ${acer_ok}
Projects backup: ${projects_ok}
Key files: ${key_files_ok} (missing:${missing})
Drive space: ${drive_ok} (${drive_err})

Action required: Check backup system immediately.
"
  printf '%s\n' "$email_body" | base64 -w0 | ssh -o BatchMode=yes -o ConnectTimeout=15 "$ACER" "base64 -d | /home/warpuppy/.local/bin/himalaya message send --account personal" >/dev/null 2>&1 || true

  exit 1
fi

curl -sS -m 5 "$BULB_BROKER/set/idle" > /dev/null 2>&1 || true
exit 0
