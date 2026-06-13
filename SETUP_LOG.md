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
| **Ground station** (RX) | Raspberry Pi 5 | Raspberry Pi OS Bookworm 64-bit (planned) | Receives + decodes + displays video. **No hardware video decoder** — software-decodes H.264 fine. |
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

## Plan / progress

- [ ] **0. Build the radios** — solder USB + power leads to each BL-M8812EU2, attach antennas.
- [x] **1. Confirm chipset** on RPi4B — `0bda:a81a` = RTL8812EU. ✅
- [x] **2. Build + install `rtl8812eu` driver** — done on RPi4B (loads, monitor mode works). ✅ *RPi5 still pending.*
- [ ] **3. Install wfb-ng** on both (`scripts/install_gs.sh` on the RPi5).
- [ ] **4. Generate + distribute keys** (`wfb_keygen` once; copy gs.key / drone.key).
- [ ] **5. Match config** — same `wifi_channel` + `wifi_region` on both.
- [ ] **6. Bench test the radio** with a test pattern; watch `wfb-cli gs` for RSSI/packets.
- [ ] **7. Wire in real Camera Module 3** pipeline on the RPi4B.
- [ ] **8. Mount on the robot** — antennas, power, range.

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

- [ ] **Confirm the radio actually transmits on 5.8 GHz.** No separate test
  needed — wfb-ng tunes the card to channel 165 (5825 MHz) on startup, so this
  is verified for free the moment the link carries traffic on 5 GHz. (In bare
  monitor mode the card defaulted to 2.4 GHz ch.1 only because nothing sets a
  frequency until wfb-ng does; the RTL8812EU chip is dual-band but this module's
  RF front-end is tuned for 5 GHz.)

---

## Journal

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
