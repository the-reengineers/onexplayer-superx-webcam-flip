#!/usr/bin/env bash
# install.sh — SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 onexplayer-webcam-flip contributors
#
# Installs webcam-flip for the current user:
#   ~/.local/bin/webcam-flip               monitor script (this service's ExecStart)
#   ~/.local/bin/webcam-flip-keeper{,.c}   idle writer + source
#   ~/.config/webcam-flip.conf             user config (created only if absent)
#   ~/.config/systemd/user/webcam-flip.service
#   ~/.config/wireplumber/wireplumber.conf.d/51-webcam-flip.conf
#
# Everything runs as the user — no root needed. The v4l2loopback module
# itself must already be loaded (see README for the one-time module setup).
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
BIN_DIR="$HOME/.local/bin"
CONF_DIR="$HOME/.config"
SERVICE_DIR="$CONF_DIR/systemd/user"
WP_CONF_DIR="$CONF_DIR/wireplumber/wireplumber.conf.d"

die() { echo "Error: $*" >&2; exit 1; }

# --- dependency checks ------------------------------------------------------
for cmd in ffmpeg v4l2-ctl fuser gcc systemctl jq; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing dependency: $cmd"
done
[ -d "$REPO_DIR/systemd" ] || die "run from the repo root (repo layout incomplete)"

# --- hardware checks --------------------------------------------------------
[ -e /dev/video10 ] || die "/dev/video10 (v4l2loopback) not found — load the module first (see README)"

CAM=""
for dev in /dev/video*; do
    [ "$dev" = "/dev/video10" ] && continue
    if v4l2-ctl -d "$dev" --info 2>/dev/null | grep -q "TOSHIBA" && \
       v4l2-ctl -d "$dev" --list-formats-ext 2>/dev/null | grep -q "1280x720"; then
        CAM="$dev"
        break
    fi
done
[ -n "$CAM" ] || echo "Warning: no Toshiba 1280x720 camera found; the service will retry detection at start" >&2

# --- install ----------------------------------------------------------------
echo "Installing to $BIN_DIR and $CONF_DIR ..."
install -Dm755 "$REPO_DIR/webcam-flip" "$BIN_DIR/webcam-flip"
install -Dm644 "$REPO_DIR/src/webcam-flip-keeper.c" "$BIN_DIR/webcam-flip-keeper.c"
gcc -O2 -Wall -o "$BIN_DIR/webcam-flip-keeper" "$BIN_DIR/webcam-flip-keeper.c" || die "failed to compile webcam-flip-keeper"

# User config: never overwrite an existing one
if [ ! -f "$CONF_DIR/webcam-flip.conf" ]; then
    install -Dm644 "$REPO_DIR/webcam-flip.conf" "$CONF_DIR/webcam-flip.conf"
    echo "Created $CONF_DIR/webcam-flip.conf (defaults, everything commented)"
else
    echo "Keeping existing $CONF_DIR/webcam-flip.conf"
fi

install -Dm644 "$REPO_DIR/systemd/webcam-flip.service" "$SERVICE_DIR/webcam-flip.service"
install -Dm644 "$REPO_DIR/wireplumber/51-webcam-flip.conf" "$WP_CONF_DIR/51-webcam-flip.conf"

# --- enable -----------------------------------------------------------------
systemctl --user daemon-reload
systemctl --user enable --now webcam-flip.service
sleep 6

# --- verify -----------------------------------------------------------------
echo
echo "Service status:"
systemctl --user is-active webcam-flip.service || true

echo "Advertised camera format (expect YUY2 1280x720):"
pw-dump 2>/dev/null | jq -r '.[] | select(.type=="PipeWire:Interface:Node")
    | select((.info.props["node.name"] // "") | test("video10"))
    | .info.params.EnumFormat[0]
    | "  \(.format) \(.size.width)x\(.size.height)@\(.framerate.num)/\(.framerate.denom)"' || true

echo
echo "Recent log:"
journalctl --user -u webcam-flip.service --since "-30s" --no-pager -o cat | tail -5

echo
echo "Done. Apps should now list a 'Camera' (flipped, on-demand)."
echo "Open e.g. Snapshot to verify — the camera LED should only light"
echo "while an app is actually watching."
