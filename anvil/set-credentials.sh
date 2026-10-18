#!/bin/bash
# Set the smart-bulb broker credentials on anvil.
# Writes /opt/smartbulb/.env (mode 600, owned by warpuppy). Password is read
# WITHOUT echo and is NOT written to shell history. Run this on anvil:
#     ssh anvil /opt/smartbulb/set-credentials.sh
set -euo pipefail

ENV=/opt/smartbulb/.env
read -rp "Tapo account email [johannvdventer@gmail.com]: " EMAIL
EMAIL=${EMAIL:-johannvdventer@gmail.com}
read -rsp "Tapo account password (hidden): " PASS; echo
read -rp "Bulb IP [192.168.1.225]: " BIP
BIP=${BIP:-192.168.1.225}

umask 077
cat > "$ENV" <<EOF
SMARTBULB_TAPO_USER=$EMAIL
SMARTBULB_TAPO_PASS=$PASS
SMARTBULB_IP=$BIP
EOF
chmod 600 "$ENV"
unset PASS

echo "wrote $ENV ($(stat -c '%a %U' "$ENV"))"
sudo systemctl restart smartbulb-broker.service
sleep 3
echo "--- broker status ---"
curl -fsS --max-time 4 http://127.0.0.1:9130/status || echo "broker not responding"
echo
echo "connected should now be true. If not, check: journalctl -u smartbulb-broker -n 30"
