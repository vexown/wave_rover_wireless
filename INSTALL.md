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

> ⏳ Remaining air-side steps (wfb-ng install, drone profile, camera pipeline)
> will be added here as we verify them.

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

> ⏳ Remaining ground-side steps (`scripts/install_gs.sh`, gs profile) will be
> added here as we verify them.

## 4. Pairing the link (keys + channel)

⏳ *Pending — `wfb_keygen` once, distribute gs.key / drone.key, match
`wifi_channel` + `wifi_region` on both ends.*

## 5. Video pipeline

⏳ *Pending — air-side camera→encode→UDP:5602; ground-side UDP:5600→player.*
