#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/jayofelony-pwnagotchi}"
SERVICE_NAME="${PWNAGOTCHI_SERVICE_NAME:-pwnagotchi}"
ARCHIVE_PATH="${PWNAGOTCHI_ARCHIVE_PATH:-/tmp/pwnagotchi-master.tar.gz}"

sudo apt-get update
sudo apt-get install -y git python3 python3-pip bettercap

if [[ -f "$ARCHIVE_PATH" ]]; then
    sudo rm -rf "$REPO_DIR"
    sudo mkdir -p "$REPO_DIR"
    sudo tar -xzf "$ARCHIVE_PATH" --strip-components=1 -C "$REPO_DIR"
elif [[ ! -d "$REPO_DIR/.git" ]]; then
    sudo rm -rf "$REPO_DIR"
    sudo git clone --depth 1 https://github.com/jayofelony/pwnagotchi "$REPO_DIR"
fi

TMP_REQ="/tmp/pwnagotchi-minimal-requirements.txt"
grep -Ev '^(stable_baselines3|torch|shimmy|gymnasium|tweepy|inky|flask-wtf|rpi_hardware_pwm|pydrive2)([<>=].*)?$' "$REPO_DIR/requirements.txt" | sudo tee "$TMP_REQ" >/dev/null
sudo pip3 install --break-system-packages -r "$TMP_REQ"
sudo pip3 install --break-system-packages --no-deps "$REPO_DIR"

sudo mkdir -p /etc/pwnagotchi
if [[ ! -f /etc/pwnagotchi/config.toml ]]; then
    sudo tee /etc/pwnagotchi/config.toml >/dev/null <<'EOF'
[main]
name = "cardputer"
lang = "en"
EOF
fi

if [[ ! -f /etc/systemd/system/${SERVICE_NAME}.service ]]; then
    sudo tee /etc/systemd/system/${SERVICE_NAME}.service >/dev/null <<'EOF'
[Unit]
Description=Pwnagotchi
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/pwnagotchi
Restart=always

[Install]
WantedBy=multi-user.target
EOF
fi

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"
echo "Bootstrap complete"
