#!/bin/bash
# Ground-station FPV viewer: receive RTP/H.264 from wfb-ng (UDP 5600) and
# display on the attached monitor with low latency.
# Deploy to the RPi5 as ~/play.sh (chmod +x). See INSTALL.md §7.
export DISPLAY=:0
exec gst-launch-1.0 \
  udpsrc port=5600 caps="application/x-rtp,media=video,encoding-name=H264,payload=96" \
  ! rtpjitterbuffer latency=50 \
  ! rtph264depay \
  ! h264parse \
  ! avdec_h264 \
  ! videoconvert \
  ! autovideosink sync=false
