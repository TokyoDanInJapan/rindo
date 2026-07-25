# Working on this repo

Notes for Claude Code that aren't obvious from the code or the README.

## `gh pr edit` silently fails on this repo

`gh pr edit <n> --body ...` (and `--title`) **does not apply the change**. It
fails inside GitHub's GraphQL layer:

```
GraphQL: Projects (classic) is being deprecated in favor of the new Projects
experience ... (repository.pullRequest.projectCards)
```

`gh` asks for `projectCards` as part of the same query it uses to edit a PR, so
the deprecation error aborts the whole mutation. The PR is left untouched while
the command looks like it mostly worked — the error mentions Projects, not the
edit, so it reads as a warning about something you didn't ask for.

Use the REST API instead, which doesn't touch Projects:

```bash
gh api -X PATCH repos/TokyoDanInJapan/rindo/pulls/<n> -F body=@body.md
gh api -X PATCH repos/TokyoDanInJapan/rindo/pulls/<n> -f title='...'
```

`-F key=@file` reads the value from a file, which also avoids fighting the
shell over backticks and quotes in a long description.

**Verify after writing**, whichever route you take — neither reports failure in
a way you'd notice while skimming:

```bash
gh pr view <n> --json body --jq '.body | contains("some phrase you just wrote")'
```

Creating a PR is unaffected: `gh pr create --body-file ...` works normally. It's
only editing an existing one.

## Releasing: bump `pubspec.yaml` *before* tagging

`.github/workflows/release.yml` refuses a `v*` tag whose version doesn't match
`pubspec.yaml`:

```
Tag v0.1.1 != pubspec version 0.1.0 - bump pubspec.yaml
```

That check is there for a good reason — the APK announces the pubspec version
whatever the tag says, so a mismatch ships a build that lies about which release
it is. But it fails *after* the tag exists, which means a wrong tag has to be
deleted locally and remotely before you can retry.

So the order is:

1. bump `version:` in `pubspec.yaml` (both parts — `0.1.1+2`; the `+N` build
   number must increase for Android to accept the upgrade)
2. commit it to `main`
3. tag `v0.1.1` and push the tag

A `v*` tag triggers two workflows: **Build APK** (debug-signed, artifact only)
and **Release**, which builds the signed APKs via `tool/release.sh` and attaches
them to a GitHub Release. Release needs `KEYSTORE_BASE64` and
`KEYSTORE_PASSWORD` in the repo's `release` *environment* — not repo secrets, or
they resolve to empty strings.
