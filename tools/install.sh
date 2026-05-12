#!/usr/bin/env bash
set -euo pipefail

FONT_DIR="/usr/share/fonts/truetype/pwnagotchi"
SERVICE_NAME="${PWNAGOTCHI_SERVICE_NAME:-pwnagotchi}"

echo "=== Pwnagotchi App Launcher installer ==="

sudo apt-get update -qq
sudo apt-get install -y python3 python3-pil curl fonts-noto-cjk fonts-noto-color-emoji

sudo mkdir -p "$FONT_DIR"
if [[ ! -f "$FONT_DIR/NotoSansSC-Bold.ttf" ]]; then
    sudo curl -fsSLo "$FONT_DIR/NotoSansSC-Bold.ttf" \
        "https://github.com/google/fonts/raw/main/ofl/notosanssc/static/NotoSansSC-Bold.ttf" || true
fi
if [[ ! -f "$FONT_DIR/NotoColorEmoji.ttf" ]]; then
    sudo curl -fsSLo "$FONT_DIR/NotoColorEmoji.ttf" \
        "https://github.com/google/fonts/raw/main/ofl/notocoloremoji/NotoColorEmoji%5Bwght%5D.ttf" || true
fi
if [[ ! -f "$FONT_DIR/NotoSansSC-Bold.ttf" && -f /usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc ]]; then
    sudo ln -sf /usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc "$FONT_DIR/NotoSansSC-Bold.ttf"
fi
if [[ ! -f "$FONT_DIR/NotoColorEmoji.ttf" && -f /usr/share/fonts/truetype/noto/NotoColorEmoji.ttf ]]; then
    sudo ln -sf /usr/share/fonts/truetype/noto/NotoColorEmoji.ttf "$FONT_DIR/NotoColorEmoji.ttf"
fi
command -v fc-cache >/dev/null 2>&1 && sudo fc-cache -f "$FONT_DIR" || true

sudo mkdir -p /etc/systemd/system/${SERVICE_NAME}.service.d
sudo tee /usr/local/bin/pwnagotchi-cardputer-launch >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
MODE_FILE=/etc/default/pwnagotchi-cardputer
MODE_ARG=""
if [[ -f "$MODE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MODE_FILE"
    if [[ "${PWNAGOTCHI_MODE:-}" == "manual" ]]; then
        MODE_ARG="--manual"
    fi
fi
exec /usr/local/bin/pwnagotchi $MODE_ARG
EOF
sudo chmod 0755 /usr/local/bin/pwnagotchi-cardputer-launch

sudo tee /etc/systemd/system/${SERVICE_NAME}.service.d/cardputer-override.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=/usr/local/bin/pwnagotchi-cardputer-launch
EOF

sudo touch /etc/default/pwnagotchi-cardputer
sudo systemctl daemon-reload
if [[ ! -x /usr/local/bin/pwnagotchi ]] || [[ ! -f /etc/systemd/system/${SERVICE_NAME}.service ]] && ! systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    "$(dirname "$0")/bootstrap_pwnagotchi.sh"
fi

echo ""
echo "=== WiFi Monitor Mode Note ==="
echo "Pwnagotchi requires a WiFi interface that supports monitor mode."
echo "The built-in WiFi on some boards (esp. BCM43439 on CM0) does NOT"
echo "support monitor mode with stock firmware."
echo ""
echo "To enable monitor mode:"
echo "  1. Use an external USB WiFi adapter (e.g. RTL8812AU, MT7612U)"
echo "  2. Or install nexmon firmware patches (only for BCM43430/43436s/43455)"
echo "     See: https://github.com/seemoo-lab/nexmon"
echo ""
echo "Without monitor mode, the app shows status but cannot scan Wi-Fi."
echo "To use an external adapter, set PWNAGOTCHI_IFACE env var."
echo ""

echo "Installer complete for service: $SERVICE_NAME"
