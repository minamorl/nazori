#!/bin/sh
# Wires the USB path and starts the daemon. `adb reverse` maps the *device's*
# loopback to this Mac's, so the app dials 127.0.0.1 and lands here.
set -eu
SERIAL="${NAZORI_SERIAL:-}"
if [ -n "$SERIAL" ]; then ADB="adb -s $SERIAL"; else ADB="adb"; fi

$ADB reverse tcp:40118 tcp:40118
echo "adb reverse: $($ADB reverse --list)"
$ADB shell am start -n com.minamorl.nazori/.MainActivity >/dev/null
exec "$(dirname "$0")/../host/.build/release/nazorid" "$@"
