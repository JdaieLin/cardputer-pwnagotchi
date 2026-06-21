#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE="${REMOTE:-pi@192.168.100.199}"
REMOTE_DIR="${REMOTE_DIR:-/home/pi/cardputer-pwnagotchi}"
PACKAGE_GLOB="${PACKAGE_GLOB:-cardputerzero-pwnagotchi_*_arm64.deb}"
REMOTE_TMP="${REMOTE_TMP:-/tmp/cardputerzero-pwnagotchi_arm64.deb}"
PWN_ARCHIVE_LOCAL="${PWN_ARCHIVE_LOCAL:-$ROOT_DIR/build/pwnagotchi-master.tar.gz}"
PWN_ARCHIVE_REMOTE="${PWN_ARCHIVE_REMOTE:-/tmp/pwnagotchi-master.tar.gz}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SUDO_PASSWORD="${SUDO_PASSWORD:-$SSH_PASSWORD}"

if [[ -n "$SSH_PASSWORD" ]]; then
  SSH_CMD=(sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no)
  SCP_CMD=(sshpass -p "$SSH_PASSWORD" scp -o StrictHostKeyChecking=no)
else
  SSH_CMD=(ssh)
  SCP_CMD=(scp)
fi

# ── Upload & install dependencies ────────────────────────────────
"${SSH_CMD[@]}" "$REMOTE" "mkdir -p /tmp/pwnagotchi_logs"
"${SSH_CMD[@]}" "$REMOTE" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'"
"${SCP_CMD[@]}" "$ROOT_DIR/build.sh" "$REMOTE:$REMOTE_DIR/"
"${SCP_CMD[@]}" -r "$ROOT_DIR/tools" "$REMOTE:$REMOTE_DIR/"
"${SCP_CMD[@]}" -r "$ROOT_DIR/main" "$REMOTE:$REMOTE_DIR/"
"${SCP_CMD[@]}" "$ROOT_DIR/SConstruct" "$REMOTE:$REMOTE_DIR/"
"${SCP_CMD[@]}" "$ROOT_DIR/config_defaults.mk" "$REMOTE:$REMOTE_DIR/"
"${SCP_CMD[@]}" "$ROOT_DIR/app-builder.json" "$REMOTE:$REMOTE_DIR/"
"${SCP_CMD[@]}" "$ROOT_DIR/.env.template" "$REMOTE:$REMOTE_DIR/"
if [[ -f "$PWN_ARCHIVE_LOCAL" ]]; then
"${SCP_CMD[@]}" "$PWN_ARCHIVE_LOCAL" "$REMOTE:$PWN_ARCHIVE_REMOTE"
fi

# Run install.sh on remote to set up system deps, Python pkgs, fonts
"${SSH_CMD[@]}" "$REMOTE" "printf '%s\n' '$SUDO_PASSWORD' | sudo -S PWNAGOTCHI_ARCHIVE_PATH='$PWN_ARCHIVE_REMOTE' '$REMOTE_DIR/tools/install.sh'"

# ── Build .deb on device ─────────────────────────────────────────
"${SSH_CMD[@]}" "$REMOTE" "cd '$REMOTE_DIR' && chmod +x build.sh tools/package_applaunch.sh && ./build.sh --device --package"

# ── Fetch .deb back and install ──────────────────────────────────
"${SSH_CMD[@]}" "$REMOTE" "cd '$REMOTE_DIR/build' && ls -1 $PACKAGE_GLOB | head -n 1 > /tmp/cardputer-pwnagotchi-deb-name"
DEB_NAME="$("${SSH_CMD[@]}" "$REMOTE" "cat /tmp/cardputer-pwnagotchi-deb-name")"
"${SCP_CMD[@]}" "$REMOTE:$REMOTE_DIR/build/$DEB_NAME" "$ROOT_DIR/build/"
"${SSH_CMD[@]}" "$REMOTE" "cp '$REMOTE_DIR/build/$DEB_NAME' '$REMOTE_TMP' && printf '%s\n' '$SUDO_PASSWORD' | sudo -S dpkg -i '$REMOTE_TMP' && printf '%s\n' '$SUDO_PASSWORD' | sudo -S systemctl restart APPLaunch.service"
"${SSH_CMD[@]}" "$REMOTE" "dpkg -s cardputerzero-pwnagotchi | sed -n '1,8p' && systemctl is-active APPLaunch.service"
