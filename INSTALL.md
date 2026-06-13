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

### 2.1 Install the RTL8812EU driver ⏳ *(pending verification)*

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
```

**Verify:** `lsmod | grep 8812eu` shows the module, and `ip -br link` shows a new
`wlan1` (the onboard `wlan0` Broadcom WiFi stays untouched).

> ⏳ Remaining air-side steps (wfb-ng install, drone profile, camera pipeline)
> will be added here as we verify them.

## 3. Ground station — Raspberry Pi 5 (Raspberry Pi OS Bookworm 64-bit)

⏳ *Pending — flash Bookworm 64-bit Desktop (SSH + WiFi enabled in Imager), then
driver + `scripts/install_gs.sh`. To be filled in once verified.*

## 4. Pairing the link (keys + channel)

⏳ *Pending — `wfb_keygen` once, distribute gs.key / drone.key, match
`wifi_channel` + `wifi_region` on both ends.*

## 5. Video pipeline

⏳ *Pending — air-side camera→encode→UDP:5602; ground-side UDP:5600→player.*
