#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_BUILDER_JSON="$ROOT_DIR/app-builder.json"
ICON_SRC="${PWNAGOTCHI_ICON_SRC:-$ROOT_DIR/tools/assets/pwnagotchi.png}"
MAINTAINER_NAME="${PWNAGOTCHI_MAINTAINER_NAME:-JdaieLin}"
MAINTAINER_EMAIL="${PWNAGOTCHI_MAINTAINER_EMAIL:-hongruilin@alum.calarts.edu}"
HOMEPAGE_URL="${PWNAGOTCHI_HOMEPAGE_URL:-https://github.com/JdaieLin/cardputer-pwnagotchi}"
PWN_ARCHIVE_LOCAL="${PWNAGOTCHI_ARCHIVE_LOCAL:-$BUILD_DIR/pwnagotchi-master.tar.gz}"

GTAR_BIN="${GTAR:-}"
if [[ -z "$GTAR_BIN" ]]; then
    if command -v gtar >/dev/null 2>&1; then
        GTAR_BIN="$(command -v gtar)"
    elif command -v tar >/dev/null 2>&1 && tar --version 2>/dev/null | grep -q 'GNU tar'; then
        GTAR_BIN="$(command -v tar)"
    elif [[ -x /opt/homebrew/bin/gtar ]]; then
        GTAR_BIN="/opt/homebrew/bin/gtar"
    else
        echo "GNU tar is required for APPLaunch store-compatible packages. Install it with: brew install gnu-tar" >&2
        exit 1
    fi
fi

make_ustar_gz() {
    local src_dir="$1"
    local out_tar_gz="$2"
    shift 2
    (
        cd "$src_dir"
        COPYFILE_DISABLE=1 "$GTAR_BIN" \
            --format=ustar \
            --owner=0 --group=0 --numeric-owner \
            --sort=name \
            --mtime='UTC 2026-01-01' \
            -czf "$out_tar_gz" "$@"
    )
}

json_value() {
    local expr="$1"
    python3 - "$APP_BUILDER_JSON" "$expr" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
expr = sys.argv[2]
data = json.loads(config_path.read_text())
value = data
for key in expr.split("."):
    value = value[key]
print(value)
PY
}

PACKAGE_NAME="${PWNAGOTCHI_PACKAGE_NAME:-$(json_value package_name)}"
VERSION="${PWNAGOTCHI_VERSION:-$(json_value version)}"
REVISION="${PWNAGOTCHI_REVISION:-$(json_value revision)}"
APP_NAME="$(json_value app_name)"
BIN_NAME="$(json_value bin_name)"
DESCRIPTION="$(json_value description)"

if [[ -n "${PWNAGOTCHI_VERSION:-}" ]]; then
    echo "[package] using version override from environment: $VERSION"
fi

BIN="$BUILD_DIR/$BIN_NAME"
PKG_ROOT="$BUILD_DIR/${PACKAGE_NAME}-package"
OUT_DEB="$BUILD_DIR/${PACKAGE_NAME}_${VERSION}-${REVISION}_arm64.deb"

if [[ ! -x "$BIN" ]]; then
    echo "missing binary: $BIN"
    echo "run ./build.sh --device first"
    exit 1
fi
if [[ ! -f "$ICON_SRC" ]]; then
    echo "missing icon: $ICON_SRC"
    exit 1
fi

rm -rf "$PKG_ROOT" "$OUT_DEB"
mkdir -p \
    "$PKG_ROOT/DEBIAN" \
    "$PKG_ROOT/usr/share/APPLaunch/applications" \
    "$PKG_ROOT/usr/share/APPLaunch/bin" \
    "$PKG_ROOT/usr/share/APPLaunch/share/images" \
    "$PKG_ROOT/usr/share/APPLaunch/share/pwnagotchi"

install -m 0755 "$BIN" "$PKG_ROOT/usr/share/APPLaunch/bin/$BIN_NAME"
install -m 0644 "$ROOT_DIR/main/tools/pwnagotchi_bridge.py" "$PKG_ROOT/usr/share/APPLaunch/share/pwnagotchi/pwnagotchi_bridge.py"
install -m 0644 "$ROOT_DIR/main/tools/display_bridge.py" "$PKG_ROOT/usr/share/APPLaunch/share/pwnagotchi/display_bridge.py"
install -m 0755 "$ROOT_DIR/tools/install.sh" "$PKG_ROOT/usr/share/APPLaunch/share/pwnagotchi/install.sh"
install -m 0755 "$ROOT_DIR/tools/bootstrap_pwnagotchi.sh" "$PKG_ROOT/usr/share/APPLaunch/share/pwnagotchi/bootstrap_pwnagotchi.sh"
install -m 0644 "$ICON_SRC" "$PKG_ROOT/usr/share/APPLaunch/share/images/pwnagotchi.png"

