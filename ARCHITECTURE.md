# Architecture — how this FPV link actually works

An educational walk through every layer of the link, bottom to top: what the
silicon does, what the driver does, what wfb-ng adds, and how a photon hitting
the camera becomes a pixel on the ground-station monitor ~150 ms later. Written
for an embedded developer who wants to *reason* about the system, not just run
it. Facts about wfb-ng internals are taken from the vendored source in
[`third_party/wfb-ng/src/`](third_party/wfb-ng/src/) — file references point
there so you can go read the real thing.

The concrete numbers below are **our** configuration (see `INSTALL.md` §4):
channel 165 (5825 MHz), 20 MHz width, MCS 1, FEC 8/12, 720p30 H.264 at 4 Mbps.

---

## 0. The system in one picture

```
ROBOT (RPi4B, Ubuntu)                                GROUND STATION (RPi5, Bookworm)
┌────────────────────────────────────────┐           ┌────────────────────────────────────┐
│ IMX708 sensor (Camera Module 3)        │           │                                    │
│   │ CSI-2, raw Bayer frames            │           │                                    │
│ Unicam (CSI receiver) → ISP (VC4 HW)   │           │                                    │
│   │ processed YUV frames               │           │                                    │
│ rpicam-vid                             │           │                                    │
│   │ V4L2 M2M → HW H.264 encoder        │           │                                    │
│   │ H.264 byte-stream on stdout        │           │                                    │
│ gst: h264parse ! rtph264pay            │           │ gst: udpsrc :5600                  │
│   │ RTP/UDP → 127.0.0.1:5602           │           │   ! rtpjitterbuffer (50 ms)        │
│ wfb_tx                                 │           │   ! rtph264depay ! h264parse       │
│   │ +encrypt +FEC(8/12) +802.11 frame  │           │   ! avdec_h264 (SW decode)         │
│ rtl8812eu driver (monitor mode)        │           │   ! autovideosink sync=false       │
│   │ raw packet injection               │           │        ▲ UDP 127.0.0.1:5600        │
│ BL-M8812EU2 radio ═══ 5.8 GHz RF ══════════════════▶ BL-M8812EU2 radio                  │
│                     (one-way, no ACKs) │           │   │ monitor-mode capture           │
│                                        │           │ wfb_rx: de-FEC, decrypt, dedup     │
└────────────────────────────────────────┘           └────────────────────────────────────┘
```

Everything on the left of the RF hop runs under `fpv-cam.service` +
`wifibroadcast@drone`; everything on the right under `wifibroadcast@gs` +
a manually started `play.sh`.

---

## 1. Why not normal WiFi (the whole point of wfb-ng)

Normal WiFi is built around a **connection**: associate with an AP, negotiate
rates, ACK every frame, retransmit what's lost, disconnect when the signal
gets bad. Every one of those features is wrong for FPV:

- **Retransmission adds unbounded latency.** A retransmitted video frame is
  a *late* video frame — worse than a lost one. You want the freshest frame,
  always.
- **Association is a cliff.** Signal degrades → throughput collapses → link
  *drops* → seconds of re-association while the robot drives blind. FPV wants
  *graceful* degradation: more noise → more artifacts → still steering.
- **Rate adaptation fights you.** The card silently drops to slower rates,
  changing your latency and airtime under load.
- **It's two-way.** ACKs mean the receiver must transmit; a receive-only
  ground station can be completely passive (and you can add more receivers
  without telling the transmitter — that's how multi-antenna diversity works
  in wfb-ng).

wfb-ng's answer: put both cards in **monitor mode** (the "just give me raw
frames" mode meant for packet sniffers), and **inject** hand-built 802.11
frames on the TX side. There is no association, no ACK, no retry, no rate
negotiation — the transmitter shouts into the void at a fixed rate, and
whoever tunes to the channel hears it. Reliability is rebuilt *above* this,
with erasure coding (§4.3), which trades a fixed, known amount of redundancy
for loss tolerance — instead of unbounded time.

