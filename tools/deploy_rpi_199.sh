#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE="${REMOTE:-pi@192.168.100.199}"
REMOTE_DIR="${REMOTE_DIR:-/home/pi/cardputer-pwnagotchi}"
PACKAGE_GLOB="${PACKAGE_GLOB:-cardputerzero-pwnagotchi_*_arm64.deb}"
REMOTE_TMP="${REMOTE_TMP:-/tmp/cardputerzero-pwnagotchi_arm64.deb}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SUDO_PASSWORD="${SUDO_PASSWORD:-$SSH_PASSWORD}"

if [[ -n "$SSH_PASSWORD" ]]; then
  SSH_CMD=(sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no)
  SCP_CMD=(sshpass -p "$SSH_PASSWORD" scp -o StrictHostKeyChecking=no)
else
  SSH_CMD=(ssh)
  SCP_CMD=(scp)
fi

# ── Upload package sources ───────────────────────────────────────
"${SSH_CMD[@]}" "$REMOTE" "mkdir -p /tmp/pwnagotchi_logs"
"${SSH_CMD[@]}" "$REMOTE" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'"
"${SCP_CMD[@]}" "$ROOT_DIR/build.sh" "$REMOTE:$REMOTE_DIR/"
"${SCP_CMD[@]}" -r "$ROOT_DIR/tools" "$REMOTE:$REMOTE_DIR/"
"${SCP_CMD[@]}" -r "$ROOT_DIR/main" "$REMOTE:$REMOTE_DIR/"
"${SCP_CMD[@]}" "$ROOT_DIR/SConstruct" "$REMOTE:$REMOTE_DIR/"
"${SCP_CMD[@]}" "$ROOT_DIR/config_defaults.mk" "$REMOTE:$REMOTE_DIR/"
"${SCP_CMD[@]}" "$ROOT_DIR/app-builder.json" "$REMOTE:$REMOTE_DIR/"
"${SCP_CMD[@]}" "$ROOT_DIR/.env.template" "$REMOTE:$REMOTE_DIR/"

# ── Build .deb on device ─────────────────────────────────────────
"${SSH_CMD[@]}" "$REMOTE" "cd '$REMOTE_DIR' && chmod +x build.sh tools/package_applaunch.sh && ./build.sh --device --package"

# ── Fetch .deb back and install ──────────────────────────────────
"${SSH_CMD[@]}" "$REMOTE" "cd '$REMOTE_DIR/build' && ls -1 $PACKAGE_GLOB | head -n 1 > /tmp/cardputer-pwnagotchi-deb-name"
DEB_NAME="$("${SSH_CMD[@]}" "$REMOTE" "cat /tmp/cardputer-pwnagotchi-deb-name")"
"${SCP_CMD[@]}" "$REMOTE:$REMOTE_DIR/build/$DEB_NAME" "$ROOT_DIR/build/"
"${SSH_CMD[@]}" "$REMOTE" "cp '$REMOTE_DIR/build/$DEB_NAME' '$REMOTE_TMP' && printf '%s\n' '$SUDO_PASSWORD' | sudo -S dpkg -i '$REMOTE_TMP'"
"${SSH_CMD[@]}" "$REMOTE" "dpkg -s cardputerzero-pwnagotchi | sed -n '1,8p' && systemctl is-active APPLaunch.service"
