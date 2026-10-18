#!/usr/bin/env python3
"""
Log backup_fail events to a file for daily catch-up reporting.
Called by the broker when backup_fail is triggered.
"""
import json
import time
from pathlib import Path

LOG_FILE = Path("/home/warpuppy/Projects/Clarity/data/clarity/backup_events.json")

def log_backup_event():
    """Log a backup failure event with timestamp."""
    event = {
        "timestamp": time.time(),
        "datetime": time.strftime("%Y-%m-%d %H:%M:%S"),
        "event": "backup_fail",
        "pattern": "police_light",
        "duration_minutes": 60  # 1 hour of flashing
    }
    
    # Read existing events
    events = []
    if LOG_FILE.exists():
        try:
            with open(LOG_FILE, 'r') as f:
                events = json.load(f)
        except (json.JSONDecodeError, IOError):
            events = []
    
    # Add new event
    events.append(event)
    
    # Keep only last 30 days of events
    cutoff = time.time() - 30 * 24 * 60 * 60
    events = [e for e in events if e["timestamp"] > cutoff]
    
    # Write back
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(LOG_FILE, 'w') as f:
        json.dump(events, f, indent=2)

def get_recent_backup_events(hours=24):
    """Get backup events from the last N hours."""
    if not LOG_FILE.exists():
        return []
    
    try:
        with open(LOG_FILE, 'r') as f:
            events = json.load(f)
    except (json.JSONDecodeError, IOError):
        return []
    
    cutoff = time.time() - hours * 60 * 60
    return [e for e in events if e["timestamp"] > cutoff]

if __name__ == "__main__":
    log_backup_event()
    print(f"Logged backup event at {time.strftime('%Y-%m-%d %H:%M:%S')}")