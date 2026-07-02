# wave_rover_wireless — Build & Setup Log

A running journal of what we do and what we learn while building a digital
FPV-style video link with [wfb-ng](https://github.com/svpcom/wfb-ng).

> This repo is a fork of wfb-ng. We're using it to stream Camera Module 3 video
> from a robot (Wave Rover) to a ground station for low-latency display.

---

## Goal

Stream live video from a Raspberry Pi Camera Module 3 on a moving robot to a
ground station, over a long-range digital radio link (not normal WiFi).

## Hardware

| Role | Device | OS | Notes |
|------|--------|----|-------|
| **Air side** (TX) | Raspberry Pi 4B | Ubuntu (kernel `6.8.0-1057-raspi`) | On the Wave Rover robot. Ubuntu chosen for **ROS2**. Camera Module 3 capture already working here. |
| **Ground station** (RX) | Raspberry Pi 5 | Raspberry Pi OS Bookworm 64-bit (kernel `6.12.75+rpt-rpi-2712`) | Receives + decodes + displays video. **No hardware video decoder** — software-decodes H.264 fine. |
| **Radios** ×2 | BL-M8812EU2 | — | Bare USB modules, **Realtek RTL8812EU** chipset. Need soldering (USB + power). |

## How it works (mental model)

wfb-ng does **not** use normal WiFi association. It puts the adapters in
**monitor mode** and **injects raw 802.11 packets**. The two ends don't
"connect" — they just need the **same channel** + the **same encryption key**.

Data flow:

```
ROBOT (RPi4B / drone profile)                  GROUND (RPi5 / gs profile)
  Camera Module 3
    -> H.264 encode
      -> RTP -> UDP 127.0.0.1:5602
        -> wfb_tx  ))) 📡  RF  📡 (((  wfb_rx
                                          -> UDP 127.0.0.1:5600
                                            -> GStreamer player -> screen
```

## Key things we've learned

- **Driver matters most.** BL-M8812EU2 = RTL8812EU. The *stock* Linux driver
  won't do packet injection. We must build the **svpcom fork**:
  https://github.com/svpcom/rtl8812eu (DKMS). The wfb-ng installer only accepts
  a driver named `rtl88x2eu` (8812eu) or `rtl88xxau_wfb` (8812au).
- **Keys are a matched pair.** Run `wfb_keygen` **once**, then copy `gs.key` to
  the ground station and `drone.key` to the robot. Both ends must come from the
  same generation or the link stays silent.
- **Same channel + region** in `/etc/wifibroadcast.cfg` on both ends
  (default: channel 165 @ 5825 MHz, 20 MHz wide).
- **Pi 5 has no hardware video decoder** — fine, CPU handles 1080p H.264.
- **Ubuntu on the robot is intentional (ROS2)**; Camera Module 3 capture is
  already solved there (pipeline to be documented in the video step).
- ⚠️ **Never power/transmit the radio without an antenna attached** — can
  damage the RF power amplifier.
- **A robot's SD card must tolerate power cuts.** The FAT boot partition has no
  journaling and corrupted twice on hard power-off. Mount **`/boot/firmware`
  read-only** (it's static at runtime) — zero writes = nothing to corrupt.
  Verified against a real battery-dead cut. (Don't "remember to shut down
  cleanly" — solve it in the filesystem.)
- **Camera Module 3 on Ubuntu needs a source-built libcamera/rpicam-apps** (distro
  `0.2.0` is blind to the IMX708) and an **explicit `dtoverlay=imx708`**. The
  source libcamera in `/usr` is fragile to apt upgrades overwriting its IPA
  module — symptom "No cameras available!"; fix by reinstalling source libcamera.
- **The camera is single-owner.** ROS (`ros2_camera_feed.service`) and the FPV
  pipeline can't both hold it — disable one. Coexistence design still open.

## Plan / progress

- [ ] **0. Build the radios** — solder USB + power leads to each BL-M8812EU2, attach antennas.
- [x] **1. Confirm chipset** on RPi4B — `0bda:a81a` = RTL8812EU. ✅
- [x] **2. Build + install `rtl8812eu` driver** — done on **both** RPi4B (kernel 6.8) and RPi5 (kernel 6.12); both load + monitor mode works. ✅
- [x] **3. Install wfb-ng** — **GS (RPi5) done**: built `.deb` from repo, installed, `wifibroadcast@gs` running. ✅ *RPi4B (drone) pending.*
- [x] **4. Generate + distribute keys** — `wfb_keygen` run once on the GS (`/etc/gs.key` + `/etc/drone.key`). ✅ *drone.key still to copy to RPi4B.*
- [x] **5. Match config** — both ends on `wifi_channel=165` / `wifi_region='BO'` / `bandwidth=20`. ✅
- [x] **6. Bench test the radio** — **LINK UP**: `wfb-cli gs` shows RSSI ~−38/−40 dBm, dloss 0; test-pattern video confirmed drone→GS, color bars on the GS screen. ✅
- [x] **7. Wire in real Camera Module 3** pipeline on the RPi4B — **LIVE**: IMX708
  → H.264 → RTP → wfb → GS screen, smooth 720p30 (`~/cam.sh` + `~/play.sh`, in
  `fpv/`). Also hardened the SD against power cuts (read-only `/boot/firmware`). ✅
- [ ] **8. Make it hands-free** — `cam.sh` as a systemd service (auto-stream on
  power-up); resolve ROS-camera vs FPV coexistence; optional GS autostart.
- [ ] **9. Reduce glass-to-glass latency** — **correction (2026-07-02): it DOES
  grow, then seems to plateau.** Fresh start ≈ imperceptible; after a while it
  settles around ~900 ms–1 s (rough stopwatch; runs were short, so "plateau"
  is tentative). Restarting `cam.sh` resets it. Caveat: a TX restart also resets
  the GS `rtpjitterbuffer` (new SSRC/timestamp base), so this doesn't localize
  the growth yet. A plateau points at a **bounded buffer filling and staying
  full** (consumer marginally slower than producer), not clock drift.
  **Discriminating test next time it's slow: restart `play.sh` only** — if
  latency drops, it's GS-side (udpsrc socket buffer / jitterbuffer); if not,
  it's air-side (rpicam→gst pipe + encoder queue). Bounded-latency insurance
  either way: `rtpjitterbuffer drop-on-latency=true` + `queue leaky=downstream
  max-size-buffers=1` before the sink.
- [ ] **10. Mount on the robot** — antennas, power, range. Clone SD to a fresh card.

## Radio wiring reference (BL-M8812EU2)

These are **bare modules** — power them from a **separate 5 V supply**, not the
Pi's USB port (TX peaks ~2.5 A @ 5 V would brown out a Pi port).

| Module pad | Connects to | Wire (from a cut USB-A cable) |
|---|---|---|
| `USB2.0+DP` (D+) | Pi USB **D+** | green — twisted pair, short |
| `USB2.0-DM` (D−) | Pi USB **D−** | white — twisted pair, short |
| `GND` | **Common ground**: Pi GND **and** PSU GND | black |
| `VDD5.0` | **+5 V from separate supply (≥3 A)** | thick (22–24 AWG) |

- Leave the USB cable's **red (Pi 5 V) wire disconnected** — module is powered externally.
- **Tie the external PSU ground to the Pi ground** (shared `GND`) or USB won't enumerate.
- Pins **9–18 are GND** (can be left floating per datasheet).
- Add a **470–1000 µF bulk cap** across `VDD5.0`/`GND` at the module for TX spikes.
- On the robot, feed `VDD5.0` from a dedicated **5 V BEC/buck**, not the Pi's strained rail.

Safety:
- ⚠️ Attach 5 GHz antennas to IPEX connectors **J0 + J1 BEFORE powering** (no-antenna TX can fry the PA).
- 🔥 Add a **heatsink (+ fan at high power)**; 8812eu reports temp, overheat warning at 60 °C.

Refs: [manual](https://manuals.plus/ae/1005007098141054) ·
[datasheet](https://www.scribd.com/document/880836308/BL-M8812EU2-datasheet-V1-0-1-0-231027-70003939) ·
[OpenIPC wiki](https://github.com/OpenIPC/wiki/blob/master/en/fpv-bl-m8812eu2-wifi-adaptors.md)

---

## Open items to confirm later

- [x] **Confirm the radio operates on 5.8 GHz.** ✅ **GS side confirmed** —
  with `wifibroadcast@gs` running, `iw dev wlan1 info` shows
  `channel 165 (5825 MHz), type monitor`. wfb-ng retunes the card to 5 GHz on
  startup (vs the bare 2.4 GHz/ch1 default before any service runs). Full
  TX-over-the-air confirmation still comes once the air side transmits.

---

## Journal

### 2026-07-02 — Latency verdict revised: it creeps up to ~1 s, then plateaus

Fresh observations from today's session (link restarted after 4 days off):

- **On a fresh start the latency is near-imperceptible** — the committed
  `play.sh` (jitterbuffer 50 ms, `sync=false`) does behave low-latency, so the
  06-28 "~1–2 s" figure was *not* the pipeline's steady floor.
- **But it creeps:** after running a while it measured ~900 ms–1 s by a rough
  stopwatch test, and **seems to level off there** rather than grow without
  bound (caveat: runs were short — plateau not yet proven on a long run).
- **Restarting `cam.sh` (air side only) snapped it back to fast.** Tempting to
  blame the air side, but inconclusive: a TX restart gives the stream a new
  SSRC/timestamp base, which **also resets the GS `rtpjitterbuffer`** — so this
  experiment resets *both* ends' state at once.
- **Reading of the shape:** growth-to-a-ceiling is the signature of a **bounded
  buffer that fills and stays full** — a consumer running marginally slower
  than the producer until some queue hits capacity. Candidates: GS `udpsrc`
  kernel socket buffer, the jitterbuffer, or (air) the `rpicam-vid → gst` pipe
  + encoder queue. Pure clock drift is now less likely (drift doesn't plateau).
- **Next probe (cheap, decisive): when it's slow again, restart `play.sh`
  ONLY.** Latency drops → GS-side; stays → air-side.
- **Fix to apply regardless** (bounds latency no matter which buffer it is):
  `rtpjitterbuffer latency=50 drop-on-latency=true` and a
  `queue leaky=downstream max-size-buffers=1` right before the sink in
  `play.sh`.
- Also revised plan item 9 accordingly (the "stable, not growing" conclusion
  from 06-28 was wrong — it was measured too early in the growth curve).

### 2026-06-28 (later) — 🎥 REAL CAMERA over the link + SD card made power-cut-proof

The big day: live **Camera Module 3** video over the wfb link (smooth 720p30,
crisp). Getting there meant recovering from a 2nd SD corruption and peeling four
nested camera problems.

- **2nd SD corruption (again the FAT boot partition).** Robot wouldn't boot after
  power-cycling. Read the card on the laptop: `config.txt` gave **`Input/output
  error`** (a *hardware* read fault, not just logical scramble), 624 `FSCK*.REC`
  files, dirty bit set. `fsck.vfat -a -w` truncated the unreadable `config.txt`
  to 0 bytes; restored it from a backup; `fsck.ext4 -f -y` cleaned the root
  (damage again confined to `~/.ros/log`). Booted fine.
- **Root cause + the fix.** Both bricks share one fingerprint: the **FAT boot
  partition** corrupts (no journaling) on **power cuts** — and a robot gets its
  power *cut*, not `poweroff`'d. `config.txt` never changes at runtime, so we
  mounted **`/boot/firmware` read-only** (`defaults,ro` in fstab). It's not
  "fewer writes," it's **zero** (no dirty bit / FAT / FSINFO / atime) → a power
  cut has nothing to tear. **Proven the same session:** the robot battery died
  mid-work (hard cut) and it **booted clean** — boot partition still `ro`,
  `config.txt` intact, no fsck. That failure mode is closed. (Aging card is still
  suspect — plan to `ddrescue`-clone to a fresh card; overlayroot for the ext4
  root is a later upgrade. The user power-cuts the robot by design, so this had
  to be solved in the *filesystem*, not by "remember to shut down cleanly.")
- **Camera was dead — four stacked causes, all recovery fallout:**
  1. **Wrong port.** The ribbon was in the **DSI** (display) socket, not **CSI**
     (camera) — identical unlabeled FFCs on the Pi 4B. Kernel saw no sensor.
     Moved to CSI (between HDMI and the 3.5 mm jack) + set explicit
     `dtoverlay=imx708` (Ubuntu's `camera_auto_detect` is unreliable). → `dmesg`
     shows `imx708 ... module ID 0x0301`, a `unicam` media device appears.
  2. **Wiped binaries.** SD corruption deleted `/usr/local/bin/rpicam-*` (the
     `libcamera-*` symlinks dangled → "No such file or directory" on a file that
     `find` located). The **source build dir + libcamera 0.5.0 survived**, so
     just `meson compile -C ~/libcamera_build/rpicam-apps/build` + `meson install`.
  3. **Stale IPA module.** Then libcamera said **"No cameras available!"** despite
     the kernel seeing the sensor. Cause: the apt libcamera `0.2.0` (pulled in by
     the earlier ROS `full-upgrade`) had overwritten the source `ipa_rpi_vc4.so`
     (Pi 4's ISP) with its `0.2.0` version — ABI/signature mismatch, libcamera
     rejects it. Fix: reinstall source libcamera (`ninja -C
     ~/libcamera_build/libcamera/build install` — it recompiled + re-signed the
     `0.5.x` IPA). → `rpicam-hello --list-cameras` finally lists the IMX708.
  4. **ROS owned the camera.** `rpicam-vid` then hit *"Pipeline handler in use by
     another process."* The robot's `ros2_camera_feed.service` auto-starts and
     grabs the single-owner camera. `systemctl disable --now` it for FPV.
- **Streaming.** Wrote `~/cam.sh` (rpicam-vid → h264parse → rtph264pay →
  udpsink:5602, `--rotation 180` for the upside-down mount) and `~/play.sh`
  (udpsrc:5600 → jitterbuffer → depay → avdec_h264 → autovideosink). Both saved
  to `fpv/` in the repo.
- **SSH-backgrounding gotcha.** Launching the persistent GStreamer processes
  *through* one-shot `ssh '... &'`/`setsid` calls kept dropping the channel
  (**exit 255**, process didn't survive). Foreground `ssh` runs everything else
  fine; the durable players just need a **held interactive session** (or a
  systemd service). User ran `play.sh` (GS) and `cam.sh` (air) in their own
  terminals → instant live feed.
- **Link health with real video:** session negotiated **FEC K=8/N=12**, RSSI
  **−33 dB**, packet loss trivial (a startup blip; the "1 lost" lines are the
  telemetry tunnel, not video). Smooth and crisp end to end.
- Promoted INSTALL.md **§2.4** (read-only boot), **§6** (real camera: port, IMX708
  overlay, libcamera/rpicam-apps build + the IPA-clash fix, ROS conflict,
  `cam.sh`), **§7** (daily-use quick-start) to verified.
- **Open items:** (a) ROS-camera vs FPV **coexistence** design (one camera, one
  owner); (b) **auto-start** `cam.sh` as a systemd service so the robot streams
  on power-up (+ optional GS autostart) — next session; (c) **clone the SD** to a
  fresh card (it's showing hardware read faults); (d) overlayroot for full
  power-cut immunity.

### 2026-06-28 — 🎉 FIRST LIGHT: full wireless video link works end to end

- **Air side (RPi4B) brought up:** built wfb-ng `.deb` from the repo on Ubuntu
  24.04 (`0~noble`), installed it; copied `drone.key` from the GS (verified
  bit-identical via `sha256sum` — `093e3b8a…`); wrote the drone
  `/etc/wifibroadcast.cfg` (drone profile, ch165/BO/bw20 matching the GS, FEC
  authoritative, `[drone_video] peer=listen://0.0.0.0:5602`); enabled BOTH
  systemd units (lesson from the GS) with the `drone` profile. Service came up
  `active (running)`, card `wlx140a02515687` in monitor mode, ch165, 10 dBm.
- **Link confirmed:** `wfb-cli gs` on the RPi5 showed the **gs tunnel** RX panel
  with two antenna lines at **RSSI ~−38/−40 dBm**, `dloss 0`, sess decrypting —
  i.e. clean bidirectional RF + matched-key pairing. (video/mavlink panels at 0,
  expected — no source yet.)
- **Video end to end:** GStreamer `videotestsrc → x264enc → rtph264pay →
  udpsink:5602` on the drone lit up the GS **video** panel (recv pkt/s, ~2 Mbit/s).
  Then `udpsrc:5600 → rtph264depay → avdec_h264 → autovideosink` (DISPLAY=:0)
  on the RPi5 put the **SMPTE color bars on the portable screen.** 📺 First light!
- **Copy-paste gotcha (again):** long single-line `gst-launch` pipelines get
  chopped by terminal line-wrap on paste (newlines land mid-command, `!`
  separators become bash operators → `!: command not found`, `not-linked`).
  Fixes: keep it on ONE physical line, or backslash-split into short lines, or
  put it in a script. Documented in INSTALL.md §5.
- Promoted INSTALL.md **§2.2/§2.3** (air-side wfb-ng + drone profile), **§4**
  (pairing) and **§5** (video pipeline, test pattern) to verified. The core link
  is DONE — next is swapping the test pattern for the real Camera Module 3.

### 2026-06-27 (later) — RPi4B unbootable after apt upgrade — recovered (no reflash)

- After `apt full-upgrade` (~200 pkgs, mostly ROS Jazzy — NOT a kernel bump) +
  reboot, the RPi4B was unreachable (solid green ACT LED, no SSH; WiFi was its
  only path since eth0 is NO-CARRIER).
- Diagnosed by reading the SD card on the (Linux) laptop, *not* reflashing:
  dpkg.log showed the upgrade **completed** (not interrupted); `vmlinuz`+`initrd`
  present and correct size (not a missing-kernel); disk not full. **Smoking gun:
  600+ `FSCK*.REC` fragments in the FAT boot partition = filesystem corruption.**
- Fix: `fsck.vfat -a -w /dev/sdc1` (boot) + `fsck.ext4 -f -y /dev/sdc2` (root).
  Boot-partition corruption was the blocker; ext4 damage was confined to
  disposable `~/.ros/log` (a year of run logs). Re-inserted → **booted fine**,
  same kernel `6.8.0-1057-raspi`, radio (8812eu) intact.
- **Lessons:** corruption ≠ data loss (the *index* was scrambled, not the bytes;
  fsck rebuilds it from intact data — look before you reflash). Heavy SD logging
  (`~/.ros/log`) + a write storm can corrupt cards; watch this card for repeats.
  Keep kernel headers tracking the kernel for DKMS (separate earlier lesson).

### 2026-06-27 (later) — GS now boots clean (fixed half-enabled service)

- Reboot test of the RPi5 revealed the GS did **not** come up working:
  `wlan1` was present (driver auto-loaded on the new 6.12.93 kernel — DKMS
  persistence confirmed ✅) but in `type managed`, txpower -100 — i.e.
  NetworkManager had it, the `wifibroadcast@gs` service wasn't running.
- Cause: wfb-ng uses **two systemd units** — umbrella `wifibroadcast.service`
  (`WantedBy=multi-user.target`, the boot entry point) + worker
  `wifibroadcast@gs` (`WantedBy=wifibroadcast.service`). We'd only enabled the
  worker, never the umbrella, so at boot nothing pulled the chain. Status
  showed `disabled`.
- Fix: `systemctl enable wifibroadcast.service` **and**
  `systemctl enable wifibroadcast@gs`. After reboot, `iw dev wlan1 info` came
  up `type monitor` / ch165 / 10 dBm with **no** manual steps. GS now boots
  ready-to-receive. Corrected INSTALL.md §3.4 (the enable step was incomplete)
  + added a reboot-survival check.
- Watch item: possible boot race (service starts before USB enumerates
  `wlan1`). `Restart=on-failure` (5s) self-heals it; didn't trigger here.
  Robust fix if it ever does: bind umbrella to the
  `sys-subsystem-net-devices-<iface>.device` via Requires/After (commented
  example already in `wifibroadcast.service`).

### 2026-06-27 — wfb-ng installed + GS link UP on the RPi5 ✅

- Built the wfb-ng `.deb` **from our repo** on the RPi5 (`make deb`). Hit one
  missing build-dep: `dpkg-checkbuilddeps: error: unmet build dependencies:
  python3-all-dev` → installed `python3-all-dev`, rebuilt, got
  `wfb-ng_26.6.13.56077-0~bookworm_arm64.deb`. Installed via
  `apt install ./deb_dist/...deb` (pulled `socat`). (Harmless apt note about
  "unsandboxed download ... Permission denied" when installing from $HOME.)
- Package ships `/etc/default/wifibroadcast` (NIC autodetect) + the systemd
  units, but **not** `/etc/wifibroadcast.cfg` — we create that. Did the
  config half of `scripts/install_gs.sh` by hand (since we installed our own
  .deb, not the apt-repo one): `wfb_keygen` in /etc (gs.key + drone.key),
  wrote `/etc/wifibroadcast.cfg` (gs profile, ch165, region BO, video→5600),
  `/etc/modprobe.d/wfb.conf`.
- **Heredoc-over-SSH gotcha:** `sudo tee <<'EOF'` pastes kept hanging on the
  shell `>` continuation prompt → switched to `sudo nano`. Noted in INSTALL.md.
- **Kernel-update / DKMS gotcha (the big lesson):** service first failed with
  `wfb-server: --wlans: expected at least one argument` → `wfb-nics` returned
  empty → no `wlan1`. Cause: `apt upgrade` over the break moved the kernel
  6.12.75 → 6.12.87, but DKMS hadn't rebuilt 8812eu for it (headers/kernel
  drift), so `modprobe 8812eu` gave *"Module not found in
  /lib/modules/6.12.87..."*. Fix: headers for the running kernel were present,
  so `sudo dkms autoinstall` rebuilt the module for 6.12.87, `modprobe` loaded
  it, `wlan1` returned. **Keep updating, just keep headers in sync; recover with
  `dkms autoinstall`.** Documented as a callout in INSTALL.md §3.2.
- `systemctl restart wifibroadcast@gs` → **`active (running)`**: it spawned
  `wfb-server --profiles gs --wlans wlan1`, the `wfb_rx ... -u 5600 -K
  /etc/gs.key` video receiver, + mavlink/tunnel helpers. Enabled on boot.
- **5.8 GHz confirmed (RX side):** `iw dev wlan1 info` →
  `channel 165 (5825 MHz), type monitor`, txpower 19 dBm. Closed that open item.
- Promoted INSTALL.md **§3.3 + §3.4** to verified. **Ground station is done** —
  receive half of the link is built and listening. Next: RPi4B air side
  (drone profile + copy drone.key + camera pipeline).
- **Made RF/FEC knobs explicit** in `/etc/wifibroadcast.cfg` (vs inheriting
  master.cfg defaults) so they're visible/tunable: `wifi_txpower = 1000`
  (10 dBm — deliberately low for close-range bench testing), `bandwidth = 20`,
  `fec_k=8`/`fec_n=12`. After restart, `iw dev wlan1 info` now reads
  `txpower 10.00 dBm` (the explicit value *is* honored + reported — the "iw is
  cosmetic" caveat only applied to the unset driver default). Notes for later:
  GS txpower only drives the (mostly unused) uplink — the **drone's** txpower
  governs the video downlink; and FEC is TX-side, so the **drone** copy is
  authoritative (RX derives FEC from the session packet).

### 2026-06-14 — RPi5 ground station driver VERIFIED ✅ (both ends at parity)

- Flashed the RPi5 with **Raspberry Pi OS Bookworm 64-bit Desktop** (Imager:
  hostname `rpi5-waverover`, SSH + onboard WiFi enabled). First attempt was
  **32-bit by mistake → reflashed 64-bit**: our vendored driver's Makefile
  targets arm64 (`CONFIG_PLATFORM_ARM64_RPI=y`), so a 32-bit (armhf) kernel is
  the wrong platform. Bonus: both Pis on arm64 = one identical driver build.
- Confirmed `uname -m` = **aarch64**, Bookworm 12, kernel
  **`6.12.75+rpt-rpi-2712`** (newer than the RPi4B's 6.8 — DKMS handles it).
- Headers package on Pi OS = **`raspberrypi-kernel-headers`** (NOT Ubuntu's
  `linux-headers-$(uname -r)`). `ls /lib/modules/$(uname -r)/build` resolved → OK.
- Cloned the repo over **HTTPS** (no GitHub SSH key needed on a fresh Pi),
  `sudo ./dkms-install.sh` built cleanly against 6.12, `sudo modprobe 8812eu`
  loaded it: dmesg shows `usbcore: registered new interface driver rtl88x2eu`.
- Interface = **`wlan1`** here (Pi OS naming), vs `wlx140a02515687` on Ubuntu —
  doesn't matter, wfb-ng autodetects by driver. Onboard `wlan0` (SSH) untouched.
- `ID_NET_DRIVER=rtl88x2eu` ✅ and **monitor mode confirmed** (`type monitor`,
  txpower 19 dBm, same 2.4 GHz/ch1 default until wfb-ng retunes to ch165). 🎯
- **The earlier Trixie-avoidance worry about 6.12+ vs the out-of-tree driver
  didn't materialize** — Bookworm now ships 6.12 anyway and the driver built fine.
- Promoted INSTALL.md **§3.1 + §3.2** to verified (Pi OS driver path documented
  alongside the Ubuntu path in §2.1). **Both radios now at parity.**

### 2026-06-13 (later) — RPi4B driver VERIFIED ✅

- After the dkms.conf fix, `sudo ./dkms-install.sh` built cleanly against
  kernel `6.8.0-1057-raspi` (`8812eu.ko.zst` installed, depmod ran).
- Module didn't auto-load (adapter was plugged in before the driver existed) →
  `sudo modprobe 8812eu` loaded it and it bound to the device.
- New interface = **`wlx140a02515687`** (Ubuntu MAC-based name, not `wlan1`).
  Onboard `wlan0` (brcmfmac, the SSH path) untouched.
- `ID_NET_DRIVER=rtl88x2eu` → **wfb-ng autodetect will match** (no need to
  hardcode the interface name).
- **Monitor mode confirmed**: `iw set type monitor` → `type monitor`, txpower
  19 dBm. This is the capability the whole project needs. 🎯
- Noted a chatty dmesg backtrace (`phydm_*`/`rtw_acs_trigger`) during a scan —
  NetworkManager surveying the card; harmless, will stop under monitor+unmanaged.
- Promoted INSTALL.md §2.1 to **verified**.

### 2026-06-13 (later) — Driver build blocked by missing dkms.conf (fixed)

- First `sudo ./dkms-install.sh` on RPi4B failed: *"Could not locate dkms.conf
  file ... /usr/src/rtl88x2eu-5.15.0.1/dkms.conf does not exist."*
- Wrong first theory: the upstream script's `cp -r $(pwd) DEST` nesting footgun.
  Disproved — `find` showed no nested dkms.conf, and a manual clean copy still
  lacked it.
- **Real cause:** the vendored driver carried its **own nested `.gitignore`**
  (a C-dev template) whose line 56 ignores `dkms.conf`. My `git add third_party`
  honored it and silently omitted `dkms.conf` — so the Pi's `git pull` never had
  it. Upstream force-adds dkms.conf past that ignore; my commit didn't.
  (Diagnosed via `git check-ignore -v` and on-disk(720) vs tracked(719) counts.)
- **Fix:** removed the nested `.gitignore` (we never build in-place; dkms builds
  in /usr/src) and committed `dkms.conf`. Now 719 on disk == 719 tracked.
  Recorded in VENDOR.md. Commit `4260847`.
- **Learning:** when vendoring a repo, check for nested `.gitignore` files —
  they can silently drop required files from your commit. `git status --ignored`
  catches this.
- Next on RPi4B (after push + re-pull): clean the leftover
  `sudo rm -rf /usr/src/rtl88x2eu-5.15.0.1`, then `sudo ./dkms-install.sh`.

### 2026-06-13 (later) — Vendored the rtl8812eu driver into the repo

- Goal: be able to rebuild on fresh hardware independent of upstream survival.
- Chose **vendored local copy over git submodule**: a submodule only stores a
  pointer, so if upstream is ever deleted a fresh checkout can't fetch it —
  that fails the "independent" goal. A local copy lives in our repo forever.
- Vendored `svpcom/rtl8812eu` tag `v5.15.0.1` (commit `48e6e44`) into
  `third_party/rtl8812eu/`, stripped upstream `.git`, baked in the arm64
  Makefile flags (works for both Pis). Provenance + license notes in
  `third_party/rtl8812eu/VENDOR.md`.
- **Brief scare:** user saw only `v5.2.20` on GitHub — turned out they were
  looking at `rtl8812**au**` (AU chips), not our `rtl8812**eu**` (EU chips).
  Two different svpcom repos with different version schemes. Our successful
  clone at `v5.15.0.1` confirmed the eu tag is real.
- **License check:** driver is **GPL-2.0-only** (stated in source headers, no
  standalone LICENSE file). Our repo is GPL-3.0. This is legal as **mere
  aggregation** (GPL §5) — two separate programs (userspace wfb-ng vs a kernel
  module) side by side, not linked/combined. Obligations met: preserved
  notices, ship full source, documented our Makefile change in VENDOR.md, kept
  it isolated and not relicensed. (Same pattern every Linux distro uses.)
- INSTALL.md §2.1 updated to build from the vendored copy (no clone, no sed).

### 2026-06-13 (later) — RPi4B driver build started

- Diagnostic on RPi4B: kernel `6.8.0-1057-raspi`, **arch arm64**.
- **Kernel headers were MISSING** and **dkms not installed** → installing
  `dkms build-essential bc git linux-headers-$(uname -r)` first.
  (Ubuntu-raspi fallback if headers pkg not found:
  `linux-headers-raspi linux-modules-extra-raspi`.)
- `wlan0` present = **onboard Broadcom WiFi (brcmfmac)** and is the **SSH
  lifeline** (eth0 is NO-CARRIER). Must NOT be touched — our radio will be a
  separate iface (expect `wlan1`), and wfb-ng will be pointed only at it.
- No stock driver bound to the RTL8812EU on this Pi → no blacklisting needed here.
- **Driver build plan (svpcom/rtl8812eu, tag `v5.15.0.1`, ARM64):**
  clone → sed Makefile (`CONFIG_PLATFORM_I386_PC=n`, `CONFIG_PLATFORM_ARM64_RPI=y`)
  → `sudo ./dkms-install.sh`. Module name = `8812eu`.

### 2026-06-13 (later) — First radio soldered & enumerates

- Soldered radio #1: USB data pair + GND to a USB cable, `VDD5.0` to a **5 V / 5 A**
  supply, two 5.8 GHz antennas on J0/J1, heatsink + fan fitted. 👍
- Plugged into RPi4B → `lsusb` shows `Bus 001 Device 004: ID 0bda:a81a Realtek
  Semiconductor Corp. 802.11ac NIC`.
- **`0bda:a81a` = RTL8812EU confirmed.** Generic "802.11ac NIC" descriptor is
  expected until the proper driver binds. → use **svpcom/rtl8812eu** fork.
- Next: gather kernel/headers/driver-bound/build-tools state on RPi4B, then
  build the driver. ✅ checked off plan step 1 (chipset confirmed).

### 2026-06-13 — Kickoff

- Established the architecture and roles above.
- Confirmed BL-M8812EU2 = RTL8812EU → need the svpcom/rtl8812eu driver fork.
- Decided GS OS = Raspberry Pi OS Bookworm 64-bit Desktop (RPi5).
- Kept Ubuntu on RPi4B (for ROS2); camera capture already working there.
- **Realized step 0 is physical:** the BL-M8812EU2 modules are bare boards —
  need USB data + power leads soldered on before any software work.
- Looked up official wiring (LB-LINK datasheet / OpenIPC wiki). Key learning:
  **power the module from a separate ≥3 A 5 V supply, not the Pi's USB** (TX
  peaks ~2.5 A). Data pair (D+/D−) + **common ground** to the Pi; leave the
  USB cable's 5 V wire disconnected. See "Radio wiring reference" above.
- Confirmed Ubuntu on RPi4B is for ROS2 and Camera Module 3 capture is already
  working there — user will share that pipeline at the video step.
- **OS decision for RPi5 GS: Bookworm (legacy), NOT Trixie.** Trixie's newer
  kernel (6.12+) is riskier for the out-of-tree rtl8812eu driver, wfb-ng's apt
  repo may lack a `trixie` suite (forcing source build), and all community
  guides assume Bookworm. No upside to Trixie on a receive-only GS. Revisit
  Trixie later once the driver/repo ecosystem catches up.
- Note: the two machines will run different kernels (RPi4B Ubuntu 6.8 vs RPi5
  Bookworm) — fine, we build the driver per-machine.
- Next: solder both radios (antennas on first!), then run the chipset/headers
  diagnostic on the RPi4B.
