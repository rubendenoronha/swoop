#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Search npm
# @raycast.mode silent
# @raycast.argument1 { "type": "text", "placeholder": "Package", "percentEncoded": true }

# Optional parameters:
# @raycast.icon 📦
# @raycast.packageName Developer

open "https://www.npmjs.com/search?q=$1"
