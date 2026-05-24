#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
PKG_ROOT="$BUILD_DIR/applaunch-package"
BIN="$BUILD_DIR/pwnagotchi_app"
OUT_DEB="$BUILD_DIR/pwnagotchi-applaunch_0.1-m5stack1_arm64.deb"
ICON_SRC="${PWNAGOTCHI_ICON_SRC:-$ROOT_DIR/tools/assets/pwnagotchi.png}"

if [[ ! -x "$BIN" ]]; then
    echo "missing binary: $BIN"
    exit 1
fi

rm -rf "$PKG_ROOT" "$OUT_DEB"
mkdir -p \
    "$PKG_ROOT/DEBIAN" \
    "$PKG_ROOT/usr/share/APPLaunch/applications" \
    "$PKG_ROOT/usr/share/APPLaunch/bin" \
    "$PKG_ROOT/usr/share/APPLaunch/share/images" \
    "$PKG_ROOT/usr/share/APPLaunch/share/pwnagotchi" \
    "$PKG_ROOT/usr/share/APPLaunch/share/pwnagotchi/nexmon"

install -m 0755 "$BIN" "$PKG_ROOT/usr/share/APPLaunch/bin/pwnagotchi_app"
install -m 0644 "$ROOT_DIR/main/tools/pwnagotchi_bridge.py" "$PKG_ROOT/usr/share/APPLaunch/share/pwnagotchi/pwnagotchi_bridge.py"
install -m 0644 "$ROOT_DIR/main/tools/display_bridge.py" "$PKG_ROOT/usr/share/APPLaunch/share/pwnagotchi/display_bridge.py"
install -m 0755 "$ROOT_DIR/tools/install.sh" "$PKG_ROOT/usr/share/APPLaunch/share/pwnagotchi/install.sh"
install -m 0755 "$ROOT_DIR/tools/bootstrap_pwnagotchi.sh" "$PKG_ROOT/usr/share/APPLaunch/share/pwnagotchi/bootstrap_pwnagotchi.sh"
install -m 0644 "$ROOT_DIR/nexmon/nexmon-patched-43439.bin" "$PKG_ROOT/usr/share/APPLaunch/share/pwnagotchi/nexmon/nexmon-patched-43439.bin"
install -m 0644 "$ICON_SRC" "$PKG_ROOT/usr/share/APPLaunch/share/images/pwnagotchi.png"

cat > "$PKG_ROOT/usr/share/APPLaunch/bin/pwnagotchi_launcher" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

detect_fbdev() {
    if [[ -n "${APPLAUNCH_LINUX_FBDEV_DEVICE:-}" ]]; then
        echo "$APPLAUNCH_LINUX_FBDEV_DEVICE"
    else
        echo /dev/fb0
    fi
}

export PWNAGOTCHI_BRIDGE=/usr/share/APPLaunch/share/pwnagotchi/pwnagotchi_bridge.py
export PWNAGOTCHI_DISPLAY_BRIDGE=/usr/share/APPLaunch/share/pwnagotchi/display_bridge.py
export PWNAGOTCHI_FBDEV="$(detect_fbdev)"
export PWNAGOTCHI_KEYBOARD_DEVICE="${APPLAUNCH_LINUX_KEYBOARD_DEVICE:-/dev/input/by-path/platform-3f804000.i2c-event}"

resolve_log_dir() {
    local shared_dir="/tmp/pwnagotchi_logs"
    local fallback_dir="/tmp/pwnagotchi_logs_$(id -u)"
    local probe_file=""

    mkdir -p "$shared_dir" 2>/dev/null || true
    probe_file="$shared_dir/.write-test-$$"
    if touch "$probe_file" >/dev/null 2>&1; then
        rm -f "$probe_file"
        echo "$shared_dir"
        return 0
    fi

    mkdir -p "$fallback_dir"
    echo "$fallback_dir"
}

LOCK_DIR="/tmp/pwnagotchi_singleton.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

LOG_DIR="$(resolve_log_dir)"
LOG_FILE="$LOG_DIR/pwnagotchi_$(date +%Y%m%d_%H%M%S).log"

{
    echo "[launcher] fbdev=$PWNAGOTCHI_FBDEV keyboard=$PWNAGOTCHI_KEYBOARD_DEVICE"
    /usr/share/APPLaunch/bin/pwnagotchi_app &
    APP_PID=$!
    term_child() {
        kill -TERM "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    }
    trap term_child INT TERM
    wait "$APP_PID"
} >>"$LOG_FILE" 2>&1
EOF
chmod 0755 "$PKG_ROOT/usr/share/APPLaunch/bin/pwnagotchi_launcher"

cat > "$PKG_ROOT/usr/share/APPLaunch/applications/pwnagotchi.desktop" <<'EOF'
[Desktop Entry]
Name=Pwnagotchi
Exec=/usr/share/APPLaunch/bin/pwnagotchi_launcher
Icon=share/images/pwnagotchi.png
Terminal=false
Sysplause=false
Type=Application
EOF

cat > "$PKG_ROOT/DEBIAN/control" <<'EOF'
Package: pwnagotchi-applaunch
Version: 0.1-m5stack1
Architecture: arm64
Maintainer: M5Stack <m5stack@m5stack.com>
Section: APPLaunch
Priority: optional
Description: Pwnagotchi APPLaunch entry for CardputerZero
EOF

(
    cd "$PKG_ROOT/DEBIAN"
    COPYFILE_DISABLE=1 tar -czf "$BUILD_DIR/control.tar.gz" .
)
(
    cd "$PKG_ROOT"
    COPYFILE_DISABLE=1 tar --exclude ./DEBIAN -czf "$BUILD_DIR/data.tar.gz" .
)
printf '2.0\n' > "$BUILD_DIR/debian-binary"
(
    cd "$BUILD_DIR"
    ar -r "$OUT_DEB" debian-binary control.tar.gz data.tar.gz >/dev/null
    rm -f debian-binary control.tar.gz data.tar.gz
)

echo "$OUT_DEB"
