#!/bin/bash
# Air-side FPV camera capture -> H.264 -> RTP -> wfb-ng drone video (UDP 5602).
# Deploy to the RPi4B as ~/cam.sh (chmod +x). See INSTALL.md §6.5 / §7.
#
# Camera Module 3 (IMX708) is mounted upside-down, so --rotation 180.
#   --inline       : put SPS/PPS in-stream so the GS can join mid-stream
#   --intra 30     : keyframe every 30 frames (~1s @30fps) for fast recovery
#   config-interval=1 : resend SPS/PPS every second on the RTP side too
#   udpsink sync=false : send packets immediately. With the default sync=true,
#     udpsink paces buffers to h264parse's idealized-30fps timestamps; the real
#     camera runs a hair slower, so the wait grows -> latency creeps to ~1s
#     (rpicam-vid ends up blocked in pipe_write). Diagnosed 2026-07-02.
set -e

WIDTH=1280
HEIGHT=720
FPS=30
BITRATE=4000000   # 4 Mbps; tune later for the RF link

rpicam-vid -t 0 --nopreview --rotation 180 \
  --width "$WIDTH" --height "$HEIGHT" --framerate "$FPS" \
  --codec h264 --inline --intra "$FPS" --bitrate "$BITRATE" \
  -o - \
| gst-launch-1.0 -q -e fdsrc fd=0 \
  ! h264parse \
  ! rtph264pay config-interval=1 pt=96 \
  ! udpsink host=127.0.0.1 port=5602 sync=false
