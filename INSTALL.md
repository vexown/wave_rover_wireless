# wave_rover_wireless — Reproducible Install Guide

A clean, linear runbook to rebuild this digital video link from scratch on fresh
hardware. **Every step here has been verified working** unless tagged ⏳ (pending
verification). For the *why* behind these choices and the troubleshooting story,
see [`SETUP_LOG.md`](SETUP_LOG.md).

> **Link overview:** RTL8812EU radios in monitor mode inject raw 802.11 packets
> (no normal WiFi association). Camera on the robot → encode → wfb_tx → RF →
> wfb_rx → decode → screen on the ground station. The two ends just need the
> **same channel** + the **same key**.

---

## 0. Bill of materials

- 1× Raspberry Pi 4B — **air side** (on the robot), runs Ubuntu (for ROS2), kernel `6.8.0-1057-raspi` (arm64).
- 1× Raspberry Pi 5 — **ground station**, Raspberry Pi OS Bookworm 64-bit.
- 2× **BL-M8812EU2** USB modules (Realtek **RTL8812EU**, enumerate as `0bda:a81a`).
- 1× Raspberry Pi Camera Module 3 (on the air side).
- Per radio: a separate **5 V ≥3 A** supply, two 5.8 GHz antennas, heatsink + fan.

## 1. Build each radio (✅ verified)

The BL-M8812EU2 is a bare module — **power it from a separate 5 V supply, not the
Pi's USB port** (TX peaks ~2.5 A).

| Module pad | Connects to | Wire (from a cut USB-A cable) |
|---|---|---|
| `USB2.0+DP` (D+) | Pi USB **D+** | green — twisted pair, short |
| `USB2.0-DM` (D−) | Pi USB **D−** | white — twisted pair, short |
| `GND` | **Common ground**: Pi GND **and** PSU GND | black |
| `VDD5.0` | **+5 V from separate supply (≥3 A)** | thick (22–24 AWG) |

- Leave the USB cable's **red (Pi 5 V) disconnected** — module is externally powered.
- **Tie PSU ground to Pi ground** or USB won't enumerate. Pins 9–18 are GND (floatable).
- Add a **470–1000 µF bulk cap** across `VDD5.0`/`GND` at the module.
- ⚠️ **Antennas on J0/J1 BEFORE powering** (no-antenna TX can fry the PA). 🔥 Heatsink + fan.

**Verify:** `lsusb` shows `ID 0bda:a81a Realtek Semiconductor Corp. 802.11ac NIC`.

## 2. Air side — Raspberry Pi 4B (Ubuntu)

### 2.1 Install the RTL8812EU driver ✅ *(verified — RPi4B, kernel 6.8.0-1057-raspi)*

The driver is **vendored in this repo** at `third_party/rtl8812eu/` (tag
`v5.15.0.1`, already configured for arm64). No internet clone needed — build it
straight from the repo. See [`third_party/rtl8812eu/VENDOR.md`](third_party/rtl8812eu/VENDOR.md)
for provenance/license.

```bash
# Build prerequisites
sudo apt update
sudo apt install -y dkms build-essential bc linux-headers-$(uname -r)

# Build + install from the vendored copy (run from your checkout of this repo)
cd third_party/rtl8812eu
sudo ./dkms-install.sh

# Load it now (it also auto-loads on boot/plug afterwards via udev)
sudo modprobe 8812eu
```

**Verify:**

```bash
lsmod | grep 8812eu                                   # module loaded
ip -br link                                           # new wlxXXXXXXXXXXXX iface appears
IFACE=$(ls /sys/class/net | grep '^wlx')              # our card (Ubuntu MAC-based name)
sudo udevadm info /sys/class/net/$IFACE | grep ID_NET_DRIVER   # => rtl88x2eu
sudo ip link set $IFACE down && sudo iw dev $IFACE set type monitor && sudo ip link set $IFACE up
iw dev $IFACE info | grep type                        # => "type monitor"
```

Notes:
- On Ubuntu the card gets a **MAC-based name** (`wlxXXXXXXXXXXXX`), not `wlan1`.
  Don't hardcode it — wfb-ng autodetects the card by its driver (`rtl88x2eu`).
- The onboard `wlan0` (Broadcom, `brcmfmac`) is the SSH path on the RPi4B —
  leave it alone.
