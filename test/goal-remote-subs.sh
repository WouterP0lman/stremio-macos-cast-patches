#!/bin/bash
# The remote's subtitle list must reload when it switches to another device, or it
# stays on "Looking for subtitles..." for good. Counts the places that reset the
# list without also forgetting which stream it was loaded for; the one reset right
# after the key is set for a new stream is the load itself. Green = 0.
f=${1:-$(dirname "$0")/../webui/cast-remote.js}
n=$(awk '/subtitleSourceKey = state.source;/ {skip=NR+1} /subtitleOptions = null/ && !/subtitleSourceKey/ && !/var subtitleOptions/ && NR!=skip {c++} END {print c+0}' "$f")
echo "$n"; [ "$n" -eq 0 ]