if [[ -f "$PWN_ARCHIVE_LOCAL" ]]; then
    install -m 0644 "$PWN_ARCHIVE_LOCAL" "$PKG_ROOT/usr/share/APPLaunch/share/pwnagotchi/pwnagotchi-master.tar.gz"
    echo "[package] bundled pwnagotchi archive: $PWN_ARCHIVE_LOCAL"
else
    echo "[package] warning: no pwnagotchi archive at $PWN_ARCHIVE_LOCAL; installer will fall back to git clone"
fi

# Bundle display fonts so the app does not need a separate font setup step.
FONT_DST="$PKG_ROOT/usr/share/APPLaunch/share/pwnagotchi/fonts"
mkdir -p "$FONT_DST"
copy_first_font() {
    local dst_name="$1"
    shift
    for src in "$@"; do
        if [[ -f "$src" ]]; then
            install -m 0644 "$src" "$FONT_DST/$dst_name"
            echo "[package] bundled font: $dst_name <= $src"
            return 0
        fi
    done
    echo "[package] missing optional font: $dst_name"
    return 0
}

copy_first_font "NotoSansSC-Bold.ttf" \
    "$ROOT_DIR/tools/fonts/NotoSansSC-Bold.ttf" \
    "$ROOT_DIR/tools/fonts/NotoSansSC-Regular.ttf" \
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc" \
    "/usr/share/fonts/opentype/noto/NotoSansCJKSC-Regular.otf" \
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc" \
    "/usr/share/fonts/truetype/noto/NotoSansSC-Regular.ttf" \
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

copy_first_font "NotoColorEmoji.ttf" \
    "$ROOT_DIR/tools/fonts/NotoColorEmoji.ttf" \
    "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf" \
    "/usr/share/fonts/opentype/noto/NotoColorEmoji.ttf"

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
export PWNAGOTCHI_HANDSHAKES_DIR=/home/pi/handshakes
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

cat > "$PKG_ROOT/usr/share/APPLaunch/applications/pwnagotchi.desktop" <<EOF
[Desktop Entry]
Name=$APP_NAME
Exec=/usr/share/APPLaunch/bin/pwnagotchi_launcher
Icon=share/images/pwnagotchi.png
Terminal=false
Sysplause=false
Type=Application
EOF

cat > "$PKG_ROOT/DEBIAN/control" <<EOF
Package: $PACKAGE_NAME
Version: $VERSION-$REVISION
Architecture: arm64
Maintainer: $MAINTAINER_NAME <$MAINTAINER_EMAIL>
Section: APPLaunch
Priority: optional
Homepage: $HOMEPAGE_URL
Depends: sudo, python3, python3-pip, python3-pil, curl, git, fonts-noto-cjk, fonts-noto-color-emoji, binutils, iw, wireless-tools, rfkill, bettercap, bettercap-caplets, iptables
Replaces: pwnagotchi-applaunch
Breaks: pwnagotchi-applaunch
Description: $DESCRIPTION for M5Cardputer Zero
 Requires a monitor-mode capable external USB Wi-Fi adapter; the CM0 onboard
 Wi-Fi does not support monitor mode for Pwnagotchi capture.
EOF

cat > "$PKG_ROOT/DEBIAN/postinst" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

INSTALLER="/usr/share/APPLaunch/share/pwnagotchi/install.sh"
ARCHIVE="/usr/share/APPLaunch/share/pwnagotchi/pwnagotchi-master.tar.gz"
if [[ -x "$INSTALLER" ]]; then
    if [[ -f "$ARCHIVE" ]]; then
        PWNAGOTCHI_INSTALL_SKIP_APT=1 PWNAGOTCHI_ARCHIVE_PATH="$ARCHIVE" "$INSTALLER"
    else
        PWNAGOTCHI_INSTALL_SKIP_APT=1 "$INSTALLER"
    fi
fi
EOF
chmod 0755 "$PKG_ROOT/DEBIAN/postinst"

make_ustar_gz "$PKG_ROOT/DEBIAN" "$BUILD_DIR/control.tar.gz" .
make_ustar_gz "$PKG_ROOT" "$BUILD_DIR/data.tar.gz" --exclude ./DEBIAN .
printf '2.0\n' > "$BUILD_DIR/debian-binary"
(
    cd "$BUILD_DIR"
    ar -r "$OUT_DEB" debian-binary control.tar.gz data.tar.gz >/dev/null
    rm -f debian-binary control.tar.gz data.tar.gz
)

echo "$OUT_DEB"