The mental model: **wfb-ng is a UDP-over-radio pipe**. Anything you push into
UDP port 5602 on the robot falls out of UDP port 5600 on the GS. Video is just
the main tenant; the same link also carries a MAVLink channel and a
general-purpose IP tunnel (§4.5).

---

## 2. The radio: BL-M8812EU2 (RTL8812EU inside)

The module is a bare PCB with a **Realtek RTL8812EU** — an 802.11ac
"wave 2" USB chip, 2×2 MIMO (two RF paths, J0/J1), with external PA + LNA on
each path. It enumerates as USB ID `0bda:a81a`.

What "an 802.11 USB NIC" actually is, in embedded terms: an SoC running its
own firmware that implements the entire PHY and low-level MAC in
hardware/firmware — OFDM modulation, convolutional/LDPC coding, scrambling,
preambles, carrier sense, all of it. The host driver doesn't modulate
anything; it hands the chip a MAC frame plus per-frame TX descriptors (rate,
bandwidth, antenna config) and the silicon does the rest. That's why
"injection" is possible at all: the chip will happily transmit any
well-formed frame it's handed — *if* the driver is willing to pass it
through.

Points that matter for this project:

- **Power.** TX bursts pull up to ~2.5 A at 5 V — far beyond a Pi USB port.
  Hence the separate 5 V supply, common ground, and bulk capacitor (wiring
  table in `SETUP_LOG.md`). Undervoltage here looks like "USB device resets
  mid-flight," which looks like a software bug. It isn't.
- **Thermals.** The PA dissipates real heat; the driver exposes a per-path
  temperature (`/proc/net/rtl88x2eu/<iface>/thermal_state`, overheat warning
  at 60 °C). Heat scales hard with TX power — at our bench 10 dBm both paths
  sit ~47 °C; re-check at 20–30 dBm before range driving (INSTALL §7).
- **Why this chipset?** Not because it's special silicon — because the
  **driver** (svpcom's `rtl8812eu` fork, vendored at
  `third_party/rtl8812eu/`) is patched for reliable monitor mode + injection
  with the radiotap controls wfb-ng needs, and the FPV community has beaten
  on it. The stock Realtek driver can't do this.

---

## 3. The driver layer: monitor mode + injection

The `rtl8812eu` driver is a **vendor driver**: it implements the whole WiFi
MAC stack internally (its own scanning, its own state machine) instead of
using the kernel's shared `mac80211` framework. Ugly for normal WiFi;
irrelevant for us, because wfb-ng uses exactly two features:

1. **Monitor mode** (`iw dev <iface> set monitor otherbss`): the driver stops
   filtering — every frame decoded on the channel is delivered raw to
   userspace, prefixed with a **radiotap header** (per-frame metadata: RSSI,
   rate, flags). No association state exists at all.
2. **Injection**: a userspace process opens a raw `AF_PACKET` socket on the
   monitor interface and writes frames that begin with a radiotap header the
   *sender* fills in. The driver parses that header and obeys it per frame.

Radiotap is the key embedded-flavored detail: it's a little TLV-ish binary
header (`src/ieee80211_radiotap.h`) through which wfb_tx dictates, **per
packet**: MCS index, 20/40 MHz bandwidth, long/short guard interval, STBC,
LDPC. That's how the link runs at a *pinned* rate — our systemd invocation is
visible in `ps`: `wfb_tx ... -B 20 -G long -S 1 -L 1 -M 1` (20 MHz, long GI,
STBC on, LDPC on, MCS 1).

Because the driver is out-of-tree it must be rebuilt for every kernel — hence
**DKMS**, which recompiles it automatically on kernel upgrades. It's built
per-machine: the RPi4B runs Ubuntu's 6.8 kernel, the RPi5 runs Raspberry Pi
OS's 6.12; same source, two builds (INSTALL §§2–3).

