#!/usr/bin/env bash
# Records a window of a running Baguette app as a GIF while a list of
# timed clicks drives it. Needs an X display, xdotool and ffmpeg.
#
#   scripts/record-gif.sh "Window title" SECONDS OUT.gif [AT:X,Y ...]
#
# Each AT:X,Y clicks window-relative X,Y at AT seconds into the recording.
set -euo pipefail

title=$1 seconds=$2 out=$3
shift 3
window=$(xdotool search --sync --name "^$title\$" | tail -1)
# xdotool reports the frame's position; xwininfo the client area's.
info=$(xwininfo -id "$window")
X=$(awk '/Absolute upper-left X/ {print $NF}' <<<"$info")
Y=$(awk '/Absolute upper-left Y/ {print $NF}' <<<"$info")
WIDTH=$(awk '/Width:/ {print $NF}' <<<"$info")
HEIGHT=$(awk '/Height:/ {print $NF}' <<<"$info")
frames=$(mktemp -d)
trap 'rm -rf "$frames"' EXIT

ffmpeg -loglevel error -y -f x11grab -framerate 15 -video_size "${WIDTH}x${HEIGHT}" \
  -i "$DISPLAY+$X,$Y" -t "$seconds" "$frames/capture.mkv" &
recorder=$!

start=$(date +%s.%N)
for click in "$@"; do
  at=${click%%:*} xy=${click#*:}
  now=$(date +%s.%N)
  delay=$(echo "$at - ($now - $start)" | bc)
  if (( $(echo "$delay > 0" | bc) )); then sleep "$delay"; fi
  xdotool mousemove --window "$window" "${xy%,*}" "${xy#*,}" click 1
done
wait "$recorder"

ffmpeg -loglevel error -y -i "$frames/capture.mkv" \
  -vf "fps=12,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
  "$out"
echo "$out"
