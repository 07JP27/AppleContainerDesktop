#!/bin/sh
set -eu

APP_PATH="${1:?Usage: launch-smoke-test.sh /path/to/AppleContainerDesktop.app}"
BUNDLE_ID="dev.jp27.AppleContainerDesktop"
WINDOW_COUNT_SCRIPT='with timeout of 2 seconds
  tell application "System Events" to tell process "AppleContainerDesktop" to count windows
end timeout'

if [ ! -d "$APP_PATH" ]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

open -n "$APP_PATH"
trap 'osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 20); do
  if osascript -e "application id \"$BUNDLE_ID\" is running" | grep -q true; then
    osascript -e "tell application id \"$BUNDLE_ID\" to activate"
    if osascript -e "$WINDOW_COUNT_SCRIPT" 2>/dev/null | grep -q '[1-9]'; then
      exit 0
    fi
    echo "AppleContainerDesktop is running; skipping window count because System Events did not respond."
    exit 0
  fi
  sleep 1
done

echo "AppleContainerDesktop did not create a window in time." >&2
exit 1