One deliberate oddity: `wifi_region = 'BO'` in the config. Regulatory
domains cap TX power per channel; wfb-ng ships that workaround so the kernel
regulatory db doesn't clamp the radio below what the hardware allows. The
*ethics/legality* of power and channel choice is on you (and note the ham
question in `SETUP_LOG.md`: ham privileges forbid encryption, and wfb-ng's
crypto is mandatory — unresolved).

---

## 4. wfb-ng: the transport (`third_party/wfb-ng/src/`)

### 4.1 The frame it puts on the air

wfb_tx builds an 802.11 **data frame** by hand (`wifibroadcast.hpp:156`):

```
08 01 00 00                dframe, broadcast, no protection bit
FF FF FF FF FF FF          receiver addr: broadcast (nobody ACKs broadcast!)
57 42 xx xx xx xx          transmitter addr — starts with "WB" in ASCII :)
57 42 xx xx xx xx          the xx bytes encode channel_id = (link_id, radio_port)
seq/frag                   sequence number
[payload: wfb-ng packet]   encrypted FEC block fragment
```

Two tricks in one header:

- **Broadcast receiver address** is what disables the 802.11 ACK machinery —
  the standard says broadcast frames are never ACKed, so even unmodified
  hardware won't try to retransmit.
- The **MAC address fields are repurposed as an addressing scheme**:
  `link_id` (derived from your key, so two wfb-ng systems on one channel
  don't cross-talk) plus `radio_port` (which logical stream this is — video,
  mavlink, tunnel). The RX filters on these bytes cheaply, in BPF.

### 4.2 Crypto and sessions (`tx.cpp`, `rx.cpp`)

Every data packet is encrypted+authenticated with **ChaCha20-Poly1305**
(libsodium AEAD) under a random **session key** generated by the TX at
startup. The session key itself is delivered in-band: wfb_tx periodically
broadcasts a **session packet** (`Transmitter::send_session_key()`,
`tx.cpp:645`) sealed with **crypto_box** (Curve25519 + XSalsa20-Poly1305)
using the keypair halves you generated with `wfb_keygen` — the drone signs
with `drone.key`, the GS unseals with `gs.key`. The session packet also
carries the link parameters (FEC k/n, epoch), which is why **FEC is a
TX-side setting**: the RX learns it from the air (that note in INSTALL §4 is
this mechanism).

Practical consequences: keys must match across ends or the RX silently
ignores everything; and a receiver can join mid-stream (it just waits for the
next session announcement — they repeat every couple of seconds).

### 4.3 FEC: the replacement for retransmission (`zfex.c`)

wfb-ng uses **Zfex**, an optimized Reed–Solomon-style *erasure code*
(Vandermonde matrix over GF(2⁸), the classic Rizzo construction — the
academic lineage is in the source header). Ours is **k=8, n=12**:

- Take 8 consecutive video packets (a *block*).
- Compute 4 parity packets from them; transmit all 12.
- The receiver can reconstruct the original 8 from **any 8 of the 12** — up
  to 4 losses per block, position-independent, zero extra round trips.

The trade-offs an embedded dev should see immediately:

- **Overhead is fixed**: n/k = 1.5× airtime (4 Mbps video → ~6 Mbps on air),
  spent whether or not anything was lost. It's insurance, pre-paid.
- **Latency couples to k**: parity is computed over a full block, so the
  encoder can't emit parity until 8 packets exist. At high packet rates this
  is milliseconds; it's one reason wfb-ng likes *big bitrate + small k*
  rather than tiny trickles.
- **Loss beyond 4/block = a hole in the H.264 stream** — smear/artifacts
  until the next IDR frame (≤1 s away, see §5.2). This is the graceful
  degradation you bought by abandoning retransmission.

### 4.4 The receive side (`rx.cpp`)

