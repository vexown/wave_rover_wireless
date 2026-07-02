# wave_rover_wireless

Long-range digital FPV video link for a **Wave Rover** land robot: a Raspberry
Pi 4B + Camera Module 3 on the robot streams H.264 over **wfb-ng** (raw 802.11
packet injection on 5.8 GHz, BL-M8812EU2 / RTL8812EU radios) to a Raspberry
Pi 5 ground station that shows it live on a monitor. Working end to end,
hands-free on the robot side: power it on and it streams.

## Start here

| Doc | What it is |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | How it all works, layer by layer — radio silicon to pixels. Read this to *understand* the system. |
| [`INSTALL.md`](INSTALL.md) | The verified runbook: build everything from a fresh SD card to a live link. |
| [`SETUP_LOG.md`](SETUP_LOG.md) | The journal: every step, failure, and root cause, in chronological order. |

## Repo layout

```
fpv/                     our scripts: cam.sh (air), play.sh (GS),
                         fpv-cam.service (autostart), camera setup recipe
docs/hardware/           BL-M8812EU2 module photos/datasheet screenshots
third_party/wfb-ng/      vendored wfb-ng source (built on both Pis) — VENDOR.md
third_party/rtl8812eu/   vendored RTL8812EU driver (dkms, both Pis) — VENDOR.md
```

## Attribution

The heavy lifting is done by [wfb-ng](https://github.com/svpcom/wfb-ng) and the
[rtl8812eu driver](https://github.com/svpcom/rtl8812eu), both by Vasily
Evseenko (svpcom) and contributors — vendored under `third_party/` with
provenance notes. All credit for that work goes upstream.

## License

**GPL-3.0**, same as wfb-ng — full text in [`LICENSE.txt`](LICENSE.txt). The
vendored driver is GPL-2.0-only (see its `VENDOR.md`).
