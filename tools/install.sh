#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKIP_APT="${PWNAGOTCHI_INSTALL_SKIP_APT:-0}"
FONT_DIR="/usr/share/fonts/truetype/pwnagotchi"
SERVICE_NAME="${PWNAGOTCHI_SERVICE_NAME:-pwnagotchi}"
BUNDLED_FONTS=""
for d in "$SCRIPT_DIR/fonts" "/usr/share/APPLaunch/share/pwnagotchi/fonts"; do
    if [[ -d "$d" && -n "$(ls -A "$d" 2>/dev/null)" ]]; then
        BUNDLED_FONTS="$d"
        break
    fi
done

install_systemd_safeguards() {
    echo "Installing systemd safeguards for all pwnagotchi services..."

    sudo mkdir -p /etc/systemd/system/${SERVICE_NAME}.service.d
    sudo tee /etc/systemd/system/${SERVICE_NAME}.service.d/cardputer-override.conf >/dev/null <<EOF
[Unit]
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
ExecStart=
ExecStart=/usr/local/bin/pwnagotchi-cardputer-launch
Restart=on-failure
RestartSec=10
MemoryMax=200M
MemoryHigh=180M
TimeoutStartSec=90
EOF

    if systemctl cat bettercap.service >/dev/null 2>&1; then
        sudo mkdir -p /etc/systemd/system/bettercap.service.d
        sudo tee /etc/systemd/system/bettercap.service.d/cardputer-safeguard.conf >/dev/null <<'BCEOF'
[Unit]
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
ExecStart=
ExecStart=/usr/local/bin/bettercap-cardputer-launch
Restart=on-failure
RestartSec=10
MemoryMax=150M
MemoryHigh=120M
TimeoutStartSec=60
BCEOF
    fi

    if systemctl cat pwngrid-peer.service >/dev/null 2>&1; then
        sudo mkdir -p /etc/systemd/system/pwngrid-peer.service.d
        sudo tee /etc/systemd/system/pwngrid-peer.service.d/cardputer-safeguard.conf >/dev/null <<'PGEOF'
[Unit]
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
Restart=on-failure
RestartSec=10
MemoryMax=80M
PGEOF
    fi

    sudo systemctl daemon-reload
}

