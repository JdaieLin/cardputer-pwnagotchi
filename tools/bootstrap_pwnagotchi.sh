#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/jayofelony-pwnagotchi}"
SERVICE_NAME="${PWNAGOTCHI_SERVICE_NAME:-pwnagotchi}"
ARCHIVE_PATH="${PWNAGOTCHI_ARCHIVE_PATH:-/tmp/pwnagotchi-master.tar.gz}"
SKIP_APT="${PWNAGOTCHI_INSTALL_SKIP_APT:-0}"

if [[ "$SKIP_APT" == "1" ]]; then
    echo "Skipping apt during package configuration; system packages are provided by the .deb Depends field."
else
    sudo apt-get update
    sudo apt-get install -y git python3 python3-pip iw wireless-tools

    if command -v bettercap >/dev/null 2>&1; then
        echo "bettercap already installed."
    else
        sudo apt-get install -y bettercap || echo "Warning: bettercap not available in apt; install manually."
    fi
fi

if [[ -f "$ARCHIVE_PATH" ]]; then
    sudo rm -rf "$REPO_DIR"
    sudo mkdir -p "$REPO_DIR"
    sudo tar -xzf "$ARCHIVE_PATH" --strip-components=1 -C "$REPO_DIR"
elif [[ ! -d "$REPO_DIR/.git" ]]; then
    sudo rm -rf "$REPO_DIR"
    sudo git clone --depth 1 https://github.com/jayofelony/pwnagotchi "$REPO_DIR"
fi

TMP_REQ="/tmp/pwnagotchi-minimal-requirements.txt"
grep -Ev '^(stable_baselines3|torch|shimmy|gymnasium|tweepy|inky|rpi_hardware_pwm|pydrive2)([<>=].*)?$' "$REPO_DIR/requirements.txt" | sudo tee "$TMP_REQ" >/dev/null
sudo pip3 install --break-system-packages -r "$TMP_REQ"
sudo pip3 install --break-system-packages --no-deps "$REPO_DIR"

PWNAGOTCHI_BIN="$(command -v pwnagotchi || true)"
if [[ -z "$PWNAGOTCHI_BIN" && -x /usr/local/bin/pwnagotchi ]]; then
    PWNAGOTCHI_BIN=/usr/local/bin/pwnagotchi
fi
if [[ -n "$PWNAGOTCHI_BIN" ]]; then
    sudo python3 - "$PWNAGOTCHI_BIN" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
if "from pwnagotchi.google import cmd as google_cmd" in text:
    text = text.replace(
        "from pwnagotchi.google import cmd as google_cmd",
        "try:\n"
        "    from pwnagotchi.google import cmd as google_cmd\n"
        "except ModuleNotFoundError as exc:\n"
        "    if exc.name != \"pydrive2\":\n"
        "        raise\n"
        "    google_cmd = None",
    )
    text = text.replace(
        "        # Add parsers from google_cmd\n        google_cmd.add_parsers(subparsers)",
        "        # Add parsers from google_cmd\n"
        "        if google_cmd is not None:\n"
        "            google_cmd.add_parsers(subparsers)",
    )
    text = text.replace(
        "    if google_cmd.used_google_cmd(args):",
        "    if google_cmd is not None and google_cmd.used_google_cmd(args):",
    )
    path.write_text(text)
PY
fi

sudo mkdir -p /etc/pwnagotchi
if [[ ! -f /etc/pwnagotchi/config.toml ]]; then
    sudo tee /etc/pwnagotchi/config.toml >/dev/null <<'EOF'
[main]
name = "cardputer"
lang = "en"
EOF
fi

if [[ ! -f /etc/systemd/system/${SERVICE_NAME}.service ]] && ! systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    sudo tee /etc/systemd/system/${SERVICE_NAME}.service >/dev/null <<EOF
[Unit]
Description=Pwnagotchi
After=network-online.target bettercap.service
Wants=bettercap.service

StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
Type=simple
ExecStart=/usr/local/bin/pwnagotchi
Restart=on-failure
RestartSec=10
MemoryMax=200M
MemoryHigh=180M
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
EOF
fi

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
echo "Bootstrap complete"