`wfb_rx` on the GS captures via pcap with a BPF filter on the channel_id
bytes, then: radiotap parse (RSSI per antenna — this is what `wfb-cli gs`
shows), dedup, FEC decode, AEAD decrypt/verify, reorder, and out the far end
of the pipe as plain UDP to `127.0.0.1:5600`. If several receivers/adapters
are attached (not our setup — yet), packets from all of them merge before
FEC, so any antenna hearing a fragment saves it: cheap spatial diversity.

### 4.5 One link, several streams

`ps` on the robot shows three `wfb_tx` instances, one per radio_port:

| radio_port | stream | our use |
|---|---|---|
| 0 | video (UDP 5602 → 5600) | the FPV feed |
| 16 | mavlink | idle (no flight controller — future rover telemetry?) |
| 32 | tunnel (`wfb_tun`) | idle IP tunnel over the link |

Same channel, same key, same radio; the port byte in the "MAC address" keeps
them apart. The tunnel is worth remembering: it's a general bidirectional IP
path over the wfb link — potentially the answer to "how do I send driving
commands without the home WiFi," within the FEC/latency budget of the uplink.

---

## 5. The video path

### 5.1 Air side: sensor to RTP (`fpv/cam.sh`)

**Camera stack.** The IMX708 sensor streams raw Bayer frames over CSI-2 into
**Unicam** (the Pi's CSI receiver), and the VC4's **ISP** turns them into
usable YUV (debayer, 3A, denoise). All of this is orchestrated by
**libcamera** in userspace — which is why a too-old distro libcamera means
"No cameras available!" even though the kernel sees the sensor (the saga in
SETUP_LOG 06-28; on Ubuntu we run a source-built libcamera 0.5 + rpicam-apps,
recipe: `fpv/setup-camera-ubuntu-24.04.sh`).

**Encoding.** `rpicam-vid` feeds frames to the RPi4's **hardware H.264
encoder** (V4L2 M2M device) — near-zero CPU. Streaming-specific flags:

- `--inline`: embed SPS/PPS (the stream's "decoder config registers") into
  the byte-stream itself, so a GS that tunes in mid-stream can configure its
  decoder without out-of-band data.
- `--intra 30`: an IDR (full, standalone) frame every second. IDR frames are
  the *only* re-sync points — after unrecoverable loss you're smearing until
  the next one. This is the knob balancing recovery time vs bitrate.
- `--bitrate 4000000`: 4 Mbps. Chosen to fit MCS 1's usable throughput with
  FEC headroom (§6).

**Packetization.** GStreamer wraps the byte-stream into **RTP**
(`rtph264pay`): H.264 NAL units chopped to fit ~1400-byte UDP packets
(FU-A fragmentation), each stamped with a 90 kHz timestamp and sequence
number so the receiver can reorder and pace. `config-interval=1` re-sends
SPS/PPS in-band every second — belt *and* suspenders with `--inline`.

**The hard-won flag: `udpsink sync=false`.** GStreamer sinks default to
pacing buffers against the pipeline clock. Our timestamps come from
`h264parse` *counting frames* at an idealized 30.000 fps, but the sensor
delivers a hair slower — so timestamps drift ahead of the clock and a
syncing udpsink waits longer and longer before releasing each packet.
Result: glass-to-glass latency creeping from ~0 to a ~1 s plateau (the
plateau = the pipe + camera buffer pool filling; diagnosed 2026-07-02 via
`wchan` sampling showing `rpicam-vid` stuck in `pipe_write` while every
socket queue in the system was empty). A live camera is already real-time
paced by physics; **nothing between camera and screen should ever wait on a
clock**. Both our pipelines now say so explicitly.

### 5.2 Ground side: RTP to pixels (`fpv/play.sh`)

```
udpsrc :5600 → rtpjitterbuffer(50ms) → depay → parse → avdec_h264 → convert → sink(sync=false)
```

- **`rtpjitterbuffer latency=50`** is the *only* intentional buffer in the
  whole chain. RF delivery is bursty (FEC blocks arrive in clumps and
  recovered packets pop out late); the jitterbuffer re-times packets against
  RTP timestamps inside a 50 ms window and reorders by sequence number.
  Smaller = less latency, more stutter under loss. This is a tuning knob.
- **`avdec_h264` is software decode** — the RPi5 dropped the VC4 H.264
  decode block, and its CPU decodes 720p30 with ease (~26 % of one core).
  (The RPi4 is the opposite: HW encode + HW decode, but a weaker CPU.)
- **`sync=false` on the sink**: same principle as the air side — render the
  newest frame immediately, never wait for a presentation clock.

---

## 6. RF budget & the numbers, briefly

- **Channel 165 = 5825 MHz**, 20 MHz wide. 5.8 GHz trades range/penetration
  for a quieter band and small antennas. For a land robot, expect terrain and
  bodies to matter much more than for an aircraft — range test before trust.
- **MCS 1** (QPSK, rate-1/2 coding) at 20 MHz / long GI ≈ **13 Mbps PHY**.
  Usable injection throughput is roughly half-ish of PHY after preambles and
  per-frame overhead — comfortably above our ~6 Mbps FEC-expanded video, with
  margin for the other streams. Low MCS = the most robust constellation; you
  buy SNR margin (≈ range) with bitrate you weren't using anyway.
- **STBC + LDPC on** (both radios are 2×2): the same data goes out both
  antennas in a space-time code (diversity, not doubled rate), with modern
  LDPC channel coding. Free robustness, since the hardware supports it.
- **TX power `1000` = 10 dBm** (the driver takes dBm×100) — a bench setting.
  Range driving wants 20–30 dBm, which is when the thermal check (§2) and
  the ham/encryption question (§3) become live issues. Only the **drone's**
  txpower matters for video; the GS transmits almost nothing.

## 7. Boot choreography & debugging crib sheet

**Robot power-on** (all automatic): `wifibroadcast@drone` starts `wfb_tx`
(radio → monitor mode, channel 165) → `fpv-cam.service` starts `cam.sh`
(retries every 2 s forever, so ordering races self-heal) → video flows
~15–30 s after power. **GS**: `wifibroadcast@gs` is up from boot; run
`~/play.sh` when you want eyes.

When something's wrong, walk the layers with these (all proven in anger):

| Question | Tool |
|---|---|
| Is the RF link alive? RSSI? losses? | `ssh rpi5-waverover 'wfb-cli gs'` (dloss>0 = FEC couldn't save it) |
| Is the radio in the right state? | `iw dev <iface> info` → `type monitor`, `channel 165 (5825 MHz)` |
| Radio overheating? | `/proc/net/rtl88x2eu/*/thermal_state` (warn ≥60 °C) |
| Camera service healthy? | `systemctl status fpv-cam` / `journalctl -u fpv-cam` |
| Where is latency hiding? | Byte queues: `ss -unap` Recv-Q/Send-Q, `tc -s qdisc`. If all zero but video lags: something is **clock-pacing** — sample `ps -L -o wchan:20,comm -p <pid>`; a producer stuck in `pipe_write` means downstream won't take data |
| Measure glass-to-glass | Film a millisecond stopwatch + the GS monitor in one photo; timestamp delta = latency |

## 8. Further reading (already in the repo)

- `third_party/wfb-ng/doc/Analysis of Injection Capabilities ... .pdf` — how
  monitor-mode injection really behaves per chipset; the academic companion
  to §3.
- `third_party/wfb-ng/doc/mimo_for_dummies.pdf` — STBC/MIMO background for §6.
- `third_party/wfb-ng/doc/wfb-ng-std-draft.md` — upstream's own protocol
  description (packet formats, session protocol).
- Upstream wiki: https://github.com/svpcom/wfb-ng/wiki
