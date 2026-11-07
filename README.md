# onexplayer-webcam-flip

The built-in Toshiba webcam on the OneXPlayer Super X is physically mounted
upside-down. This presents a correctly flipped "Camera" to all apps through a
v4l2loopback virtual device, and — unlike the usual always-on ffmpeg bridge —
**powers the real camera only while an app is actually watching**, so the
camera LED stays off when idle.

Written and tested on a OneXPlayer Super X running Fedora. Other devices with
an upside-down UVC camera may work after adjusting the source camera
detection and the WirePlumber hide rule (see *Configuration* and
`wireplumber/51-webcam-flip.conf`).

## How it works

```
                ┌──────────────────────────── systemd --user ───────────────────────┐
                │                                                                  │
  apps ──► "Camera" (/dev/video10, v4l2loopback) ◄── keeper OR real ffmpeg writer  │
                │                                                      ▲          │
                │                                    monitor loop (bash + fuser)   │
```

- **Monitor loop** (`webcam-flip`): polls `fuser /dev/video10` every 0.5 s.
  Every consumer — PipeWire clients (browsers, portal apps) and direct V4L2
  apps alike — must hold the device open, so this detects both; when idle
  only our own writer holds it. (PipeWire link/node state can't see direct
  V4L2 apps, which is why pw-link-based approaches fail.)
- **Keeper** (`webcam-flip-keeper`, ~100 lines of C): while idle, writes
  black frames into the loopback. This is required: v4l2loopback fails
  capture `VIDIOC_STREAMON` with `EIO` when no writer is streaming, so apps
  cannot even open the camera without it. Its `write()` blocks when the
  buffer queue is full, so it costs ~0 CPU while nobody is reading.
- **Real writer**: on a consumer, the script swaps keeper → an ffmpeg
  pipeline reading the Toshiba camera with `hflip,vflip`. After the last
  consumer leaves (2 s), it swaps back and the camera powers off.

The original Toshiba nodes are hidden from app camera menus by a WirePlumber
rule, so apps only see the flipped "Camera". Other cameras (e.g. a plugged-in
USB webcam) are unaffected and remain visible.

## Requirements

- Any distro running **PipeWire + WirePlumber** (the default on Fedora,
  Ubuntu, Debian, Arch, openSUSE) and **systemd**. Verified on Fedora.
  On distros without PipeWire the flip and on-demand logic still work
  (direct V4L2 apps are detected too), but the original upside-down
  camera cannot be hidden from app menus — apps would list both cameras.
  Without systemd, run `~/.local/bin/webcam-flip` under any supervisor.
- v4l2loopback kernel module installed (`kmod-v4l2loopback` or a DKMS
  build; on Secure Boot enroll a MOK key so the module's signature is
  accepted). It is loaded at boot by a root-level
  `webcam-flip-module.service` unit — installed and enabled by
  `install.sh` (it prompts for sudo). The unit passes the module options
  on the `modprobe` command line because the Fedora v4l2loopback package
  ships `/usr/lib/modprobe.d/98-v4l2loopback.conf` ("OBS Virtual Camera",
  `exclusive_caps=1`, no `video_nr`), and a plain `modprobe v4l2loopback`
  has been observed to merge only those package options — creating no
  usable device. Options on the command line always win.
- User-level tools: `ffmpeg`, `v4l2-ctl` (v4l2-utils), `fuser` (psmisc),
  `gcc`, `systemctl`, `jq`

## Installation

```bash
git clone https://github.com/the-reengineers/onexplayer-webcam-flip.git
cd onexplayer-webcam-flip
./install.sh
```

`install.sh` checks dependencies and hardware, installs the root-level
module-load unit (sudo prompt), compiles the keeper, installs everything
under `~/.local` and `~/.config`, enables the user service, and verifies
the advertised camera format (`YUY2 1280x720`). It never overwrites an
existing `~/.config/webcam-flip.conf`.

Verify:

```bash
systemctl --user status webcam-flip.service
pw-dump | jq '.[] | select(.info.props["node.name"] // "" | test("video10"))
                | .info.params.EnumFormat[0]'
```

