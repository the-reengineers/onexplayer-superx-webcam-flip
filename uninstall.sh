#!/usr/bin/env bash
# uninstall.sh — SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 onexplayer-superx-webcam-flip contributors
#
# Removes everything install.sh put in place and restores the original
# (upside-down) Toshiba camera in app menus. Does not touch the
# v4l2loopback module itself.
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
CONF_DIR="$HOME/.config"

sudo systemctl disable --now webcam-flip-module.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/webcam-flip-module.service
sudo systemctl daemon-reload

systemctl --user disable --now webcam-flip.service 2>/dev/null || true

rm -f "$BIN_DIR/webcam-flip" \
      "$BIN_DIR/webcam-flip-keeper" \
      "$BIN_DIR/webcam-flip-keeper.c" \
      "$CONF_DIR/systemd/user/webcam-flip.service" \
      "$CONF_DIR/wireplumber/wireplumber.conf.d/51-webcam-flip.conf"

# Keep the user config if it was modified; remove the untouched template
if [ -f "$CONF_DIR/webcam-flip.conf" ] && ! cmp -s "$CONF_DIR/webcam-flip.conf" /dev/null; then
    if grep -qE '^[A-Z_]+=' "$CONF_DIR/webcam-flip.conf"; then
        echo "Keeping modified $CONF_DIR/webcam-flip.conf"
    else
        rm -f "$CONF_DIR/webcam-flip.conf"
    fi
fi

systemctl --user daemon-reload
# Re-probe so the Toshiba nodes reappear in app camera menus
systemctl --user restart wireplumber 2>/dev/null || true

echo "Removed. The original Toshiba camera is back (upside-down)."
