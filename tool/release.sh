#!/usr/bin/env bash
# Build the distributable release APKs: the arm64 split (the main download -
# virtually every modern phone) plus the fat APK as an any-device fallback,
# renamed with the pubspec version and checksummed, in build/release/.
# Attach them to a GitHub Release / upload wherever the site links to.
#
# Needs android/key.properties pointing at the release keystore (real
# passwords, not the CHANGE_ME placeholders). Paths default to the layout in
# README "Setup"; override via env: ANDROID_HOME=... JAVA_HOME=... FLUTTER=...
set -euo pipefail

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export JAVA_HOME="${JAVA_HOME:-$HOME/.android-studio/jbr}"
FLUTTER="${FLUTTER:-$HOME/flutter/bin/flutter}"

[ -x "$FLUTTER" ] || FLUTTER="$(command -v flutter)" || {
  echo "flutter not found - install per README, or set FLUTTER=" >&2; exit 1;
}

cd "$(dirname "$0")/.."

[ -f android/key.properties ] || {
  echo "android/key.properties missing - release builds must be signed with" \
       "the real keystore, not the debug key. See README \"Release\"." >&2
  exit 1
}
if grep -q CHANGE_ME android/key.properties; then
  echo "android/key.properties still has CHANGE_ME placeholders - fill in" \
       "the keystore passwords first." >&2
  exit 1
fi

version=$(sed -n 's/^version: *\([0-9][^+ ]*\)+.*/\1/p' pubspec.yaml)
[ -n "$version" ] || { echo "Could not read version from pubspec.yaml" >&2; exit 1; }

"$FLUTTER" build apk --release --split-per-abi
"$FLUTTER" build apk --release

out=build/release
mkdir -p "$out"
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk \
   "$out/rindo-$version-arm64.apk"
cp build/app/outputs/flutter-apk/app-release.apk \
   "$out/rindo-$version.apk"

(cd "$out" && sha256sum "rindo-$version-arm64.apk" "rindo-$version.apk" \
  > "rindo-$version.sha256")

echo
echo "Release $version:"
(cd "$out" && du -h "rindo-$version-arm64.apk" "rindo-$version.apk")
echo "Checksums in $out/rindo-$version.sha256"