Then open an app (e.g. Snapshot) — the camera LED should only light up while
the app is actually watching, and the video should be right-side up.

## Manual installation

If you prefer to place files yourself:

```bash
# 1. Module-load unit (root, for boot persistence — see Requirements)
sudo install -Dm644 systemd/webcam-flip-module.service \
  /etc/systemd/system/webcam-flip-module.service
sudo systemctl daemon-reload
sudo systemctl enable --now webcam-flip-module.service

# 2. Install the scripts
install -Dm755 webcam-flip ~/.local/bin/webcam-flip
install -Dm644 src/webcam-flip-keeper.c ~/.local/bin/webcam-flip-keeper.c
gcc -O2 -o ~/.local/bin/webcam-flip-keeper ~/.local/bin/webcam-flip-keeper.c

# 3. Configuration (optional — defaults are the Super X values)
install -Dm644 webcam-flip.conf ~/.config/webcam-flip.conf

# 4. Service and WirePlumber rule
install -Dm644 systemd/webcam-flip.service ~/.config/systemd/user/webcam-flip.service
install -Dm644 wireplumber/51-webcam-flip.conf \
  ~/.config/wireplumber/wireplumber.conf.d/51-webcam-flip.conf

# 5. Enable
systemctl --user daemon-reload
systemctl --user enable --now webcam-flip.service
```

## Configuration

All tunables live in `~/.config/webcam-flip.conf` (bash-syntax, sourced by
the script; every default is commented out in the installed file): source
device, loopback node, resolution, idle framerate, poll interval, stop delay,
and the camera-reopen retry parameters (the Super X's camera returns `EBUSY`
for a few seconds after a previous writer closed it — the script retries).

The idle frame format is fixed to YUYV, the built-in camera's native format.

## Performance

Measured on a Super X (Ryzen, 1280×720 YUYV):

| State | CPU | Memory |
|---|---|---|
| Idle (monitor + keeper) | **< 0.5 %** total (monitor ~0.3 %, keeper ~0.15 %) | ~6 MB |
| Idle, being probed/negotiated | unchanged (keeper self-paces via blocking writes) | ~6 MB |
| Camera in use (flip ffmpeg) | ~6–8 % (camera capture + hflip/vflip + YUYV copy) | ~130 MB |

Other behaviour, as tested:

- A consumer connecting sees ~2–4 s of black frames before live video —
  the keeper→camera writer swap plus camera power-on.
- The camera powers off `STOP_DELAY` (default 2 s) after the last consumer
  leaves; the LED goes out.
- A consumer that opens while the service is stopped fails (as expected —
  that's "camera off"). An already-running stream survives writer swaps.

## Troubleshooting

- **"Could not play camera stream" (Snapshot) / black or 640×480 video**:
  WirePlumber probed the loopback while no writer was streaming and cached
  v4l2loopback's uninitialised 2×1 format. The script restarts WirePlumber
  *after* starting the keeper for exactly this reason — if it reappears,
  `systemctl --user restart webcam-flip` (which re-does the ordered restart).
- **Camera not found after reboot / `/dev/video10` missing**: the module
  wasn't loaded (or was loaded with only the package's OBS options, which
  create no device). Check `systemctl status webcam-flip-module.service`
  and `journalctl -u webcam-flip-module -b`. If it's not enabled, re-run
  `install.sh` (or the manual-install step 1). The module unit is
  self-healing: `systemctl start webcam-flip-module.service` reloads the
  module with the right options, and the user service then recovers on
  its own within a few restarts.
- **Camera not found after replug / renumbering**: the script re-detects the
  Toshiba by card name on every start; only the loopback node (`/dev/video10`)
  must stay fixed, which the module config pins via `video_nr=10`.

## Uninstall

```bash
./uninstall.sh
```

Stops the service, removes all installed files, and restores the original
(upside-down) camera in app menus. The v4l2loopback module is left alone.

## License

GPL-3.0-only — see [LICENSE](LICENSE). Each file carries an
`SPDX-License-Identifier: GPL-3.0-only` header.
