#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FONT_DIR="/usr/share/fonts/truetype/pwnagotchi"
SERVICE_NAME="${PWNAGOTCHI_SERVICE_NAME:-pwnagotchi}"
NEXMON_MODE="${PWNAGOTCHI_NEXMON_MODE:-auto}"
NEXMON_PATCH_VERSION="7.95.49 (2271bb6 CY)"
NEXMON_PATCH_LOCAL="${PWNAGOTCHI_NEXMON_PATCH:-}"
NEXMON_FIRMWARE_TARGET="/lib/firmware/brcm/brcmfmac43439-sdio.bin"
NEXMON_FIRMWARE_BACKUP="/lib/firmware/brcm/brcmfmac43439-sdio.bin.orig"
NEXMON_FW_URL="https://kali.download/kali/pool/non-free-firmware/f/firmware-nexmon/firmware-nexmon_0.2_all.deb"
NEXMON_DKMS_URL="https://kali.download/kali/pool/contrib/b/brcmfmac-nexmon-dkms/brcmfmac-nexmon-dkms_6.12.2_all.deb"

resolve_nexmon_firmware() {
    if [[ -n "$NEXMON_PATCH_LOCAL" && -f "$NEXMON_PATCH_LOCAL" ]]; then
        return 0
    fi

    for candidate in \
        "$SCRIPT_DIR/nexmon/nexmon-patched-43439.bin" \
        "$ROOT_DIR/nexmon/nexmon-patched-43439.bin"; do
        if [[ -f "$candidate" ]]; then
            NEXMON_PATCH_LOCAL="$candidate"
            return 0
        fi
    done

    echo "No local nexmon firmware found; downloading from Kali repository..."
    local tmp_dir="/tmp/nexmon-fw-install"
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"
    if ! curl -fsSL -o "$tmp_dir/firmware-nexmon.deb" "$NEXMON_FW_URL"; then
        echo "Warning: failed to download nexmon firmware package."
        return 1
    fi
    (cd "$tmp_dir" && ar x firmware-nexmon.deb && tar -xf data.tar.*)
    local combined="$tmp_dir/usr/lib/firmware/cypress/43439A0-7.95.49.00.combined"
    if [[ -f "$combined" ]]; then
        NEXMON_PATCH_LOCAL="$combined"
        return 0
    fi
    echo "Warning: downloaded package did not contain expected firmware."
    return 1
}

install_nexmon_dkms() {
    if lsmod | grep -q brcmfmac && modinfo brcmfmac 2>/dev/null | grep -q nexmon; then
        echo "Nexmon DKMS module already installed."
        return 0
    fi

    echo "Installing nexmon DKMS kernel module..."
    sudo apt-get install -y dkms raspberrypi-kernel-headers 2>/dev/null || true

    if ! dpkg -s brcmfmac-nexmon-dkms >/dev/null 2>&1; then
        local tmp_deb="/tmp/brcmfmac-nexmon-dkms.deb"
        if curl -fsSL -o "$tmp_deb" "$NEXMON_DKMS_URL"; then
            sudo dpkg -i "$tmp_deb" 2>&1 || sudo apt-get install -f -y 2>&1 || true
            rm -f "$tmp_deb"
        else
            echo "Warning: failed to download nexmon DKMS module."
        fi
    fi
}

install_nexmon_patch() {
    if [[ "$NEXMON_MODE" == "off" ]]; then
        echo "Skipping nexmon patch install (PWNAGOTCHI_NEXMON_MODE=off)."
        return 0
    fi

    if [[ ! -f "$NEXMON_FIRMWARE_TARGET" ]]; then
        echo "No BCM43439 firmware found at $NEXMON_FIRMWARE_TARGET; skipping."
        return 0
    fi

    local current_version
    current_version="$(strings "$NEXMON_FIRMWARE_TARGET" 2>/dev/null | grep -m1 'Version: 7\.95\.' || true)"

    if [[ -n "$current_version" && "$current_version" == *"$NEXMON_PATCH_VERSION"* ]]; then
        echo "BCM43439 firmware already matches nexmon patch version; skipping."
        return 0
    fi

    if ! resolve_nexmon_firmware; then
        echo "No nexmon firmware available; skipping patch."
        return 0
    fi

    echo "Installing BCM43439 nexmon monitor-mode firmware..."
    echo "  current: ${current_version:-unknown}"
    echo "  target:  $NEXMON_PATCH_VERSION"

    local real_target
    real_target="$(readlink -f "$NEXMON_FIRMWARE_TARGET" 2>/dev/null || echo "$NEXMON_FIRMWARE_TARGET")"

    if [[ ! -f "$NEXMON_FIRMWARE_BACKUP" ]]; then
        sudo cp "$real_target" "$NEXMON_FIRMWARE_BACKUP"
        echo "  backup:  $NEXMON_FIRMWARE_BACKUP"
    fi

    if [[ -L "$NEXMON_FIRMWARE_TARGET" ]]; then
        sudo rm -f "$NEXMON_FIRMWARE_TARGET"
    fi
    sudo cp "$NEXMON_PATCH_LOCAL" "$NEXMON_FIRMWARE_TARGET"
    sudo chmod 0644 "$NEXMON_FIRMWARE_TARGET"

    for variant in /lib/firmware/brcm/brcmfmac43439-sdio.raspberrypi,*.bin; do
        [[ -e "$variant" ]] || continue
        if [[ -L "$variant" ]]; then
            sudo rm -f "$variant"
            sudo cp "$NEXMON_PATCH_LOCAL" "$variant"
            sudo chmod 0644 "$variant"
        fi
    done

    install_nexmon_dkms
    echo "Installed nexmon firmware. A reboot is required to activate monitor mode."
}

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

    echo "[bettercap-launch] ERROR: Cannot create monitor interface. Is nexmon firmware installed?"
    echo "[bettercap-launch] Run: PWNAGOTCHI_NEXMON_MODE=force /path/to/install.sh"
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

install_pwnagotchi_launcher() {
    echo "Installing pwnagotchi launcher..."

    sudo tee /usr/local/bin/pwnagotchi-cardputer-launch >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

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
}

echo "=== Pwnagotchi App Launcher installer ==="

sudo apt-get update -qq
sudo apt-get install -y python3 python3-pil curl fonts-noto-cjk fonts-noto-color-emoji binutils iw wireless-tools

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

sudo touch /etc/default/pwnagotchi-cardputer

if [[ ! -x /usr/local/bin/pwnagotchi ]] || { [[ ! -f /etc/systemd/system/${SERVICE_NAME}.service ]] && ! systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; }; then
    "$SCRIPT_DIR/bootstrap_pwnagotchi.sh"
fi

install_pwnagotchi_launcher
install_bettercap_wrapper
configure_bettercap_caplets
install_systemd_safeguards
install_nexmon_patch

echo ""
echo "=== Installation Summary ==="
echo "Service: $SERVICE_NAME"
if strings "$NEXMON_FIRMWARE_TARGET" 2>/dev/null | grep -q "$NEXMON_PATCH_VERSION"; then
    echo "Nexmon: installed (reboot to activate if newly installed)"
else
    echo "Nexmon: NOT installed — monitor mode unavailable"
    echo "  To force install: PWNAGOTCHI_NEXMON_MODE=force $0"
fi
echo ""
echo "Installer complete."
