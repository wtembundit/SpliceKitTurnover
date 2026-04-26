#!/bin/zsh
set -euo pipefail

osascript -e 'tell application id "com.splicekit.worker-app" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application id "com.splicekit.vfx-shot-list-worker-app" to quit' >/dev/null 2>&1 || true
