# Rindo

[![Build APK](https://github.com/TokyoDanInJapan/rindo/actions/workflows/build-apk.yml/badge.svg)](https://github.com/TokyoDanInJapan/rindo/actions/workflows/build-apk.yml)

Touring companion for Japan: JMA rain radar, road closures and seasonal
gates on a rider-centred map. Built in Flutter. Android works now, and the
iOS scaffold is in place for later.

Rindo is a companion to
[garmin-jma-radar](https://github.com/hebberd/garmin-jma-radar). It uses the
same JMA nowcast, but the phone fetches it directly with no proxy. The
device stacks JMA's transparent radar tiles over an OSM base map itself.

## Features

- **Rain radar** – JMA 高解像度降水ナウキャスト (high-resolution precipitation
  nowcast), from −15 min to +60 min in 15-minute frames. The animation is
  centred on the rider's GPS position over a CyclOSM cycling base map. The
  app pulls the radar tiles straight from JMA's undocumented nowcast
  endpoints. An empty or 404 tile simply means 'no rain there'. JMA renders
  these tiles only at even zoom levels up to z10, so the app fetches z10 and
  lets the map scale it as you zoom in closer. The result is blocky, and it
  matches JMA's roughly 250 m data, but it is always shown.
- **Scout another area** – long-press the map to drop a pin. Closures then
  load around the pin instead of around the GPS position, and distances are
  measured from the pin. A teal ring shows the searched radius, and pulses
  while the search runs. Tap the pin or the locate button to return to the
  rider.
- **Scout a planned ride (GPX)** – load a `.gpx` track with the route
  button. The track draws on the map, and the app searches for closures
  within a **10 km corridor of the route** (the union of the per-point
  searches). Everything on or near your planned ride is highlighted at once.
  Clear the track from the same button.
- **Road closures within 50 km** – full closures (通行止) from two sources,
  merged and de-duplicated. The app draws them as markers and red segment
  overlays. A detail sheet links to the authoritative source page.
  - **JARTIC** (`jartic.or.jp/map` internal GeoJSON) – nationwide, including
    the prefectural roads, updated every 5 minutes.
  - **MLIT 道路情報提供システム** (`road-info-prvs.mlit.go.jp`) – national
    highways (直轄国道), including winter closures (冬期通行止), with
    regulation periods.
- **English and Japanese toggle** (English by default) – English mode swaps
  the base map for Esri's English-labelled World Street Map. It also
  translates the closure text on the device with Google ML Kit. The Japanese
  and English models download once, about 30 MB each, then work offline.
  Japanese mode shows the sources word for word over CyclOSM. If a
  translation fails, the app falls back to the original Japanese.
- **Graceful loading and offline use** – base-map tiles pulse softly while
  they download. Beneath the tiles sits a baked-in outline of Japan and the
  prefecture borders, generated from GeoJSON by
  `tool/prep_japan_outline.dart`. A slow or dead connection therefore leaves
  a usable skeleton instead of a grey void. Tiles that *fail*, through
  server errors or timeouts, draw a visible broken-tile placeholder. Tap the
  placeholder to fetch it again, or tap the retry banner that counts the
  failed tiles. Failed tiles also retry when you press ↻, and automatically
  once the network returns. A separate offline banner covers socket-level
  outages.
- **Landslide alerts (土砂災害警戒情報)** – JMA issues these
  municipality-level landslide warnings jointly with the prefectures. The
  app shows them as amber markers at the municipality office inside the
  search area. The warnings usually come hours before the road closures
  themselves. After a large round of municipal mergers, regenerate the
  municipality coordinate table with `tool/prep_municipalities.dart`.
- **Weather report** – tap the rider dot, or a dropped pin, for JMA's area
  forecast for that spot. The radar says what the rain will do in the next
  hour. This says whether to set off at all. The sheet follows the layout of
  JMA's own page:
  - a near-term table, with an icon and the temperatures for each day, and
    the rain chance in fixed 00-06, 06-12, 12-18 and 18-24 blocks
  - the 週間予報 week-ahead table, with the weather, the rain chance, the
    high and low, and JMA's own A/B/C confidence grade
  - JMA's wording and prose outlook below the tables, and any warning
    headline on top

  Weather icons come from JMA's 3-digit 天気コード, bucketed by the leading
  digit (1 晴れ, 2 くもり, 3 雨, 4 雪). JMA publishes about 130 codes, but no
  machine-readable table for them. The icon is therefore coarse on purpose,
  and the wording beside it carries the detail.

  JMA keys its forecasts by area code, not by coordinates. The app resolves
  a position through the nearest municipality to its class10 subdivision
  (千葉県北東部, not just 'Chiba'). If JMA reorganises its forecast areas,
  regenerate that table with `tool/prep_forecast_areas.dart`.

  In English mode the report translates on the device, as the closures do.
  Place names are the exception. They use JMA's own English, such as
  'North-eastern Region' and 'Sapporo City', because machine translation is
  at its worst exactly where JMA is already authoritative. The Japanese
  shows immediately and the English swaps in behind it, so a first-run model
  download never blocks the forecast.
- **Seasonal winter gates** – a curated, bundled dataset of the annual
  mountain-pass closures (渋峠, 麦草峠, 金精峠, 乗鞍 …) with their nominal
  open and close dates. While a closure is *scheduled*, the app draws an
  indigo snowflake marker plus the whole closed road section, so you can
  plan a tour around it. `tool/fetch_gate_lines.dart` bakes that geometry
  from OSM. The live feeds confirm when a gate is actually closed.

The base map renders in **greyscale by default**, like JMA's own nowcast
page, so the radar and closure colours stand out. A palette button flips it
to full colour.

## Layout

- `lib/jma/jma_api.dart` – JMA targetTimes and tile client, ported from the
  proxy's `jma.js`. This is the only file to touch when JMA changes
  something.
- `lib/jma/jma_forecast.dart` – JMA area-forecast client behind the weather
  sheet, plus the generated table that maps a position to a forecast area
  (`forecast_areas.g.dart`)
- `lib/closures/` – closure model, JARTIC and MLIT sources, and the curated
  seasonal winter-gate dataset (`seasonal_gates.dart`, updated once a year
  from the prefecture notices) with baked OSM road geometry
  (`seasonal_gate_lines.g.dart`, generated). Also holds the merging
  repository and the generated table of prefecture bounding boxes and
  bureaux.
- `lib/map/japan_outline.g.dart` – generated prefecture-boundary skeleton,
  drawn beneath the tiles
- `lib/screens/radar_map_screen.dart` – the map screen's state and layer
  stack. Its widgets (frame controls, legend, closure sheets and styling,
  tile pulse) live in `lib/screens/radar_map/`.
- `test/` – unit tests. The files in `test/fixtures/` are real captured API
  responses.
- `tool/`
  - `run.sh` – boot the emulator (if needed), then `flutter run`
  - `deploy.sh` – build the release APK and install it on a USB-connected
    phone
  - `live_check.dart` – network smoke test:
    `dart run tool/live_check.dart 35.45 139.55`
  - `fetch_gate_lines.dart` – regenerate the seasonal-gate road geometry
    from OSM Overpass. Run it when you add a gate.
  - `prep_japan_outline.dart` – regenerate the prefecture skeleton from a
    prefectures GeoJSON. That file is not checked in, so pass its path.

## Setup

### 1. Install Android Studio (Linux)

Download the tarball from <https://developer.android.com/studio>. Extract
it, for example to `~/.android-studio`, then launch it:

```sh
tar -xzf android-studio-*-linux.tar.gz -C ~
mv ~/android-studio ~/.android-studio
~/.android-studio/bin/studio      # add ~/.android-studio/bin to PATH for `studio`
```

The first-run wizard installs the Android SDK to `~/Android/Sdk`. That
includes the platform tools, a platform, the build tools and the emulator.
Android Studio also bundles a JDK at `~/.android-studio/jbr`, so you do not
need a separate Java installation:

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

Use Android Studio: **Device Manager → Create Virtual Device**. Or use the
command line:

```sh
$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager \
  "system-images;android-35;google_apis;x86_64"
$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager create avd \
  -n tourtest -d pixel_7 -k "system-images;android-35;google_apis;x86_64"
```

### 4. Run the app in the emulator

The short way. It boots the AVD if needed, then runs the app with hot
reload:

```sh
tool/run.sh                       # env overrides: ANDROID_HOME, JAVA_HOME, FLUTTER, AVD
```

Or do it by hand:

```sh
$ANDROID_HOME/emulator/emulator -avd tourtest &   # or start it from Device Manager
flutter pub get
flutter run                       # picks up the running emulator
```

`flutter run` gives hot reload (`r`) and hot restart (`R`). The emulator's
default GPS position is Mountain View. To see radar and closures, set a
location in Japan in the emulator's **⋯ → Location** panel. For Yokohama,
use 35.45, 139.55.

#### The emulator has no network ('Failed host lookup' or 'Network is unreachable')

Symptom: everything that touches the network fails – the radar, the closures
and the translation-model download. You get `errno 7` (Failed host lookup)
or `errno 101` (Network is unreachable), while the *host* has working
internet.

This is **not** a DNS problem. The usual cause is a stale **quickboot
snapshot** that froze Android in a state with no default network. Inside the
guest, `dumpsys connectivity` shows `Active default network: none`. The
interface (`eth0`, 10.0.2.15) and its local route are present, but there is
no default route. Android's policy routing therefore sends every packet to
the null `dummy0` interface. Note that `-no-snapshot-save` still *loads*
such a snapshot, so the broken state returns on every boot.

`tool/run.sh` now boots with **`-no-snapshot`**, a clean cold boot every
time, plus `-dns-server 8.8.8.8,1.1.1.1`. That avoids the problem. If you
meet it on an emulator started another way:

```sh
# 1. delete the stale snapshot so boots start clean
rm -rf ~/.android/avd/tourtest.avd/snapshots/default_boot
# 2. cold boot
~/Android/Sdk/emulator/emulator -avd tourtest -no-snapshot -dns-server 8.8.8.8

# verify inside the guest - want "Active default network: 100" (not "none"):
adb shell dumpsys connectivity | grep 'Active default network'
adb shell ping -c1 8.8.8.8
```

One related trap: if `run.sh` reports *'Emulator did not appear in adb'* but
a qemu process is running, the adb server is stale. Run `adb kill-server &&
adb start-server`, then try again. On a host whose GPU driver forces
software rendering, cold boots are also slower and sometimes fail to launch.
Just retry.

### 5. Deploy to a real device

Set the phone up once. Go to **Settings → About phone** and tap **Build
number** seven times to unlock Developer options. Then turn on **Developer
options → USB debugging**. Plug the phone in over USB and accept the 'Allow
USB debugging?' prompt on its screen. `~/Android/Sdk/platform-tools/adb
devices` must now list the phone as `device`, not `unauthorized`.

Then:

```sh
tool/deploy.sh                    # builds the release APK, installs + launches it
```

If several devices are attached, pick one with `DEVICE=<serial>
tool/deploy.sh`. These release builds are signed with the debug key. That is
fine for a personal device, and you only need a real keystore for store
distribution. To develop with hot reload on the phone, use `flutter run`
instead. It targets a connected phone the same way it targets the emulator.

## Build

```sh
flutter pub get
flutter test
flutter build apk --debug   # or --release
```

## Release

Release builds are signed with the keystore configured in
`android/key.properties`, which is gitignored. If that file is absent, the
build falls back to the debug key, so `flutter run --release` works
anywhere. Set the keystore up once:

```sh
keytool -genkey -v -keystore ~/keystores/rindo-release.jks \
  -keyalg RSA -keysize 2048 -validity 10950 -alias rindo
# then fill in storeFile/storePassword/keyAlias/keyPassword in
# android/key.properties. Never commit the keystore or the passwords.
# If you lose the keystore, users must uninstall the app before they can
# ever upgrade.
```

For each release, bump `version:` in `pubspec.yaml`. The `+N` build number
must increase, or Android refuses the upgrade. Then run:

```sh
tool/release.sh
```

This produces three files:

- `build/release/rindo-<version>-arm64.apk` – the main download. It works on
  almost every modern phone.
- `rindo-<version>.apk` – a fat APK for any device.
- a `.sha256` file.

Attach them to a GitHub Release and link to them from the site. If you host
the APKs yourself instead, serve them with the MIME type
`application/vnd.android.package-archive`.

CI can do the whole release instead. Push a `v<version>` tag to run
`.github/workflows/release.yml`. It builds the same signed APKs and attaches
them to the GitHub Release. The tag must match the pubspec version. The
workflow needs two secrets in the `release` environment: `KEYSTORE_BASE64`
(`base64 -w0` of the keystore) and `KEYSTORE_PASSWORD`. `build-apk.yml`
remains the unsigned CI check for pushes and pull requests.

## Licence

The **code** in this repository is licensed under the
[PolyForm Noncommercial License 1.0.0](LICENSE). The source is open to read,
use, modify and share for **noncommercial purposes only**: personal use,
hobby projects, research and education. **Commercial use, including selling
the app or a derivative, is not permitted.** This also matches the terms of
the closure data sources. JARTIC in particular limits its data to private
use.

The licence covers the code only. Data fetched at runtime stays subject to
its providers' terms. The bundled and generated datasets listed below carry
their own upstream terms, and the code licence does not override them.

## Data terms

Fetched at runtime, and not redistributed by this repo:

- JMA data:
  [Public Data License v1.0](https://www.jma.go.jp/jma/en/copyright.html).
  JMA requires attribution and a 'processed' notice, both shown in the map
  credits. The app redisplays JMA's own published nowcast and area
  forecasts. It does not synthesise forecasts of its own, which the Weather
  Service Act regulates.
- CyclOSM tiles: hosted by OpenStreetMap France under fair use. The OSM data
  is © OpenStreetMap contributors (ODbL).
- Esri World Street Map tiles (English mode): the attribution is shown in
  the map credits. This is fine for light personal use. Check Esri's terms
  before you distribute anything.
- JARTIC: the terms limit the site and its data to private use, which is
  fine for a personal tool. **Do not distribute the app or its data for
  commercial purposes.** The code licence is noncommercial for the same
  reason. The endpoints are undocumented and may change.
- MLIT 道路情報提供システム: government content, attribution required.

Bundled in the repo. This is generated data, and the code licence does not
cover it:

- `lib/map/japan_outline.g.dart` – the prefecture boundary skeleton, derived
  from Global Map Japan (地球地図日本, © 国土地理院/GSI,
  <https://www.gsi.go.jp/kankyochiri/gm_jpn.html>) and obtained through
  [dataofjapan/land](https://github.com/dataofjapan/land). The distributor's
  terms ask you to credit the source. For commercial use, they also ask for
  a usage report to GSI.
- `lib/closures/seasonal_gate_lines.g.dart` – seasonal-gate road geometry
  extracted from OpenStreetMap through Overpass. © OpenStreetMap
  contributors, [ODbL](https://opendatacommons.org/licenses/odbl/).
- `lib/hazards/municipalities.g.dart` – municipality office coordinates from
  [code4fukui/localgovjp](https://github.com/code4fukui/localgovjp) (CC0).
  The upstream sources are GSI and J-LIS.
- `test/fixtures/` – two API responses captured on 13 July 2026 for the unit
  tests: `r13.json` (JARTIC closure GeoJSON) and `tuko83.json` (MLIT 通行止
  data). They remain the property of their services, and they are included
  only as test fixtures.
- The curated seasonal-gate list (`lib/closures/seasonal_gates.dart`) is
  hand-compiled from public prefecture road notices.