install_bettercap_wrapper() {
    echo "Installing bettercap launcher wrapper..."

    local bettercap_bin=""
    for candidate in /usr/bin/bettercap /usr/local/bin/bettercap; do
        if [[ -x "$candidate" ]]; then
            bettercap_bin="$candidate"
            break
        fi
    done

    if [[ -z "$bettercap_bin" ]]; then
        echo "Warning: bettercap not found; skipping wrapper."
        return 0
    fi

    local caplet_dir=""
    for candidate in /usr/share/bettercap/caplets /usr/local/share/bettercap/caplets; do
        if [[ -d "$candidate" ]]; then
            caplet_dir="$candidate"
            break
        fi
    done

    sudo tee /usr/local/bin/bettercap-cardputer-launch >/dev/null <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail

BETTERCAP_BIN="$bettercap_bin"
CAPLET_DIR="${caplet_dir:-/usr/share/bettercap/caplets}"
MODE_FILE="/etc/default/pwnagotchi-cardputer"
if [[ -f "\$MODE_FILE" ]]; then
    source "\$MODE_FILE"
fi
IFACE="\${PWNAGOTCHI_IFACE:-wlan0mon}"
SOURCE_IFACE="\${PWNAGOTCHI_SOURCE_IFACE:-}"
MAX_RETRIES=3
RETRY_DELAY=5
IW_BIN="\$(command -v iw 2>/dev/null || true)"
if [[ -z "\$IW_BIN" && -x /usr/sbin/iw ]]; then
    IW_BIN=/usr/sbin/iw
fi
if [[ -z "\$IW_BIN" ]]; then
    echo "[bettercap-launch] ERROR: iw not found in PATH or /usr/sbin/iw"
    exit 1
fi

detect_source_iface() {
    if [[ -n "\$SOURCE_IFACE" ]]; then
        echo "\$SOURCE_IFACE"
        return 0
    fi
    if "\$IW_BIN" dev "\$IFACE" info >/dev/null 2>&1; then
        echo "\$IFACE"
        return 0
    fi
    if [[ "\$IFACE" == *mon ]]; then
        local candidate="\${IFACE%mon}"
        if "\$IW_BIN" dev "\$candidate" info >/dev/null 2>&1; then
            echo "\$candidate"
            return 0
        fi
    fi
    for candidate in wlan1 wlan0; do
        if "\$IW_BIN" dev "\$candidate" info >/dev/null 2>&1; then
            echo "\$candidate"
            return 0
        fi
    done
    return 1
}

setup_monitor_interface() {
    if ip link show "\$IFACE" >/dev/null 2>&1; then
        "\$IW_BIN" dev "\$IFACE" set type monitor 2>/dev/null || true
        ip link set "\$IFACE" up 2>/dev/null || true
        return 0
    fi

    echo "[bettercap-launch] Setting up monitor interface \$IFACE..."

    local source_iface
    if ! source_iface="\$(detect_source_iface)"; then
        echo "[bettercap-launch] ERROR: no wireless source interface found"
        return 1
    fi

    command -v rfkill >/dev/null 2>&1 && rfkill unblock wifi 2>/dev/null || true
    ip link set "\$source_iface" up 2>/dev/null || true
    sleep 1
    "\$IW_BIN" dev "\$source_iface" set power_save off 2>/dev/null || true

    local phy
    phy="\$("\$IW_BIN" dev "\$source_iface" info 2>/dev/null | awk '/wiphy/{print "phy"\$2}' || echo phy0)"

    for attempt in \$(seq 1 \$MAX_RETRIES); do
        if "\$IW_BIN" phy "\$phy" interface add "\$IFACE" type monitor 2>/dev/null; then
            sleep 1
            if [[ "\$source_iface" != "\$IFACE" ]]; then
                ip link set "\$source_iface" down 2>/dev/null || true
            fi
            ip link set "\$IFACE" up 2>/dev/null || true
            "\$IW_BIN" dev "\$IFACE" set power_save off 2>/dev/null || true
            echo "[bettercap-launch] Monitor interface \$IFACE is up."
            return 0
        fi
        echo "[bettercap-launch] Attempt \$attempt/\$MAX_RETRIES to create monitor interface failed."
        sleep \$RETRY_DELAY
    done

    echo "[bettercap-launch] ERROR: Cannot create monitor interface. Use a monitor-capable USB Wi-Fi adapter."
    return 1
}

if ! setup_monitor_interface; then
    exit 1
fi

CAPLET="pwnagotchi-auto"
if [[ "\${PWNAGOTCHI_MODE:-}" == "manual" ]]; then
    CAPLET="pwnagotchi-manual"
fi

exec "\$BETTERCAP_BIN" -no-colors -caplet "\$CAPLET" -iface "\$IFACE"
WRAPPER
    sudo chmod 0755 /usr/local/bin/bettercap-cardputer-launch
}

configure_bettercap_caplets() {
    local mode_file="/etc/default/pwnagotchi-cardputer"
    local iface="${PWNAGOTCHI_IFACE:-wlan0mon}"
    local handshakes_file="${PWNAGOTCHI_HANDSHAKES_FILE:-/home/pi/handshakes/bettercap-wifi-handshakes.pcap}"
    if [[ -f "$mode_file" ]]; then
        # shellcheck disable=SC1090
        source "$mode_file"
        iface="${PWNAGOTCHI_IFACE:-$iface}"
        handshakes_file="${PWNAGOTCHI_HANDSHAKES_FILE:-$handshakes_file}"
    fi

    sudo mkdir -p "$(dirname "$handshakes_file")"
    sudo chown pi:pi "$(dirname "$handshakes_file")" 2>/dev/null || true

    for caplet in /usr/share/bettercap/caplets/pwnagotchi-auto.cap /usr/share/bettercap/caplets/pwnagotchi-manual.cap; do
        [[ -f "$caplet" ]] || continue
        if grep -q '^set wifi.interface ' "$caplet"; then
            sudo sed -i "s|^set wifi.interface .*|set wifi.interface $iface|" "$caplet"
        else
            echo "set wifi.interface $iface" | sudo tee -a "$caplet" >/dev/null
        fi
        sudo sed -i '/^set wifi.handshakes.file /d' "$caplet"
        if grep -q '^wifi.recon on' "$caplet"; then
            sudo sed -i "0,/^wifi.recon on/s|^wifi.recon on|set wifi.handshakes.file $handshakes_file\\nwifi.recon on|" "$caplet"
        else
            echo "set wifi.handshakes.file $handshakes_file" | sudo tee -a "$caplet" >/dev/null
        fi
    done
}

