# Rindo

[![Build APK](https://github.com/TokyoDanInJapan/rindo/actions/workflows/build-apk.yml/badge.svg)](https://github.com/TokyoDanInJapan/rindo/actions/workflows/build-apk.yml)

Touring companion for Japan: JMA rain radar, road closures, and seasonal
gates on a rider-centred map.
Flutter (Android now; the iOS scaffold is in place for later).

Companion to [garmin-jma-radar](https://github.com/hebberd/garmin-jma-radar) -
same JMA nowcast, but fetched directly from the phone with no proxy: the
device stacks JMA's transparent radar tiles over an OSM base map itself.

## Features

- **Rain radar** - JMA 高解像度降水ナウキャスト (high-resolution precipitation
  nowcast), −15 min…+60 min in 15-minute frames, animated and centred on the
  rider's GPS position over a CyclOSM cycling base map. Radar tiles are pulled
  straight from JMA's (undocumented) nowcast endpoints; an empty/404 tile
  simply means "no rain there". JMA only renders these tiles at even zoom
  levels up to z10, so the app fetches z10 and lets the map scale it when
  you zoom in closer (blocky, matching JMA's ~250 m data, but always shown).
- **Scout another area** - long-press the map to drop a pin: closures load
  around it instead of the GPS position, a teal ring shows the searched
  radius (pulsing while it loads), and distances are measured from the pin.
  Tap the pin or the locate button to return to the rider.
- **Scout a planned ride (GPX)** - load a `.gpx` track (route FAB); it draws
  on the map and closures are searched within a **10 km corridor of the
  route** (union of the per-point searches), so everything on or near your
  planned ride is highlighted at once. Clear it from the same button.
- **Road closures within 50 km** - full closures (通行止) from two sources,
  merged and de-duplicated, drawn as markers + red segment overlays with a
  detail sheet linking to the authoritative source page:
  - **JARTIC** (`jartic.or.jp/map` internal GeoJSON) - nationwide incl.
    prefectural roads, 5-minute updates.
  - **MLIT 道路情報提供システム** (`road-info-prvs.mlit.go.jp`) - national
    highways (直轄国道) incl. winter closures (冬期通行止), with regulation
    periods.
- **English / Japanese toggle** (EN by default) - English mode swaps the
  base map for Esri's English-labelled World Street Map and machine-
  translates closure text on device with Google ML Kit (the ja/en models
  download once, ~30 MB each, then work offline); Japanese mode shows the
  sources verbatim over CyclOSM. Translation failures degrade to the
  original Japanese.
- **Graceful loading/offline** - base-map tiles pulse softly while they
  download, and a baked-in outline of Japan + prefecture borders (generated
  from GeoJSON by `tool/prep_japan_outline.dart`) shows beneath the tiles,
  so a slow or dead connection leaves a usable skeleton instead of a grey
  void. Tiles that *fail* (server errors, timeouts) render a visible
  broken-tile placeholder - tap it, or the "N tiles failed - tap to
  retry" banner, to refetch; an offline banner covers socket-level
  outages, and failed tiles also retry on ↻ or automatically once the
  network returns.
- **Landslide alerts (土砂災害警戒情報)** - JMA's municipality-level
  landslide warnings (issued jointly with prefectures) shown as amber
  markers at the municipality office within the search area. They usually
  precede the actual road closures by hours. Regenerate the municipality
  coordinate table with `tool/prep_municipalities.dart` after big mergers.
- **Weather report** - tap the rider dot (or a dropped pin) for JMA's area
  forecast where you're standing: today and tomorrow's weather in JMA's own
  wording, highs/lows, 6-hourly rain chances, wind and wave heights, and the
  prose outlook, plus any warning headline. The radar says what the rain is
  doing in the next hour; this says whether to set off at all. Forecasts are
  keyed by JMA area code rather than coordinates, so a position is resolved
  through the nearest municipality to its class10 subdivision (千葉県北東部,
  not just "Chiba") - regenerate that table with
  `tool/prep_forecast_areas.dart` if JMA reorganises its forecast areas. In
  English mode the report translates on device like the closures do, except
  for place names, which use JMA's own English ("North-eastern Region",
  "Sapporo City") - machine translation is at its worst exactly where JMA is
  already authoritative. The Japanese shows immediately and the English swaps
  in behind it, so a first-run model download never blocks the forecast.
- **Seasonal winter gates** - a curated, bundled dataset of annual mountain-
  pass closures (渋峠, 麦草峠, 金精峠, 乗鞍 …) with nominal open/close dates,
  drawn as indigo snowflake markers plus the full closed road section
  (geometry baked from OSM by `tool/fetch_gate_lines.dart`) while
  *scheduled*, so tours can be planned around them; live feeds confirm when
  a gate is actually closed.

The base map renders **greyscale by default** (like JMA's own nowcast page)
so radar and closure colours stand out; a palette button flips to full
colour.

## Layout

- `lib/jma/jma_api.dart` - JMA targetTimes/tile client (port of the proxy's
  `jma.js`; the only file to touch when JMA changes something)
- `lib/jma/jma_forecast.dart` - JMA area-forecast client behind the weather
  sheet, plus the generated position → forecast-area table
  (`forecast_areas.g.dart`)
- `lib/closures/` - closure model, JARTIC + MLIT sources, curated seasonal
  winter-gate dataset (`seasonal_gates.dart`, update once a year from the
  prefecture notices) with baked OSM road geometry
  (`seasonal_gate_lines.g.dart`, generated), merging repository, generated
  prefecture bbox/bureau table
- `lib/map/japan_outline.g.dart` - generated prefecture-boundary skeleton
  drawn beneath the tiles
- `lib/screens/radar_map_screen.dart` - the map screen's state + layer
  stack; its widgets (frame controls, legend, closure sheets/styling, tile
  pulse) live in `lib/screens/radar_map/`
- `test/` - unit tests; `test/fixtures/` are real captured API responses
- `tool/`
  - `run.sh` - boot the emulator (if needed) + `flutter run`
  - `deploy.sh` - build + install the release APK on a USB-connected phone
  - `live_check.dart` - network smoke test:
    `dart run tool/live_check.dart 35.45 139.55`
  - `fetch_gate_lines.dart` - regenerate seasonal-gate road geometry from
    OSM Overpass (run when a gate is added)
  - `prep_japan_outline.dart` - regenerate the prefecture skeleton from a
    prefectures GeoJSON (not checked in; pass its path)

## Setup

### 1. Install Android Studio (Linux)

Download the tarball from <https://developer.android.com/studio> and extract
it (e.g. to `~/.android-studio`), then launch it:

```sh
tar -xzf android-studio-*-linux.tar.gz -C ~
mv ~/android-studio ~/.android-studio
~/.android-studio/bin/studio      # add ~/.android-studio/bin to PATH for `studio`
```

The first-run wizard installs the Android SDK to `~/Android/Sdk`
(platform-tools, a platform, build-tools and the emulator). Android Studio
also bundles a JDK at `~/.android-studio/jbr` - no separate Java install is
needed:

```sh
export ANDROID_HOME=~/Android/Sdk
export JAVA_HOME=~/.android-studio/jbr
```

### 2. Install Flutter

```sh
git clone -b stable https://github.com/flutter/flutter.git ~/flutter
export PATH="$HOME/flutter/bin:$PATH"
flutter doctor --android-licenses
flutter doctor                    # everything under "Android" should be green
```

### 3. Create an emulator (AVD)

Either in Android Studio via **Device Manager → Create Virtual Device**, or on
the command line:

```sh
$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager \
  "system-images;android-35;google_apis;x86_64"
$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager create avd \
  -n tourtest -d pixel_7 -k "system-images;android-35;google_apis;x86_64"
```

### 4. Run the app in the emulator

The short way - boots the AVD if needed, then runs the app with hot reload:

```sh
tool/run.sh                       # env overrides: ANDROID_HOME, JAVA_HOME, FLUTTER, AVD
```

Or manually:

```sh
$ANDROID_HOME/emulator/emulator -avd tourtest &   # or start it from Device Manager
flutter pub get
flutter run                       # picks up the running emulator
```

`flutter run` gives hot reload (`r`) and hot restart (`R`). The emulator's
default GPS position is Mountain View - set a location in Japan via the
emulator's **⋯ → Location** panel to see radar and closures
(e.g. 35.45, 139.55 for Yokohama).

#### Emulator has no network ("Failed host lookup" / "Network is unreachable")

Symptom: everything that hits the network fails - radar, closures, the
translation-model download - with `errno 7` (Failed host lookup) or
`errno 101` (Network is unreachable), while the *host* has working
internet.

This is **not** a DNS problem. The usual cause is a stale **quickboot
snapshot** that froze Android in a state with no default network. Inside
the guest, `dumpsys connectivity` shows `Active default network: none`:
the interface (`eth0`, 10.0.2.15) and its local route are present, but
there's no default route, so Android's policy routing sends every packet
to the null `dummy0` interface. Crucially, `-no-snapshot-save` still
*loads* such a snapshot, so the broken state returns on every boot.

`tool/run.sh` now boots with **`-no-snapshot`** (a clean cold boot every
time) plus `-dns-server 8.8.8.8,1.1.1.1`, which avoids this. If you hit it
on an emulator started another way:

```sh
# 1. delete the stale snapshot so boots start clean
rm -rf ~/.android/avd/tourtest.avd/snapshots/default_boot
# 2. cold boot
~/Android/Sdk/emulator/emulator -avd tourtest -no-snapshot -dns-server 8.8.8.8

# verify inside the guest - want "Active default network: 100" (not "none"):
adb shell dumpsys connectivity | grep 'Active default network'
adb shell ping -c1 8.8.8.8
```

Related gotcha: if `run.sh` reports *"Emulator did not appear in adb"* but
a qemu process is running, the adb server is stale - `adb kill-server &&
adb start-server`, then rerun. (On a host whose GPU driver forces software
rendering, cold boots are also slower and occasionally flaky to launch;
just retry.)

### 5. Deploy to a real device

One-time phone setup: **Settings → About phone → tap "Build number" seven
times** to unlock Developer options, then enable **Developer options → USB
debugging**. Plug the phone in via USB and accept the "Allow USB debugging?"
prompt on its screen (`~/Android/Sdk/platform-tools/adb devices` should list
it as `device`, not `unauthorized`).

Then:

```sh
tool/deploy.sh                    # builds the release APK, installs + launches it
```

With several devices attached, pick one via `DEVICE=<serial> tool/deploy.sh`.
Release builds are signed with the debug key (fine for a personal device;
a real keystore is only needed for store distribution). For development
with hot reload on the phone, use `flutter run` instead - it targets a
connected phone the same way it targets the emulator.

## Build

```sh
flutter pub get
flutter test
flutter build apk --debug   # or --release
```

## Release

Release builds are signed with the keystore configured in
`android/key.properties` (gitignored; falls back to the debug key when the
file is absent, so `flutter run --release` works anywhere). One-time setup:

```sh
keytool -genkey -v -keystore ~/keystores/rindo-release.jks \
  -keyalg RSA -keysize 2048 -validity 10950 -alias rindo
# then fill in storeFile/storePassword/keyAlias/keyPassword in
# android/key.properties. Never commit the keystore or the passwords;
# losing the keystore means users must uninstall to ever upgrade.
```

Per release: bump `version:` in `pubspec.yaml` (the `+N` build number must
increase or Android refuses the upgrade), then:

```sh
tool/release.sh
```

This produces `build/release/rindo-<version>-arm64.apk` (the main download -
works on virtually every modern phone), `rindo-<version>.apk` (fat APK, any
device) and a `.sha256` file. Attach them to a GitHub Release and link from
the site; serving sideloaded APKs needs the MIME type
`application/vnd.android.package-archive` if self-hosting instead.

CI can do the whole release instead: pushing a `v<version>` tag runs
`.github/workflows/release.yml`, which builds the same signed APKs (the tag
must match the pubspec version) and attaches them to the GitHub Release.
It needs two secrets in the `release` environment - `KEYSTORE_BASE64`
(`base64 -w0` of the keystore) and `KEYSTORE_PASSWORD`. `build-apk.yml`
remains the unsigned CI check for pushes and PRs.

## License

The **code** in this repository is licensed under the
[PolyForm Noncommercial License 1.0.0](LICENSE): the source is open to
read, use, modify, and share for **noncommercial purposes only** - personal
use, hobby projects, research, education. **Commercial use, including
selling the app or a derivative, is not permitted.** This also matches the
terms of the closure data sources (JARTIC in particular limits its data to
private use).

The license covers the code only: data fetched at runtime remains subject
to its providers' terms, and the bundled/generated datasets listed below
carry their own upstream terms, which the code license does not override.

## Data terms

Fetched at runtime (not redistributed by this repo):

- JMA data: [Public Data License v1.0](https://www.jma.go.jp/jma/en/copyright.html)
  - attribution + "processed" notice required (shown in the map credits).
  The app redisplays JMA's own published nowcast; it does not synthesise
  forecasts (regulated under the Weather Service Act).
- CyclOSM tiles: hosted by OpenStreetMap France, fair-use; OSM data © OpenStreetMap
  contributors (ODbL).
- Esri World Street Map tiles (English mode): attribution shown in the map
  credits; fine for light personal use, but check Esri's terms before any
  distribution.
- JARTIC: terms limit the site/data to private use - fine for a personal
  tool; **do not distribute the app or its data for commercial purposes** (the
  code licence is noncommercial for the same reason). The endpoints are
  undocumented and may change.
- MLIT 道路情報提供システム: government content, attribution required.

Bundled in the repo (generated data, not covered by the code licence):

- `lib/map/japan_outline.g.dart` - prefecture boundary skeleton derived from
  Global Map Japan (地球地図日本, © 国土地理院/GSI,
  <https://www.gsi.go.jp/kankyochiri/gm_jpn.html>) obtained via
  [dataofjapan/land](https://github.com/dataofjapan/land). Per the
  distributor's terms: credit the source; commercial use additionally asks
  for a usage report to GSI.
- `lib/closures/seasonal_gate_lines.g.dart` - seasonal-gate road geometry
  extracted from OpenStreetMap via Overpass; © OpenStreetMap contributors,
  [ODbL](https://opendatacommons.org/licenses/odbl/).
- `lib/hazards/municipalities.g.dart` - municipality office coordinates from
  [code4fukui/localgovjp](https://github.com/code4fukui/localgovjp) (CC0;
  upstream sources GSI and J-LIS).
- `test/fixtures/` - two API responses captured 2026-07-13 for the unit
  tests: `r13.json` (JARTIC closure GeoJSON) and `tuko83.json` (MLIT 通行止
  data). They remain the property of their services and are included solely
  as test fixtures.
- The curated seasonal-gate list (`lib/closures/seasonal_gates.dart`) is
  hand-compiled from public prefecture road notices.
