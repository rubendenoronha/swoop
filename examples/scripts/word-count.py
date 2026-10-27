#!/usr/bin/env python3

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Count Words on Clipboard
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.icon 🔢
# @raycast.packageName Text

import subprocess
text = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
print(f"{len(text.split())} words, {len(text)} characters, {len(text.splitlines())} lines")
