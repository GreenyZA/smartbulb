#!/usr/bin/env bash
# backup_dashboard.sh — generate HTML status page from backup-status.json
set -u

BACKUP_ROOT=/backup
STATUS_JSON="$BACKUP_ROOT/metadata/backup-status.json"
HTML_OUT="$BACKUP_ROOT/metadata/backup-status.html"
PYTHON="$(command -v python3 || echo /usr/bin/python3)"

if [ ! -f "$STATUS_JSON" ]; then
  echo '<p class="degraded">No status JSON found</p>' > "$HTML_OUT"
  exit 0
fi

# Parse JSON with python (robust)
get() {
  "$PYTHON" - "$STATUS_JSON" "$1" <<'PYEOF'
import json, sys
path = sys.argv[2].split(".")
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("")
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

status=$(get "status")
timestamp=$(get "timestamp")
lenovo_ok=$(get "lenovo.ok")
acer_ok=$(get "acer.ok")
projects_ok=$(get "projects.ok")
key_files_ok=$(get "key_files.ok")
key_files_missing=$(get "key_files.missing")
drive_ok=$(get "drive_space.ok")
drive_err=$(get "drive_space.errors")
use_percent=$(get "backup_disk.use_percent")
disk_total=$(get "backup_disk.total")
disk_used=$(get "backup_disk.used")
disk_avail=$(get "backup_disk.available")
lenovo_last=$(grep "lenovo: OK snapshot" /backup/metadata/backup.log 2>/dev/null | tail -1 | awk '{print $1, $2}')
acer_last=$(grep "acer: OK snapshot" /backup/metadata/backup.log 2>/dev/null | tail -1 | awk '{print $1, $2}')
projects_last=$(grep "projects: OK snapshot" /backup/metadata/backup.log 2>/dev/null | tail -1 | awk '{print $1, $2}')

lenovo_snaps=$(ls -d /backup/lenovo/daily-* 2>/dev/null | wc -l)
acer_snaps=$(ls -d /backup/acer/daily-* 2>/dev/null | wc -l)
projects_snaps=$(ls -d /backup/projects/daily-* 2>/dev/null | wc -l)
lenovo_weeklies=$(ls -d /backup/lenovo/weekly-* 2>/dev/null | wc -l)
acer_weeklies=$(ls -d /backup/acer/weekly-* 2>/dev/null | wc -l)
projects_weeklies=$(ls -d /backup/projects/weekly-* 2>/dev/null | wc -l)

today=$(date +%Y-%m-%d)
lenovo_errors=$(grep "lenovo: ERROR" /backup/metadata/backup.log 2>/dev/null | grep "$today" | tail -3)
acer_errors=$(grep "acer: ERROR" /backup/metadata/backup.log 2>/dev/null | grep "$today" | tail -3)
projects_errors=$(grep "projects: ERROR" /backup/metadata/backup.log 2>/dev/null | grep "$today" | tail -3)

if [ "$status" = "healthy" ]; then
  status_color="#22c55e"
  status_bg="#f0fdf4"
else
  status_color="#ef4444"
  status_bg="#fef2f2"
fi

card() {
  # args: title ok last snaps weeklies errors
  local title="$1" ok="$2" last="$3" snaps="$4" weeklies="$5" errors="$6"
  local cls="ok" txt="OK"
  if [ "$ok" != "true" ]; then cls="fail"; txt="FAILED"; fi
  echo "<div class=\"card\">"
  echo "  <div class=\"section-title\">$title</div>"
  echo "  <div class=\"metric\"><div class=\"metric-label\">Backup Today</div><div class=\"metric-value $cls\">$txt</div></div>"
  echo "  <div class=\"metric\" style=\"margin-top:0.5rem\"><div class=\"metric-label\">Last Backup</div><div class=\"metric-value\">${last:-never}</div></div>"
  echo "  <div class=\"metric\" style=\"margin-top:0.5rem\"><div class=\"metric-label\">Snapshots (daily / weekly)</div><div class=\"metric-value\">$snaps / $weeklies</div></div>"
  [ -n "$errors" ] && echo "  <div class=\"error-box\">$errors</div>"
  echo "</div>"
}

cat > "$HTML_OUT" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Backup Status</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f8fafc; color: #1e293b; padding: 2rem; }
  .container { max-width: 900px; margin: 0 auto; }
  h1 { font-size: 1.5rem; margin-bottom: 0.5rem; }
  .subtitle { color: #64748b; margin-bottom: 2rem; font-size: 0.875rem; }
  .card { background: white; border-radius: 12px; padding: 1.5rem; margin-bottom: 1rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
  .status-banner { background: $status_bg; border-left: 4px solid $status_color; padding: 1rem 1.5rem; border-radius: 8px; margin-bottom: 1.5rem; }
  .status-banner h2 { color: $status_color; font-size: 1.25rem; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 1rem; }
  .metric { padding: 0.75rem; background: #f8fafc; border-radius: 8px; }
  .metric-label { font-size: 0.75rem; color: #64748b; text-transform: uppercase; letter-spacing: 0.05em; }
  .metric-value { font-size: 1.25rem; font-weight: 600; margin-top: 0.25rem; }
  .metric-value.ok { color: #22c55e; }
  .metric-value.fail { color: #ef4444; }
  .section-title { font-size: 0.875rem; font-weight: 600; color: #475569; margin-bottom: 0.5rem; margin-top: 1rem; }
  .error-box { background: #fef2f2; border: 1px solid #fecaca; border-radius: 8px; padding: 1rem; margin-top: 1rem; font-family: monospace; font-size: 0.8rem; color: #991b1b; }
  footer { text-align: center; color: #94a3b8; font-size: 0.75rem; margin-top: 2rem; }
</style>
</head>
<body>
<div class="container">
  <h1>Backup Status</h1>
  <p class="subtitle">Last updated: $timestamp</p>

  <div class="status-banner">
    <h2>Status: ${status^^}</h2>
  </div>

  <div class="grid">
    $(card "Lenovo (anvil)" "$lenovo_ok" "$lenovo_last" "$lenovo_snaps" "$lenovo_weeklies" "$lenovo_errors")
    $(card "Acer (remote)" "$acer_ok" "$acer_last" "$acer_snaps" "$acer_weeklies" "$acer_errors")
    $(card "Projects (remote)" "$projects_ok" "$projects_last" "$projects_snaps" "$projects_weeklies" "$projects_errors")
  </div>

  <div class="card">
    <div class="section-title">Key files (acer snapshot)</div>
    <div class="metric-value $([ "$key_files_ok" = "true" ] && echo 'ok' || echo 'fail')">$([ "$key_files_ok" = "true" ] && echo 'OK' || echo "MISSING:$key_files_missing")</div>
  </div>

  <div class="card">
    <div class="section-title">Drive space (/backup)</div>
    <div class="metric-value $([ "$drive_ok" = "true" ] && echo 'ok' || echo 'fail')">$([ "$drive_ok" = "true" ] && echo "OK (${use_percent}% used)" || echo "LOW: $drive_err")</div>
    <div class="metric" style="margin-top:0.5rem"><div class="metric-label">Total / Used / Available</div><div class="metric-value">$disk_total / $disk_used / $disk_avail</div></div>
  </div>

  <footer>Generated by backup_dashboard.sh on anvil</footer>
</div>
</body>
</html>
EOF

echo "Dashboard written to $HTML_OUT"