ensure_cardputer_defaults() {
    local mode_file="/etc/default/pwnagotchi-cardputer"
    sudo touch "$mode_file"
    if ! grep -q '^PWNAGOTCHI_SOURCE_IFACE=' "$mode_file"; then
        echo 'PWNAGOTCHI_SOURCE_IFACE=wlan1' | sudo tee -a "$mode_file" >/dev/null
    fi
    if ! grep -q '^PWNAGOTCHI_IFACE=' "$mode_file"; then
        echo 'PWNAGOTCHI_IFACE=wlan1mon' | sudo tee -a "$mode_file" >/dev/null
    fi
    if ! grep -q '^PWNAGOTCHI_MODE=' "$mode_file"; then
        echo 'PWNAGOTCHI_MODE=auto' | sudo tee -a "$mode_file" >/dev/null
    fi
    if ! grep -q '^PWNAGOTCHI_HANDSHAKES_FILE=' "$mode_file"; then
        echo 'PWNAGOTCHI_HANDSHAKES_FILE=/home/pi/handshakes/bettercap-wifi-handshakes.pcap' | sudo tee -a "$mode_file" >/dev/null
    fi
}

install_pwnagotchi_launcher() {
    echo "Installing pwnagotchi launcher..."

sudo tee /usr/local/bin/pwnagotchi-cardputer-launch >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MODE_FILE=/etc/default/pwnagotchi-cardputer
if [[ -f "$MODE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MODE_FILE"
fi

MAX_WAIT=30
waited=0
IFACE="${PWNAGOTCHI_IFACE:-wlan0mon}"
while ! ip link show "$IFACE" >/dev/null 2>&1; do
    if [[ $waited -ge $MAX_WAIT ]]; then
        echo "[pwnagotchi-launch] Warning: monitor interface $IFACE not ready after ${MAX_WAIT}s"
        break
    fi
    sleep 2
    waited=$((waited + 2))
done

MODE_ARG=""
if [[ "${PWNAGOTCHI_MODE:-}" == "manual" ]]; then
    MODE_ARG="--manual"
fi
exec /usr/local/bin/pwnagotchi $MODE_ARG
EOF
    sudo chmod 0755 /usr/local/bin/pwnagotchi-cardputer-launch
}

echo "=== Pwnagotchi App Launcher installer ==="

SYSTEM_PKGS="python3 python3-pil curl fonts-noto-cjk fonts-noto-color-emoji binutils iw wireless-tools rfkill"
if [[ "$SKIP_APT" == "1" ]]; then
    echo "Skipping apt during package configuration; expected packages: $SYSTEM_PKGS"
else
    sudo apt-get update -qq
    sudo apt-get install -y $SYSTEM_PKGS
fi

sudo mkdir -p "$FONT_DIR"
if [[ ! -f "$FONT_DIR/NotoSansSC-Bold.ttf" && -n "$BUNDLED_FONTS" && -f "$BUNDLED_FONTS/NotoSansSC-Bold.ttf" ]]; then
    sudo cp "$BUNDLED_FONTS/NotoSansSC-Bold.ttf" "$FONT_DIR/NotoSansSC-Bold.ttf"
elif [[ ! -f "$FONT_DIR/NotoSansSC-Bold.ttf" && "$SKIP_APT" != "1" ]]; then
    sudo curl -fsSLo "$FONT_DIR/NotoSansSC-Bold.ttf" \
        "https://github.com/google/fonts/raw/main/ofl/notosanssc/static/NotoSansSC-Bold.ttf" || true
fi
if [[ ! -f "$FONT_DIR/NotoColorEmoji.ttf" && -n "$BUNDLED_FONTS" && -f "$BUNDLED_FONTS/NotoColorEmoji.ttf" ]]; then
    sudo cp "$BUNDLED_FONTS/NotoColorEmoji.ttf" "$FONT_DIR/NotoColorEmoji.ttf"
elif [[ ! -f "$FONT_DIR/NotoColorEmoji.ttf" && "$SKIP_APT" != "1" ]]; then
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

ensure_cardputer_defaults

if [[ ! -x /usr/local/bin/pwnagotchi ]] || { [[ ! -f /etc/systemd/system/${SERVICE_NAME}.service ]] && ! systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; }; then
    "$SCRIPT_DIR/bootstrap_pwnagotchi.sh"
fi

install_pwnagotchi_launcher
install_bettercap_wrapper
configure_bettercap_caplets
install_systemd_safeguards

echo ""
echo "=== Installation Summary ==="
echo "Service: $SERVICE_NAME"
echo "Monitor interface: configure PWNAGOTCHI_SOURCE_IFACE/PWNAGOTCHI_IFACE for a USB adapter"
echo ""
echo "Installer complete."
