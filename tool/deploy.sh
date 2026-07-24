#!/usr/bin/env bash
# Build a release APK and install + launch it on a USB-connected Android
# phone. See README "Deploy to a real device" for the one-time phone setup.
#
# Paths default to the layout in README "Setup"; override via env:
#   ANDROID_HOME=... JAVA_HOME=... FLUTTER=... DEVICE=<serial> tool/deploy.sh
set -euo pipefail

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export JAVA_HOME="${JAVA_HOME:-$HOME/.android-studio/jbr}"
FLUTTER="${FLUTTER:-$HOME/flutter/bin/flutter}"
ADB="$ANDROID_HOME/platform-tools/adb"
APP_ID=com.hebberd.rindo

[ -x "$FLUTTER" ] || FLUTTER="$(command -v flutter)" || {
  echo "flutter not found - install per README, or set FLUTTER=" >&2; exit 1;
}

cd "$(dirname "$0")/.."

# Fail fast on the device before the (slow) build. Emulators are excluded -
# this script is for real hardware; use tool/run.sh for the emulator.
mapfile -t devices < <("$ADB" devices | awk \
  'NR>1 && $2=="device" && $1 !~ /^emulator-/ {print $1}')
unauthorized=$("$ADB" devices | awk '$2=="unauthorized" {print $1}')

if [ -n "${DEVICE:-}" ]; then
  serial="$DEVICE"
elif [ "${#devices[@]}" -eq 1 ]; then
  serial="${devices[0]}"
elif [ "${#devices[@]}" -gt 1 ]; then
  echo "Several devices connected - pick one with DEVICE=<serial>:" >&2
  printf '  %s\n' "${devices[@]}" >&2
  exit 1
else
  if [ -n "$unauthorized" ]; then
    echo "Phone found but unauthorized - accept the USB-debugging prompt" \
         "on its screen, then rerun." >&2
  else
    echo "No phone detected. Enable Developer options + USB debugging" \
         "(README \"Deploy to a real device\") and plug it in via USB." >&2
  fi
  exit 1
fi

model=$("$ADB" -s "$serial" shell getprop ro.product.model | tr -d '\r')
abi=$("$ADB" -s "$serial" shell getprop ro.product.cpu.abi | tr -d '\r')
echo "Deploying to $model ($serial, $abi)…"

# Per-ABI APKs: the fat APK carries every architecture's native libs
# (~98 MB with ML Kit); the matching split is roughly a third of that.
"$FLUTTER" build apk --release --split-per-abi
apk="build/app/outputs/flutter-apk/app-$abi-release.apk"
[ -f "$apk" ] || {
  echo "No split APK for ABI '$abi' - falling back to the fat APK." >&2
  "$FLUTTER" build apk --release
  apk=build/app/outputs/flutter-apk/app-release.apk
}
"$ADB" -s "$serial" install -r "$apk"
"$ADB" -s "$serial" shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1 >/dev/null
echo "Installed $(du -h "$apk" | cut -f1) APK and launched $APP_ID on $model."