- A noisy dmesg backtrace during a scan (`phydm_*` / `rtw_acs_trigger`) is the
  driver reacting to NetworkManager surveying the card. Harmless; goes away once
  wfb-ng sets the card to monitor mode + NM-unmanaged.

### 2.2 Build + install wfb-ng (from this repo) ✅ *(verified — RPi4B, Ubuntu 24.04)*

Identical flow to the GS (§3.3); the build-dep package names are the same on
Ubuntu `noble` as on Pi OS `bookworm`. The build is **slower on the RPi4B**
(Cortex-A72) — just let it run.

```bash
sudo apt update
sudo apt install -y build-essential libpcap-dev libsodium-dev libevent-dev \
  libgstrtspserver-1.0-dev gstreamer1.0-plugins-base \
  python3-all python3-all-dev python3-pip python3-venv debhelper dh-python \
  fakeroot lsb-release python3-twisted python3-pyroute2 python3-msgpack \
  python3-jinja2 python3-yaml python3-serial python3-future

cd ~/wave_rover_wireless
make deb
sudo apt install -y ./deb_dist/wfb-ng_*_arm64.deb     # package tagged 0~noble
```

### 2.3 Configure + start the drone (air) profile ✅ *(verified — RPi4B)*

The key pair was generated once on the GS (§3.4). Copy the **`drone.key`** half
here (relay through a machine that can SSH both Pis):

```bash
# on a host with SSH to both:
scp rpi5-gs:/etc/drone.key /tmp/drone.key && scp /tmp/drone.key rpi4b:/tmp/drone.key
# on the RPi4B:
sudo install -o root -g root -m 644 /tmp/drone.key /etc/drone.key && rm /tmp/drone.key
# verify it's the EXACT matched key (one bit off = silent link):
sudo sha256sum /etc/drone.key      # must equal the GS's /etc/drone.key hash
```

`/etc/wifibroadcast.cfg` (drone) — RF settings **must match the GS** (§3.4);
differences are the `drone_video` input and that FEC is authoritative here:

```ini
[common]
wifi_channel = 165     # MUST MATCH the GS.
wifi_region = 'BO'     # MUST MATCH the GS.
wifi_txpower = 1000    # 10 dBm, low for bench. THIS one drives the video downlink.

[base]
bandwidth = 20         # MUST MATCH the GS.

[video]
fec_k = 8              # authoritative here (FEC is a TX-side setting)
fec_n = 12

[drone_video]
peer = 'listen://0.0.0.0:5602'   # camera/encoder pushes H.264 in here
```

```bash
# Enable BOTH units (umbrella + worker), drone profile:
sudo systemctl enable wifibroadcast.service
sudo systemctl enable wifibroadcast@drone
sudo systemctl start wifibroadcast@drone
sudo systemctl status wifibroadcast@drone        # => active (running), runs wfb_tx -u 5602
iw dev "$(ls /sys/class/net | grep '^wlx')" info  # => type monitor, channel 165, 10 dBm
```

### 2.4 Make the SD card power-cut-proof (read-only `/boot/firmware`) ✅ *(verified — survived a real battery-dead power cut)*

A robot gets its power **cut** (battery dies, kill switch) — not a clean
`poweroff`. The FAT **boot partition** (`/boot/firmware`, holds `config.txt`) has
**no journaling**, so a power cut mid-write scrambles its allocation table. This
bricked the RPi4B **twice** (corrupt/unreadable `config.txt` → solid green LED,
no boot; recovered each time by `fsck` on the card in a laptop).

The fix: mount `/boot/firmware` **read-only**. Nothing writes there at runtime
(`config.txt`, overlays and the kernel are static between deliberate updates), so
a power cut has nothing to tear. This *eliminates* that whole failure mode — it's
not "fewer writes," it's **zero** writes (no dirty bit, no FAT/FSINFO, no atime).

```bash
sudo cp /etc/fstab /etc/fstab.bak                              # backup
sudo sed -i '/\/boot\/firmware/ s/defaults/defaults,ro/' /etc/fstab
sudo findmnt --verify                                          # expect 0 errors
sudo systemctl daemon-reload
sudo mount -o remount,ro /boot/firmware                        # apply now
findmnt -no OPTIONS /boot/firmware | tr ',' '\n' | grep -x ro  # confirms: ro
```

