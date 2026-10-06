#!/bin/bash
# Subtitle sync: prints the number of failing checks.
/Applications/Stremio.app/Contents/MacOS/node "$(dirname "$0")/subsync.js"
