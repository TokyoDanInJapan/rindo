# Working on this repo

Notes for Claude Code that the code and the README do not make obvious.

## `gh pr edit` silently fails on this repo

`gh pr edit <n> --body ...` (and `--title`) **does not apply the change**. It
fails inside GitHub's GraphQL layer:

```
GraphQL: Projects (classic) is being deprecated in favor of the new Projects
experience ... (repository.pullRequest.projectCards)
```

`gh` asks for `projectCards` in the same query it uses to edit a pull
request, so the deprecation error aborts the whole mutation. `gh` leaves the
pull request untouched, but the command still looks like it mostly worked.
The error mentions Projects, not the edit, so it reads as a warning about
something you did not ask for.

Use the REST API instead. It does not touch Projects:

```bash
gh api -X PATCH repos/TokyoDanInJapan/rindo/pulls/<n> -F body=@body.md
gh api -X PATCH repos/TokyoDanInJapan/rindo/pulls/<n> -f title='...'
```

`-F key=@file` reads the value from a file. This also avoids a fight with
the shell over backticks and quotes in a long description.

**Verify after you write**, whichever route you take. Neither route reports
failure in a way you would notice while skimming:

```bash
gh pr view <n> --json body --jq '.body | contains("some phrase you just wrote")'
```

Creating a pull request is unaffected – `gh pr create --body-file ...` works
normally. Only the edit of an existing pull request fails.

## Releasing: bump `pubspec.yaml` *before* you tag

`.github/workflows/release.yml` refuses a `v*` tag whose version does not
match `pubspec.yaml`:

```
Tag v0.1.1 != pubspec version 0.1.0 - bump pubspec.yaml
```

That check is there for a good reason. The APK announces the pubspec version
whatever the tag says, so a mismatch ships a build that lies about which
release it is. But the check fails *after* the tag exists. You must then
delete the wrong tag, locally and remotely, before you can retry.

So use this order:

1. Bump `version:` in `pubspec.yaml`. Change both parts – `0.1.1+2`. The
   `+N` build number must increase before Android accepts the upgrade.
2. Commit the change to `main`.
3. Tag `v0.1.1` and push the tag.

A `v*` tag triggers only **Release**. It runs the analyser and the tests,
builds the signed APKs with `tool/release.sh` and attaches them to a GitHub
Release. **Build APK** runs on pushes to `main` and on pull requests, and
produces a debug-signed artifact only. Release needs `KEYSTORE_BASE64` and
`KEYSTORE_PASSWORD` in the repo's `release` *environment*. Repo secrets do
not work – they resolve to empty strings.

## No compositing layers inside the map

Do not wrap anything inside `FlutterMap` in `Opacity` (other than 0 or 1),
`ColorFiltered`, `FadeTransition`, `ShaderMask` or `BackdropFilter`. Draw
the effect with paint instead: a colour on the paint, a colour matrix on an
image paint, or `TileDisplay` opacity for tiles.

Each of those widgets is an offscreen texture at full screen resolution,
and a rotated or zoomed-out map repeats them per tile. On a Pixel 10
(PowerVR GPU), Impeller's Vulkan backend runs out of image memory
(`VK_ERROR_COMPRESSION_EXHAUSTED_EXT`) and then aborts the app on the next
nested layer:

```
[FATAL:flutter/impeller/display_list/canvas.cc(1471)] Check failed: back_texture
```

0.1.5 crashed this way on zoom and rotation. The emulator renders with
OpenGL ES and never shows it. The `offscreen layers` test in
`test/widgets_test.dart` fails if a layer comes back.