**To edit `config.txt` later** (camera/kernel tweaks) unlock it briefly:

```bash
sudo mount -o remount,rw /boot/firmware
sudo nano /boot/firmware/config.txt
sudo mount -o remount,ro /boot/firmware
```

> Verified the hard way: the robot battery died mid-session (hard power cut) and
> the Pi **booted clean** — `/boot/firmware` still `ro`, `config.txt` intact, no
> fsck. The ext4 *root* is journaled so it self-recovers; for full power-cut
> immunity an **overlayroot** read-only root is the next-session upgrade. The GS
> benefits from the same `ro` boot trick if it's ever hard-cut.

## 3. Ground station — Raspberry Pi 5 (Raspberry Pi OS Bookworm 64-bit)

### 3.1 Flash the OS ✅ *(verified — RPi5)*

Use **Raspberry Pi Imager**: Device = Raspberry Pi 5, OS = **Raspberry Pi OS
(64-bit) Desktop** (Bookworm). Before writing, open ⚙️ "Edit Settings" and set:
**hostname**, **enable SSH**, **username/password**, your **home WiFi** (so you
can SSH in headless over the *onboard* WiFi — the BL-M8812EU2 stays free for
wfb-ng), and **locale**.

> ⚠️ Must be **64-bit (`aarch64`)**, not 32-bit. The vendored driver's Makefile
> targets arm64 (`CONFIG_PLATFORM_ARM64_RPI = y`); a 32-bit (armhf) kernel is
> the wrong platform. Keeping both Pis on arm64 also means **one identical
> driver build** on both ends.

Boot it, then verify from your machine and on the Pi:

```bash
ping <hostname>.local && ssh <user>@<hostname>.local   # from your machine
uname -m                                               # on the Pi => aarch64
cat /etc/os-release | grep PRETTY                      # => Debian 12 (bookworm)
```

### 3.2 Install the RTL8812EU driver ✅ *(verified — RPi5, kernel 6.12.75+rpt-rpi-2712)*

Same vendored driver as the air side — **identical build on arm64**. The only
OS difference from Ubuntu (§2.1) is the **kernel-headers package name**: on
Raspberry Pi OS it's `raspberrypi-kernel-headers`, not `linux-headers-$(uname -r)`.

```bash
# Clone this repo (HTTPS — no GitHub SSH key needed on a fresh Pi)
cd ~ && git clone https://github.com/vexown/wave_rover_wireless.git
cd wave_rover_wireless

# Build prerequisites (note the Pi-OS-specific headers package)
sudo apt update
sudo apt install -y git dkms build-essential bc raspberrypi-kernel-headers

# Confirm the headers match the running kernel (bites people on Bookworm)
ls -d /lib/modules/$(uname -r)/build      # must exist and resolve

# Build + install from the vendored copy, then load it
cd third_party/rtl8812eu
sudo ./dkms-install.sh
sudo modprobe 8812eu
```

**Verify:**

```bash
lsmod | grep 8812eu                                   # module loaded
ip -br link                                            # new wlan1 appears
sudo udevadm info /sys/class/net/wlan1 | grep ID_NET_DRIVER   # => rtl88x2eu
sudo ip link set wlan1 down && sudo iw dev wlan1 set type monitor && sudo ip link set wlan1 up
iw dev wlan1 info | grep type                         # => "type monitor"
```

Notes:
- On **Pi OS the card is named `wlan1`** (not `wlxXXXX` like Ubuntu in §2.1).
  Either way wfb-ng autodetects by driver (`rtl88x2eu`), so the name doesn't matter.
