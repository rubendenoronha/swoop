#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Show My IP Address
# @raycast.mode compact

# Optional parameters:
# @raycast.icon 🌐
# @raycast.packageName Network

ipconfig getifaddr en0 || ipconfig getifaddr en1 || echo "Not connected"
