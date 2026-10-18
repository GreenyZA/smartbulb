#!/bin/bash
# Backup monitor script - calls smartbulb broker to set backup_fail state
# Add to cron: */10 * * * * /home/warpuppy/Projects/smartbulb/anvil/backup_monitor.sh
#
# This script checks for backup failures and triggers the police light pattern.
# It should be run either:
# 1. As a cron job every 10 minutes: */10 * * * *
# 2. Triggered by backup system failures

BROKER_URL="http://192.168.1.8:9130"

# Check if backup directory exists and has recent files
BACKUP_DIR="/backup"
CLARITY_BACKUP_DIR="/home/warpuppy/Projects/ClarityLearn/data/clarity/backups"

# Function to trigger backup_fail state
trigger_backup_fail() {
    echo "[$(date)] Backup failure detected - triggering alert"
    curl -s -o /dev/null -w "%{http_code}" "$BROKER_URL/set/backup_fail"
}

# Check if we're already in a backup_fail state (first check)
# The broker maintains state, so we just need to detect failure

if [ -d "$BACKUP_DIR" ]; then
    # Check for backups in last 24 hours
    RECENT_BACKUPS=$(find "$BACKUP_DIR" -name "*.tar*" -o -name "*.gz" -mtime -1 2>/dev/null | wc -l)
    if [ "$RECENT_BACKUPS" -eq 0 ]; then
        trigger_backup_fail
    fi
elif [ -d "$CLARITY_BACKUP_DIR" ]; then
    # Check ClarityLearn backups
    RECENT_BACKUPS=$(find "$CLARITY_BACKUP_DIR" -type f -mtime -1 2>/dev/null | wc -l)
    if [ "$RECENT_BACKUPS" -eq 0 ]; then
        trigger_backup_fail
    fi
else
    # No backup directory found - assume failure
    trigger_backup_fail
fi

exit 0