# Rindo

[![Build APK](https://github.com/TokyoDanInJapan/rindo/actions/workflows/build-apk.yml/badge.svg)](https://github.com/TokyoDanInJapan/rindo/actions/workflows/build-apk.yml)

Rindo is a touring companion for Japan. It shows JMA rain radar, road
closures and seasonal gates on a map centred on the rider. The app is
built in Flutter. Android works now, and the iOS scaffold is in place for
later.

Rindo is a companion to
[garmin-jma-radar](https://github.com/hebberd/garmin-jma-radar). It uses the
same JMA nowcast, but the phone fetches it directly with no proxy. The phone
itself stacks JMA's transparent radar tiles over an OSM base map.

## Features

- **Rain radar:** JMA 高解像度降水ナウキャスト (high-resolution precipitation
  nowcast), from −15 min to +60 min in 15-minute frames. The animation plays
  over a CyclOSM cycling base map, centred on the rider's GPS position. The
  app pulls the radar tiles straight from JMA's undocumented nowcast
  endpoints. An empty tile or a 404 means 'no rain there'. JMA renders these
  tiles only at even zoom levels up to z10. The app therefore fetches z10 and
  lets the map scale the tiles when you zoom in further. The result is
  blocky, which matches JMA's data resolution of about 250 m, but the radar
  stays visible at every zoom level.
- **Scout another area:** long-press the map to drop a pin. Closures then
  load around the pin instead of around the GPS position, and the app
  measures distances from the pin. A teal ring shows the search radius and
  pulses while the search runs. To return to the rider, tap the pin or the
  locate button.
- **Scout a planned ride (GPX):** load a `.gpx` track with the route button.
  The app draws the track on the map and searches for closures within a
  **10 km corridor of the route**. The corridor is the union of the searches
  around each point of the track. The map highlights everything on or near
  your planned ride at once. To clear the track, use the same button.
- **Road closures within 50 km:** full closures (通行止) from two sources.
  The app merges the two lists and removes duplicates. It draws each closure
  as a marker and a red road overlay. A detail sheet links to the authoritative
  source page.
  - **JARTIC** (`jartic.or.jp/map` internal GeoJSON): nationwide, including
    the prefectural roads. JARTIC updates the data every 5 minutes.
  - **MLIT 道路情報提供システム** (`road-info-prvs.mlit.go.jp`): national
    highways (直轄国道), including winter closures (冬期通行止), with the
    regulation periods.
- **English and Japanese modes:** English is the default. English mode
  replaces the base map with Esri's World Street Map, which has English
  labels. It also translates the closure text on the device with Google ML
  Kit. The Japanese and English models download once, about 30 MB each, and
  then work offline. Japanese mode shows the original source text over
  CyclOSM. If a translation fails, the app shows the original Japanese.
- **Slow networks and offline use:** base-map tiles pulse softly while they
  download. A built-in outline of Japan and its prefecture borders sits
  beneath the tiles. `tool/prep_japan_outline.dart` generates this outline
  from GeoJSON. A slow or dead connection therefore leaves a usable map
  skeleton instead of a grey void.

  A tile that *fails* (because of a server error or a timeout) shows a
  broken-tile placeholder. To fetch the tile again, tap the placeholder, or
  tap the retry banner that counts the failed tiles. Failed tiles also retry
  when you press ↻, and automatically when the network returns. A separate
  offline banner covers a complete loss of connection.
- **Landslide alerts (土砂災害警戒情報):** JMA and the prefectures issue these
  warnings jointly, for each municipality. The app shows each warning as an
  amber marker at the municipal office, if the office is inside the search
  area. A warning usually comes hours before the road closures. After a
  large round of municipal mergers, regenerate the table of municipality
  coordinates with `tool/prep_municipalities.dart`.
- **Weather report:** tap the rider dot, or a dropped pin, to see JMA's area
  forecast for that spot. The radar tells you what the rain will do in the
  next hour. The forecast tells you whether to set off at all. The sheet
  follows the layout of JMA's own page:
  - a near-term table, with an icon and the temperatures for each day, and
    the rain chance in fixed 00–06, 06–12, 12–18 and 18–24 blocks
  - the 週間予報 week-ahead table, with the weather, the rain chance, the
    high and low, and JMA's own A/B/C confidence grade
  - JMA's description of the weather and its written outlook below the
    tables, and any warning headline at the top

  The weather icons come from JMA's 3-digit 天気コード. The app groups the
  codes by their first digit (1 晴れ, 2 くもり, 3 雨, 4 雪). JMA publishes
  about 130 codes, but no machine-readable table for them. The icon is
  therefore coarse on purpose, and the text beside it carries the detail.

  JMA keys its forecasts by area code. To find the area for a position, the
  app takes the nearest municipality and looks up its class10 subdivision.
  A subdivision is narrower than a prefecture, for example 千葉県北東部
  (north-east Chiba). If JMA reorganises its forecast areas, regenerate
  that table with `tool/prep_forecast_areas.dart`.

  In English mode, the app translates the report on the device, as it does
  the closures. Place names are the exception. They use JMA's own English,
  such as 'North-eastern Region' and 'Sapporo City', because machine
  translation is at its worst exactly where JMA is already authoritative.
  The Japanese text shows immediately and the English replaces it when it is
  ready. A first-run model download therefore never blocks the forecast.
- **Seasonal winter gates:** a curated, bundled dataset of the annual
  closures of mountain passes, such as 渋峠, 麦草峠, 金精峠 and 乗鞍. Each
  entry has the nominal dates when the gate closes and opens. While a
  closure is *scheduled*, the app draws an indigo snowflake marker and the
  whole closed section of road. You can then plan a tour around it.
  `tool/fetch_gate_lines.dart` builds that road geometry from OSM. The live
  feeds confirm when a gate is actually closed.

The base map is **greyscale by default**, like JMA's own nowcast page, so
that the radar and closure colours stand out. The palette button switches
the map to full colour.

## Layout

- `lib/jma/`
  - `jma_api.dart`: the JMA client for nowcast times and radar tiles, ported
    from the proxy's `jma.js`. When JMA changes something, this is the only
    file to change.
  - `jma_forecast.dart`: the JMA area-forecast client for the weather sheet.
  - `forecast_areas.g.dart`: the generated table that maps a municipality to
    a forecast area.
- `lib/closures/`: the closure model, the JARTIC and MLIT sources, and the
  repository that merges them. It also holds:
  - `seasonal_gates.dart`: the curated dataset of seasonal winter gates,
    updated once a year from the prefecture notices.
  - `seasonal_gate_lines.g.dart`: the generated OSM road geometry for the
    gates.
  - `prefectures.dart`: the generated table of prefecture bounding boxes,
    with the JARTIC and MLIT codes for each prefecture.
- `lib/hazards/`: the JMA landslide-alert source, and the generated table of
  municipality coordinates (`municipalities.g.dart`).
- `lib/map/japan_outline.g.dart`: the generated outline of the prefecture
  borders, drawn beneath the tiles.
- `lib/net/`: the tile HTTP client, the offline detection and the tracking
  of failed tiles.
- `lib/route/gpx_route.dart`: GPX parsing and the route corridor.
- `lib/translate/`: on-device translation of the closures and the weather
  report.
- `lib/screens/radar_map_screen.dart`: the state and layer stack of the map
  screen. Its widgets (frame controls, legend, closure and weather sheets,
  banners, tile pulse) are in `lib/screens/radar_map/`.
- `test/`: unit tests. The files in `test/fixtures/` are real captured API
  responses.
- `tool/`
  - `run.sh`: starts the emulator if necessary, then runs `flutter run`.
  - `deploy.sh`: builds the release APK and installs it on a phone that is
    connected by USB.
  - `release.sh`: builds the release APKs for distribution. See
    [Release](#release).
  - `live_check.dart`: a network smoke test. Run
    `dart run tool/live_check.dart 35.45 139.55`.
  - `fetch_gate_lines.dart`: regenerates the road geometry of the seasonal
    gates from OSM Overpass. Run it when you add a gate.
  - `prep_japan_outline.dart`: regenerates the prefecture outline from a
    prefectures GeoJSON file. That file is not in the repository, so give
    its path as an argument.
  - `prep_municipalities.dart` and `prep_forecast_areas.dart`: regenerate
    the municipality and forecast-area tables.
  - `thin.dart`: point thinning, shared by the geometry scripts.

## Setup

### 1. Install Android Studio (Linux)

1. Download the tarball from <https://developer.android.com/studio>.
2. Extract it to `~/.android-studio`, or to another folder.
3. Start Android Studio:

```sh
tar -xzf android-studio-*-linux.tar.gz -C ~
mv ~/android-studio ~/.android-studio
~/.android-studio/bin/studio      # add ~/.android-studio/bin to PATH for `studio`
```

The first-run wizard installs the Android SDK to `~/Android/Sdk`. The SDK
includes the platform tools, a platform, the build tools and the emulator.
Android Studio also includes a JDK at `~/.android-studio/jbr`, so you do not
need a separate Java installation. Set these two variables:

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

In Android Studio, open **Device Manager → Create Virtual Device**. Or use
the command line:

```sh
$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager \
  "system-images;android-35;google_apis;x86_64"
$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager create avd \
  -n tourtest -d pixel_7 -k "system-images;android-35;google_apis;x86_64"
```

### 4. Run the app in the emulator

`tool/run.sh` is the quick way. It starts the AVD if necessary, then runs
the app with hot reload:

```sh
tool/run.sh                       # env overrides: ANDROID_HOME, JAVA_HOME, FLUTTER, AVD
```

To do the same steps by hand:

```sh
$ANDROID_HOME/emulator/emulator -avd tourtest &   # or start it from Device Manager
flutter pub get
flutter run                       # picks up the running emulator
```

In `flutter run`, press `r` for hot reload and `R` for hot restart. The
emulator's default GPS position is Mountain View. To see the radar and the
closures, set a location in Japan in the emulator's **⋯ → Location** panel.
For Yokohama, use 35.45, 139.55.

#### The emulator has no network ('Failed host lookup' or 'Network is unreachable')

Everything that uses the network fails, including the radar, the closures
and the download of the translation models. You get `errno 7` (Failed host
lookup) or `errno 101` (Network is unreachable), but the *host* has a
working internet connection.

The usual cause is a stale **quickboot snapshot**, even though the error
looks like a DNS problem. The snapshot froze Android in a state with no
default network. Inside the guest, `dumpsys connectivity` shows
`Active default network: none`. The interface (`eth0`, 10.0.2.15) and its
local route are present, but there is no default route. Android's policy
routing therefore sends every packet to the null `dummy0` interface. The
`-no-snapshot-save` option still *loads* such a snapshot, so the broken
state returns on every boot.

`tool/run.sh` avoids the problem. It starts the emulator with
**`-no-snapshot`**, which gives a clean cold boot every time, and with
`-dns-server 8.8.8.8,1.1.1.1`. If you start the emulator another way and
the problem occurs, delete the snapshot and do a cold boot:

```sh
# 1. delete the stale snapshot so that boots start clean
rm -rf ~/.android/avd/tourtest.avd/snapshots/default_boot
# 2. cold boot
~/Android/Sdk/emulator/emulator -avd tourtest -no-snapshot -dns-server 8.8.8.8

# check inside the guest. Expect "Active default network: 100", not "none".
adb shell dumpsys connectivity | grep 'Active default network'
adb shell ping -c1 8.8.8.8
```

If `run.sh` reports *'Emulator did not appear in adb'* but a qemu process is
running, the adb server is stale. Run
`adb kill-server && adb start-server`, then try again. If the GPU driver on
the host forces software rendering, cold boots are slower and sometimes fail
to start. In that case, try again.

### 5. Deploy to a real device

Prepare the phone once:

1. Go to **Settings → About phone**.
2. Tap **Build number** seven times to unlock the developer options.
3. Turn on **Developer options → USB debugging**.
4. Connect the phone with a USB cable.
5. On the phone, accept the 'Allow USB debugging?' prompt.
6. Run `~/Android/Sdk/platform-tools/adb devices`. Make sure that the list
   shows the phone as `device`, not as `unauthorized`.

Then build and install the app:

```sh
tool/deploy.sh                    # builds the release APK, installs + launches it
```

If more than one device is connected, choose one with
`DEVICE=<serial> tool/deploy.sh`. The build uses your release keystore if
`android/key.properties` exists, and the debug key if it does not. The debug
key is fine for a personal device. To develop with hot reload on the phone,
use `flutter run` instead. It finds a connected phone in the same way that
it finds the emulator.

## Build

```sh
flutter pub get
flutter test
flutter build apk --debug   # or --release
```

## Release

Release builds use the keystore that `android/key.properties` configures.
Git ignores that file. If the file does not exist, the build uses the debug
key, so `flutter run --release` works anywhere. Create the keystore once:

```sh
keytool -genkey -v -keystore ~/keystores/rindo-release.jks \
  -keyalg RSA -keysize 2048 -validity 10950 -alias rindo
# Then fill in storeFile, storePassword, keyAlias and keyPassword in
# android/key.properties. Never commit the keystore or the passwords.
# If you lose the keystore, users must uninstall the app before they can
# upgrade to a new release.
```

For each release, increase `version:` in `pubspec.yaml`. Increase the `+N`
build number too, or Android refuses the upgrade. Then run:

```sh
tool/release.sh
```

The script writes three files to `build/release/`:

- `rindo-<version>-arm64.apk`: the main download. It works on almost every
  modern phone.
- `rindo-<version>.apk`: a universal APK, which contains the native code for
  every CPU type. Use it for a device that cannot install the arm64 APK.
- a `.sha256` file with the checksums.

Attach the files to a GitHub Release and link to them from the website. If
you host the APKs on your own server, serve them with the MIME type
`application/vnd.android.package-archive`.

CI can also do the whole release. Push a `v<version>` tag to run
`.github/workflows/release.yml`, which builds the same signed APKs and
attaches them to a GitHub Release. The tag must match the version in
`pubspec.yaml`, so commit the version change before you push the tag. The
workflow needs two secrets in the `release` environment:

- `KEYSTORE_BASE64`: the output of `base64 -w0` for the keystore
- `KEYSTORE_PASSWORD`

`build-apk.yml` is the CI check for pushes and pull requests. It signs its
build with the debug key.

## Licence

The **code** in this repository is licensed under the
[PolyForm Noncommercial License 1.0.0](LICENSE). You may read, use, change
and share the source for **non-commercial purposes only**, such as personal
use, hobby projects, research and education. **Commercial use, including
selling the app or a derivative, is not permitted.** This also matches the
terms of the closure data sources. JARTIC in particular limits its data to
private use.

The licence covers the code only. Data that the app fetches at runtime
stays subject to the terms of its provider. The bundled datasets listed
below have their own upstream terms, and the code licence does not override
them.

## Data terms

The app fetches this data at runtime. The repository does not redistribute
it.

- **JMA data:**
  [Public Data License v1.0](https://www.jma.go.jp/jma/en/copyright.html).
  JMA requires attribution and a 'processed' notice. The map credits show
  both. The app shows the nowcast and area forecasts that JMA publishes. It
  does not make forecasts of its own, which the Weather Service Act
  regulates.
- **CyclOSM tiles:** hosted by OpenStreetMap France under fair use. The OSM
  data is © OpenStreetMap contributors (ODbL).
- **Esri World Street Map tiles (English mode):** the map credits show the
  attribution. Light personal use is fine. Check Esri's terms before you
  distribute anything.
- **JARTIC:** the terms limit the site and its data to private use, which is
  fine for a personal tool. **Do not distribute the app or its data for
  commercial purposes.** The code licence is non-commercial for the same
  reason. The endpoints are undocumented and can change.
- **MLIT 道路情報提供システム:** government content. Attribution is
  required.

These files are in the repository, but the code licence does not cover
them:

- `lib/map/japan_outline.g.dart`: the prefecture outline. It comes from
  Global Map Japan (地球地図日本, © 国土地理院/GSI,
  <https://www.gsi.go.jp/kankyochiri/gm_jpn.html>), through
  [dataofjapan/land](https://github.com/dataofjapan/land). The distributor's
  terms ask you to credit the source. For commercial use, they also ask you
  to send a usage report to GSI.
- `lib/closures/seasonal_gate_lines.g.dart`: the road geometry of the
  seasonal gates, extracted from OpenStreetMap through Overpass.
  © OpenStreetMap contributors,
  [ODbL](https://opendatacommons.org/licenses/odbl/).
- `lib/hazards/municipalities.g.dart`: the coordinates of municipal offices,
  from [code4fukui/localgovjp](https://github.com/code4fukui/localgovjp)
  (CC0). The upstream sources are GSI and J-LIS.
- `test/fixtures/`: two API responses, captured on 13 July 2026 for the unit
  tests. `r13.json` is JARTIC closure GeoJSON and `tuko83.json` is MLIT 通行止
  data. They remain the property of their services, and they are in the
  repository only as test fixtures.
- `lib/closures/seasonal_gates.dart`: the curated list of seasonal gates,
  compiled by hand from public prefecture road notices.
