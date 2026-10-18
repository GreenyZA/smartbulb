# smartbulb — Tapo L530 status channel (anvil broker + waybar module)

The smart bulb is a **live-work status channel**: the light shows what the agent is
doing, and the waybar module mirrors it. Built 2026-10-04 (CHG: smartbulb broker).

## Architecture

```
Hermes / anything ──HTTP──► anvil broker :9130 ──► Tapo L530 (192.168.1.225)
waybar module (acer) ──GET /bar──► anvil :9130
```

The **broker on anvil is the single writer** to the bulb. Everything else is a
client. This keeps the bulb and the bar in sync from one source of truth.

## Components

| Path | Where | Purpose |
|---|---|---|
| `anvil/broker.py` | anvil `/opt/smartbulb/broker.py` | state machine + pattern library + HTTP API |
| `anvil/set-credentials.sh` | anvil `/opt/smartbulb/set-credentials.sh` | prompt-based credential setter (no echo, no history) |
| `anvil/.env` | anvil `/opt/smartbulb/.env` (mode 600) | **credentials — not in git** |
| `acer/waybar-bulb` | acer `~/.local/bin/waybar-bulb` | waybar custom module reader/controller |
| systemd | anvil `smartbulb-broker.service` | runs the broker, `Restart=always` |

## Credentials & settings

**Everything needed to move this to a fresh machine is in this project plus the
ledger** — with ONE exception: the Tapo account password (see below).

- **Account email:** `johannvdventer@gmail.com`
- **Bulb IP:** `192.168.1.225` (Tapo L530, MAC `B4-B0-24-E3-44-AE`)
- **Broker bind:** anvil `192.168.1.8:9130`
- **Tapo library:** `tapo` (PyPI, v0.11.0) — NOT `python-tapo`. Installed in
  `/opt/smartbulb/venv` on anvil.

To restore on a new box:
1. `python3 -m venv /opt/smartbulb/venv && /opt/smartbulb/venv/bin/pip install tapo`
2. copy `broker.py` to `/opt/smartbulb/`
3. run `set-credentials.sh` (asks for the password interactively)
4. install the systemd unit (below)

> **The Tapo account password is the only thing not recoverable from files.** The
> old `.env` was destroyed when acer was wiped (2026-10-02); it was never in the
> vault (the ledger is "No secrets") or in `clarity-secrets`. Re-enter it once via
> `set-credentials.sh` — it is then stored in anvil `/opt/smartbulb/.env` (600).

## States & patterns

|| State | Bulb | waybar |
||---|---|---|
|| `idle` | cool white CT 4000, brightness 5 | dim grey ● |
|| `working` | cool white breathe (5%↔35%) | blue pulse (2 s) |
|| `needs_input` | **white↔red flash** (0.5 s) | **red flash (0.5 s)** |
|| `done` | white↔red ×5 → green → idle | brief green |
|| `error` | red ×2 → idle | red solid |
|| `off` | bulb off | grey ● |
|| `mail_checked` | **blue flash** (0.5 s) | blue flash |
|| `git_updated` | **green flash** (0.5 s) | green flash |
|| `backup_fail` | red↔blue police light (every 10 min for 1 hr) | police light |

Precedence: `needs_input` should win over `working`. The broker applies the latest
requested state (last-write-wins on a monotonically increasing `seq`).

### New patterns (Oct 2026)

- **mail_checked**: Blue flash when mail processing completes without user action needed
- **git_updated**: Green flash when git operations complete successfully  
- **backup_fail**: Police light pattern (red↔blue) that flashes every 10 minutes for 1 hour when backup fails. Triggered via `/set/backup_fail`.

## API

```
GET  /status          -> {"state","applied","since","seq","connected","uptime"}
GET  /bar             -> {"text","class","tooltip"}   (waybar JSON)
GET  /set/<state>     -> set state, returns /bar JSON
POST /state {"state":} -> set state, returns /status
GET  /health          -> {"ok":true}
```

## systemd unit (anvil)

```ini
[Unit]
Description=Smart-bulb status broker (Tapo L530, :9130)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=warpuppy
Group=warpuppy
ExecStart=/opt/smartbulb/venv/bin/python /opt/smartbulb/broker.py
Restart=always
RestartSec=3
WorkingDirectory=/opt/smartbulb

[Install]
WantedBy=multi-user.target
```

## waybar integration (acer)

`~/.config/waybar/config` → `modules-right` includes `"custom/smartbulb"`:

```json
"custom/smartbulb": {
  "exec": "/home/warpuppy/.local/bin/waybar-bulb",
  "interval": 2,
  "return-type": "json",
  "tooltip": true,
  "on-click": "/home/warpuppy/.local/bin/waybar-bulb set idle",
  "on-click-right": "/home/warpuppy/.local/bin/waybar-bulb set working"
}
```

`~/.config/waybar/style.css` → state classes + `@keyframes` (GTK CSS: keyframe
selectors must be one percentage per block — `0%{} 50%{} 100%{}`, NOT `0%,50%{}`).

## Usage

```bash
# from acer
~/.local/bin/waybar-bulb                 # bar JSON
~/.local/bin/waybar-bulb set needs_input # flash red (asking for input)
~/.local/bin/waybar-bulb set working
~/.local/bin/waybar-bulb set idle

# direct
curl http://192.168.1.8:9130/set/needs_input
```

## Hermes hook

To make patterns fire automatically, Hermes calls the broker on lifecycle events:
turn start → `working`; question/approval → `needs_input`; turn end → `done` then
`idle`. A small wrapper (see `hermes-hook.sh` when added) does this without
blocking the agent.

### New hook events

Additional events added in Oct 2026:
- `mail_checked` → sets `mail_checked` state (blue flash)
- `git_updated` → sets `git_updated` state (green flash)
- `backup_fail` → sets `backup_fail` state (police light, auto-periodics)

## Pitfalls learned

- PyPI package is **`tapo`**, not `python-tapo`.
- GTK CSS rejects `0%, 50% {}` grouped keyframe selectors — split them.
- Do NOT `pkill -SIGUSR2 waybar`; it exits. Use `waybar` restart via Hyprland
  (`hl.exec_cmd("waybar")`) or launch it under the compositor env.
- anvil is headless → use a **system** service, not a user service (no linger).
- The bulb never reports state back (local HTTP 1003); the broker tracks last state.
