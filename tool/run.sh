#!/usr/bin/env bash
# Launch the app in the Android emulator: boots the AVD if none is running,
# then hands over to `flutter run` (r = hot reload, q = quit).
#
# Always targets the emulator, never a USB-connected phone - use
# tool/deploy.sh for real hardware.
#
# Paths default to the layout in README "Setup"; override via env:
#   ANDROID_HOME=... JAVA_HOME=... FLUTTER=... AVD=... tool/run.sh
set -euo pipefail

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export JAVA_HOME="${JAVA_HOME:-$HOME/.android-studio/jbr}"
FLUTTER="${FLUTTER:-$HOME/flutter/bin/flutter}"
AVD="${AVD:-tourtest}"
ADB="$ANDROID_HOME/platform-tools/adb"

[ -x "$FLUTTER" ] || FLUTTER="$(command -v flutter)" || {
  echo "flutter not found - install per README, or set FLUTTER=" >&2; exit 1;
}

cd "$(dirname "$0")/.."

emulator_serial() {
  "$ADB" devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}'
}

serial="$(emulator_serial)"
if [ -z "$serial" ]; then
  echo "Starting emulator '$AVD'…"
  # -no-snapshot forces a clean cold boot every time. A saved snapshot can
  # freeze a broken network state (Android "Active default network: none",
  # so the guest routes everything to a null interface → "Network is
  # unreachable"), and -no-snapshot-save still *loads* such a snapshot.
  # -dns-server: the guest's forwarding of the host resolver
  # (e.g. systemd-resolved on 127.0.0.53) also breaks readily.
  "$ANDROID_HOME/emulator/emulator" -avd "$AVD" \
      -no-snapshot -dns-server 8.8.8.8,1.1.1.1 >/dev/null 2>&1 &
  # Poll for the emulator's serial: bare `adb wait-for-device` would race a
  # USB-connected phone and grab it instead. A cold boot (-no-snapshot) is
  # slower than a snapshot restore, so allow a few minutes.
  for _ in $(seq 1 120); do
    serial="$(emulator_serial)"
    [ -n "$serial" ] && break
    sleep 2
  done
  [ -n "$serial" ] || {
    echo "Emulator did not appear in adb after ~4 min." >&2
    echo "If a qemu process is running, the adb server is likely stale -" >&2
    echo "try: $ADB kill-server && $ADB start-server, then rerun." >&2
    exit 1
  }
  until [ "$("$ADB" -s "$serial" shell getprop sys.boot_completed 2>/dev/null |
      tr -d '\r')" = "1" ]; do
    sleep 2
  done
  echo "Emulator booted."
fi

exec "$FLUTTER" run -d "$serial"