- The onboard `wlan0` (Broadcom) is the SSH path on the RPi5 — leave it alone.
- Bookworm now ships a **6.12** kernel; the vendored driver builds fine on it
  (the earlier worry about 6.12+ vs the out-of-tree driver didn't materialize).

> ⚠️ **Kernel updates and DKMS.** The driver is an out-of-tree module built for
> one exact kernel version. DKMS is supposed to rebuild it automatically when
> `apt` installs a new kernel — **but only if the matching kernel headers are
> present at that moment.** On Pi OS the kernel image and headers are separate
> packages and can drift, so after an `apt upgrade` you may boot a new kernel
> with **no driver** (symptom: `wlan1` gone, `modprobe 8812eu` →
> `Module ... not found in directory /lib/modules/<new-ver>`). Recovery:
>
> ```bash
> sudo apt install -y "linux-headers-$(uname -r)"   # headers for the RUNNING kernel
> sudo dkms autoinstall                              # rebuild the module for it
> sudo modprobe 8812eu
> ```
>
> `dkms status` should then list the module as `installed` for your current
> `uname -r`. **Do keep updating the Pis** — just make sure the headers track
> the kernel so DKMS can do its job unattended.

### 3.3 Build + install wfb-ng (from this repo) ✅ *(verified — RPi5)*

No `make install`; on Debian/Pi OS you build a `.deb` from this repo and
`apt install` it (keeps us self-contained — no external apt repo).

```bash
# Build dependencies
sudo apt update
sudo apt install -y build-essential libpcap-dev libsodium-dev libevent-dev \
  libgstrtspserver-1.0-dev gstreamer1.0-plugins-base \
  python3-all python3-all-dev python3-pip python3-venv debhelper dh-python \
  fakeroot lsb-release python3-twisted python3-pyroute2 python3-msgpack \
  python3-jinja2 python3-yaml python3-serial python3-future

# Build the .deb (compiles the C binaries, then packages via stdeb — needs internet)
cd ~/wave_rover_wireless
make deb

# Install it via apt (pulls runtime deps like socat). Ignore the harmless
# "Download is performed unsandboxed ... Permission denied" apt note.
sudo apt install -y ./deb_dist/wfb-ng_*_arm64.deb
```

> `python3-all-dev` is required — the generated Debian package build-depends on
> it (`dpkg-checkbuilddeps: error: unmet build dependencies: python3-all-dev`)
> and the build aborts without it.

The package drops `/etc/default/wifibroadcast` (NIC autodetect) and the
`wifibroadcast@.service` systemd unit, but **not** `/etc/wifibroadcast.cfg` —
you create that next.

### 3.4 Configure + start the ground station ✅ *(verified — RPi5)*

```bash
# 1. Generate the matched key pair ONCE (here on the GS).
#    Keep gs.key here; drone.key gets copied to the air side (§4).
cd /etc && sudo wfb_keygen        # writes /etc/gs.key + /etc/drone.key

# 2. Create /etc/wifibroadcast.cfg  (use `sudo nano` — heredoc paste over SSH
#    can hang on the shell's `>` continuation prompt).
```

`/etc/wifibroadcast.cfg` — we set the RF/FEC knobs **explicitly** (not relying on
master.cfg defaults) so they're visible and easy to tune later:

```ini
[common]
wifi_channel = 165     # 5825 MHz (5.8 GHz). Must MATCH the drone.
wifi_region = 'BO'     # CRDA region. Must MATCH the drone.
wifi_txpower = 1000    # 8812eu: dBm*100 -> 10 dBm (~10 mW). LOW for close-range
                       # bench testing; raise for range (e.g. 2000 = 20 dBm).
                       # NB: GS only TXes the uplink; the drone's txpower governs
                       # the video downlink. iw confirms this value (10 dBm).

[base]
bandwidth = 20         # channel width 20 or 40 MHz. Must MATCH the drone.

[video]
fec_k = 8              # data packets per FEC block
fec_n = 12             # total per block -> recovers up to 4 lost packets/block.
                       # NB: FEC is a TX-side setting; the RX takes FEC from the
                       # drone's session packet, so the DRONE copy is authoritative.

[gs_mavlink]
peer = 'connect://127.0.0.1:14550'

[gs_video]
peer = 'connect://127.0.0.1:5600'   # local video sink on the RPi5
```

`/etc/modprobe.d/wfb.conf`:

```ini
options cfg80211 ieee80211_regdom=RU
options 8812eu rtw_tx_pwr_by_rate=0 rtw_tx_pwr_lmt_enable=0
```

```bash
# 3. Enable + start the gs service (NIC is autodetected by driver -> wlan1).
#    wfb-ng uses TWO units: an umbrella `wifibroadcast.service` (WantedBy
#    multi-user.target -> starts at boot) and the worker `wifibroadcast@gs`
#    (WantedBy the umbrella). You must enable BOTH or it won't start on boot.
sudo systemctl enable wifibroadcast.service   # umbrella (boot -> pulls in @gs)
sudo systemctl enable wifibroadcast@gs        # worker profile
sudo systemctl restart wifibroadcast@gs
sudo systemctl status wifibroadcast@gs        # => active (running)
```

**Verify the radio is tuned to 5.8 GHz in monitor mode:**

```bash
iw dev wlan1 info        # => type monitor, channel 165 (5825 MHz)
wfb-cli gs               # live link dashboard (q to quit); counters 0 until the air side TXes
```

`active (running)` + `channel 165 (5825 MHz)` = the receive half of the link is
done. Counters stay at 0 until the RPi4B air side is transmitting (§4/§5).

**Confirm it survives a reboot** (a GS gets power-cycled, so this matters):

```bash
sudo reboot
# reconnect, then with NO manual steps:
iw dev wlan1 info        # should ALREADY be type monitor, channel 165, 10 dBm
```

If after reboot the card is in `type managed` instead, the service lost a boot
race against USB enumeration of `wlan1`. `Restart=on-failure` (5s) usually
self-heals it within seconds; if not, bind the umbrella to the interface by
uncommenting/adapting the `Requires=`/`After=sys-subsystem-net-devices-<iface>.device`
lines in `/lib/systemd/system/wifibroadcast.service`.

## 4. Pairing the link (keys + channel) ✅ *(verified)*

Already covered inline above, but the rules in one place:
- **Keys:** `wfb_keygen` **once** (we ran it on the GS, §3.4). `gs.key` stays on
  the GS, `drone.key` goes to the drone (§2.3). Both must be from the *same*
  generation — verify with matching `sha256sum`.
- **Channel/region/bandwidth:** `wifi_channel=165`, `wifi_region='BO'`,
  `bandwidth=20` must be **identical** on both ends or the radios can't talk.

**Verify the live link** — on the GS run `wfb-cli gs`: with the drone's service
up you should see the **gs tunnel** panel show an antenna line with a real
**RSSI** (e.g. −38 dBm) and packets moving + `dloss 0`. That confirms RF + key
pairing end to end (the `video` panel stays `[No data]` until §5 feeds it).

## 5. Video pipeline ✅ *(verified with a test pattern)*

End-to-end check using a GStreamer test pattern (no camera needed yet).

**Air side (RPi4B)** — push H.264/RTP into the drone's video input (port 5602):

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,width=640,height=480,framerate=30/1 \
  ! x264enc tune=zerolatency bitrate=2000 key-int-max=30 \
  ! rtph264pay config-interval=1 pt=96 ! udpsink host=127.0.0.1 port=5602
```

**Ground station (RPi5)** — decode + display what arrives on port 5600. Run on
the Pi's local screen; over SSH prefix with `DISPLAY=:0` (XWayland). **Keep it
one physical line** — terminals insert real newlines at wrap points and break
the `!` separators:

```bash
DISPLAY=:0 gst-launch-1.0 udpsrc port=5600 caps=application/x-rtp,media=video,encoding-name=H264,payload=96 ! rtph264depay ! avdec_h264 ! videoconvert ! autovideosink sync=false
```

Needs `gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav`
on the GS (`avdec_h264`). Result: the test pattern (SMPTE color bars) appears on
the GS screen. While it runs, `wfb-cli gs`'s **video** panel shows `recv` pkt/s
climbing and `Flow: ~2000 kbit/s`.

- If GS shows `could not open display` (Wayland blocking an SSH-launched window),
  use `WAYLAND_DISPLAY=wayland-0` + `waylandsink` instead of `DISPLAY=:0` +
  `autovideosink`, or run the pipeline from a terminal on the Pi's desktop.
- `x264enc` is software encode (fine for a test). The real camera step swaps
  `videotestsrc`/`x264enc` for the Camera Module 3 capture + (HW) encode.

## 6. Real Camera Module 3 over the link (air side) ✅ *(verified — live feed on the GS, smooth 720p30, crisp)*

Replaces the §5 test pattern with the actual IMX708 (Camera Module 3) capture.

### 6.1 Connect the camera to the CORRECT port

On the Pi 4B the **DSI (display)** and **CSI (camera)** connectors are identical,
unlabeled FFC sockets — trivially easy to swap (we did, and the kernel saw
nothing for it). The **CAMERA / CSI** port is the one **between the HDMI ports
and the 3.5 mm jack** (NOT the one by the GPIO header — that's DSI). Power off
first; on the Pi end the **silver contacts face the HDMI** side; seat fully, lock
the tab. Check both ends of the ribbon.

Confirm the **kernel** sees the sensor:

```bash
dmesg | grep -i imx708          # => "imx708 10-001a: camera module ID 0x0301"
ls /dev/v4l-subdev*             # subdev nodes now exist
media-ctl -d /dev/media4 -p | grep -i imx708   # a "unicam" media device lists imx708
```

No `imx708` in dmesg + no `unicam` media device = **wrong port or loose ribbon**
(not a software problem — don't go rebuilding libcamera until the kernel sees it).

### 6.2 Enable the sensor overlay (Ubuntu) ✅

On Ubuntu, `camera_auto_detect=1` is unreliable — load the sensor **explicitly**.
The boot partition is read-only (§2.4), so unlock it to edit:

```bash
sudo mount -o remount,rw /boot/firmware
sudo nano /boot/firmware/config.txt
```

Set (replacing `camera_auto_detect=1`):

```ini
camera_auto_detect=0
dtoverlay=imx708
```

Re-lock and reboot:

```bash
sudo mount -o remount,ro /boot/firmware
sudo reboot
```

### 6.3 libcamera + rpicam-apps (source build — required for IMX708 on Ubuntu) ✅

Ubuntu's distro libcamera (`0.2.0`) does **not** drive the IMX708. Build the
Raspberry Pi fork of **libcamera + rpicam-apps** from source — recipe in this
repo: [`Ubuntu_24_04_LTS_SetupCameraModule3.sh`](Ubuntu_24_04_LTS_SetupCameraModule3.sh).
It installs libcamera `0.5.x` to `/usr` and `rpicam-vid`/`rpicam-hello` to
`/usr/local/bin` (the `libcamera-*` names are kept as compat symlinks).

> ⚠️ The script's first line runs `apt full-upgrade`. A big upgrade followed by a
> power cut is exactly what corrupted this SD card — run the **build** steps but
> consider **skipping the `full-upgrade`** unless you specifically want it.

> ⚠️ **Fragility to know about:** this source libcamera lives in `/usr`
> *alongside* the apt libcamera `0.2.0`. An apt upgrade can overwrite the source
> IPA module `ipa_rpi_vc4.so` (the Pi 4's ISP) with the `0.2.0` one — then
> libcamera reports **"No cameras available!"** even though the *kernel* sees the
> sensor. **Fix:** reinstall the source libcamera (fast, no recompile if the
> build dir survives):
> ```bash
> sudo ninja -C ~/libcamera_build/libcamera/build install && sudo ldconfig
> ```
> That restores the matching, correctly-signed `0.5.x` IPA. (This is also how we
> recovered after the SD corruption wiped the `/usr/local/bin/rpicam-*` binaries:
> `meson compile -C ~/libcamera_build/rpicam-apps/build` then
> `sudo meson install -C build`.)

Verify libcamera enumerates the camera:

```bash
rpicam-hello --list-cameras     # => "0 : imx708 [4608x2592 10-bit] ..."
```

### 6.4 Free the camera from ROS (only one owner at a time) ✅

libcamera allows a **single** process to hold the camera. The robot's ROS2 stack
auto-starts `ros2_camera_feed.service`, which grabs it — so our pipeline fails
with *"Pipeline handler in use by another process / failed to acquire camera."*
For the FPV link, release it:

```bash
sudo systemctl disable --now ros2_camera_feed.service   # restore later: enable --now
```

> ⏳ **Open design choice:** the ROS camera feed and the FPV link both want the
> one camera. Pick one of: a **mode toggle** (run whichever you need), a **single
> capture that fans out** to both, or one **consuming the other's** stream.
> Decide before you rely on both at once.

### 6.5 Air-side capture script `~/cam.sh` ✅

Camera → H.264 (HW encode) → RTP → wfb drone input (UDP 5602). The camera is
mounted upside-down, hence `--rotation 180`. Source of truth:
[`fpv/cam.sh`](fpv/cam.sh) in this repo (copied to `~/cam.sh` on the RPi4B,
`chmod +x`).

```bash
#!/bin/bash
# Air-side FPV camera capture -> H.264 -> RTP -> wfb-ng drone video (UDP 5602).
set -e
WIDTH=1280; HEIGHT=720; FPS=30; BITRATE=4000000   # 4 Mbps; tune for the RF link

rpicam-vid -t 0 --nopreview --rotation 180 \
  --width "$WIDTH" --height "$HEIGHT" --framerate "$FPS" \
  --codec h264 --inline --intra "$FPS" --bitrate "$BITRATE" \
  -o - \
| gst-launch-1.0 -q -e fdsrc fd=0 \
  ! h264parse \
  ! rtph264pay config-interval=1 pt=96 \
  ! udpsink host=127.0.0.1 port=5602
```

(`--inline` + `--intra 30` + `config-interval=1` resend SPS/PPS + keyframes so the
GS can join/recover mid-stream within ~1 s.)

## 7. Daily use — fire up the link ✅

Everything auto-starts at boot **except** the camera capture and the GS viewer
(those are manual for now — see the auto-start ⏳ item).

1. **Power on both Pis.** wfb-ng starts at boot on both (`wifibroadcast@drone` on
   the robot, `wifibroadcast@gs` on the GS) — the RF link is up with no action.
2. **Ground station — start the viewer** on the RPi5 (renders to its attached
   screen). Source: [`fpv/play.sh`](fpv/play.sh) (copied to `~/play.sh`):
   ```bash
   ~/play.sh
   ```
3. **Robot — start the camera** (`ssh rpi4b`, then):
   ```bash
   ~/cam.sh
   ```

Live camera appears on the GS screen within ~1–2 s. Ctrl-C either side to stop.

The GS viewer pipeline (`~/play.sh`):

```bash
#!/bin/bash
export DISPLAY=:0
exec gst-launch-1.0 \
  udpsrc port=5600 caps="application/x-rtp,media=video,encoding-name=H264,payload=96" \
  ! rtpjitterbuffer latency=50 \
  ! rtph264depay ! h264parse ! avdec_h264 ! videoconvert \
  ! autovideosink sync=false
```

> **Launching from SSH:** start `play.sh` and `cam.sh` in your **own interactive
> terminals** (an `ssh` session you keep open). Trying to background a persistent
> GStreamer process *through* a one-shot `ssh '... &'` call tends to drop the
> SSH channel (exit 255) and the process dies with it. Interactive sessions hold
> them fine. (The auto-start service below removes this concern entirely.)

**Health check / tuning** (from anywhere with SSH to the GS):

```bash
ssh rpi5-waverover 'wfb-cli gs'    # live RSSI, pkt/s, FEC, loss
```

Tune bitrate/resolution/FPS in `~/cam.sh`; FEC / txpower / channel in
`/etc/wifibroadcast.cfg` (must stay **matched** across both ends — see §4).

**TX radio thermal check** (run on the air-side RPi4B). The RTL8812EU reports a
per-PA-path temperature; the driver's overheat warning is **60 °C**:

```bash
watch -n2 'sudo cat /proc/net/rtl88x2eu/$(ls /sys/class/net | grep ^wlx)/thermal_state'
# each line = one antenna path; read the `temperature:` field (°C)
```

- **< 55 °C** comfortable · **55–60 °C** warm (add airflow for sustained TX) ·
  **≥ 60 °C** overheat warning — PA may throttle/degrade; improve cooling or drop
  `wifi_txpower`.
- ⚠️ **Heat scales hard with `wifi_txpower`.** At the bench setting (1000 = 10 dBm)
  both paths sat at **47–49 °C under live video TX** — lots of margin. **Re-check
  at your operational power** (20–30 dBm for range) — that's the reading that
  actually validates cooling for flying. Log a temp at each power level during
  range testing.

> ⏳ **Next session — make it hands-free:** wrap `cam.sh` in a systemd service on
> the robot (free the camera from ROS first, §6.4) so video streams on power-up,
> and optionally autostart `play.sh` on the GS desktop. Then you just power the
> robot and open the viewer.
