#!/usr/bin/env bash
# install.sh — SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 onexplayer-superx-webcam-flip contributors
#
# Installs webcam-flip:
#
#   Root (sudo, will be prompted):
#     /etc/systemd/system/webcam-flip-module.service
#         one-shot unit that loads v4l2loopback with the right options
#         at boot (the Fedora package's OBS modprobe.d override otherwise
#         poisons a plain `modprobe v4l2loopback`)
#
#   User:
#     ~/.local/bin/webcam-flip               monitor script (service ExecStart)
#     ~/.local/bin/webcam-flip-keeper{,.c}   idle writer + source
#     ~/.config/webcam-flip.conf             user config (created only if absent)
#     ~/.config/systemd/user/webcam-flip.service
#     ~/.config/wireplumber/wireplumber.conf.d/51-webcam-flip.conf
#
# The v4l2loopback kernel module itself must be installed (kmod-v4l2loopback
# or a DKMS build; see README for the Secure Boot MOK note). Loading it is
# handled by the root unit above.
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
command -v sudo >/dev/null 2>&1 || die "missing dependency: sudo (needed for the module-load unit)"
[ -d "$REPO_DIR/systemd" ] || die "run from the repo root (repo layout incomplete)"
modinfo v4l2loopback >/dev/null 2>&1 || die "v4l2loopback kernel module not installed"

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

# --- root-level: module load unit -------------------------------------------
echo "Installing module-load unit (sudo) ..."
sudo install -Dm644 "$REPO_DIR/systemd/webcam-flip-module.service" \
    /etc/systemd/system/webcam-flip-module.service
sudo systemctl daemon-reload
sudo systemctl enable --now webcam-flip-module.service
# Stale file from older instructions: loads the module WITHOUT options and
# races the unit above
sudo rm -f /etc/modules-load.d/v4l2loopback.conf

# --- user-level --------------------------------------------------------------
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
echo "Module-load unit: $(systemctl is-active webcam-flip-module.service || true)"
echo "Service status:   $(systemctl --user is-active webcam-flip.service || true)"
ls /dev/video10 >/dev/null 2>&1 || echo "Warning: /dev/video10 still missing — check: journalctl -u webcam-flip-module" >&2

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
echo "while an app is actually watching. Reboot once to confirm the"
echo "module unit loads /dev/video10 at boot."
