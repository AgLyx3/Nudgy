# ThirdParty

Vendored dependencies, checked in rather than resolved from the network.

## LiteRT-LM

`LiteRT-LM/` is a local Swift package mirroring
[google-ai-edge/LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) at tag **v0.14.0**.
`Remli.xcodeproj` references it via `XCLocalSwiftPackageReference` (relative path
`ThirdParty/LiteRT-LM`), not as a remote package.

### What is here

- `Package.swift` — from the v0.14.0 tag, with one local change (below).
- `swift/` — the Swift wrapper sources (`Engine`, `Conversation`, `Message`, …), ~124 KB.
- `LICENSE` — Apache 2.0, from the same tag.

The `binaryTarget` is *not* vendored. It stays a URL pointing at the upstream GitHub release asset
(`CLiteRTLM.xcframework.zip`, 85 MB) with upstream's checksum. SwiftPM downloads and verifies it on
first resolve and caches it in DerivedData. So this directory stays small and the binary still comes
from Google, checksum-pinned.

### Local change 1: corrected binary checksum

**The v0.14.0 tag does not resolve as published.** Google re-uploaded
`CLiteRTLM.xcframework.zip` to the v0.14.0 release without retagging, so the checksum recorded in
that tag's `Package.swift` no longer matches the bytes the URL serves:

| Source | Checksum for the same v0.14.0 asset URL |
| --- | --- |
| `v0.14.0` tag | `4a4bdb0e…` — stale, resolution fails |
| `v0.15.0-alpha0` tag | `4a4bdb0e…` — same stale value |
| `main` | `dddac2f6…` |
| Bytes GitHub actually serves | `dddac2f6…` (SwiftPM-computed) |

This file uses `dddac2f6…`. That is not "whatever we happened to download" — it is the value
upstream publishes on `main` for this exact URL, independently agreeing with what SwiftPM computes
from the download. Anyone depending on the tag as-published hits
`checksum of downloaded artifact ... does not match checksum specified by the manifest`.

When bumping to a future tag, verify the tag's checksum against the served bytes before trusting it:

```sh
swift package compute-checksum <downloaded>.zip
```

### Local change 2: removed the macOS binary target

Upstream declares a second `binaryTarget`, `CLiteRTLM_mac` (44.6 MB), for the macOS slice, and makes
the wrapper depend on it under `.when(platforms: [.macOS])`. That target is **removed here.**

SwiftPM downloads every declared `binaryTarget` at resolve time regardless of its platform
condition, so an iOS-only app still pays for the macOS framework. On a slow connection that is
several minutes for something nothing links against. Remli has no macOS target.

Consequence: this package no longer builds for macOS. If a macOS target is ever added, restore the
`CLiteRTLM_mac` binaryTarget and its conditional dependency from the v0.14.0 tag.

### Why vendored instead of a remote package reference

Two reasons, both discovered the hard way:

1. **Clone size.** The repo carries the full C++ runtime and its history. A normal SwiftPM resolve
   clones it in full — the fetch passed 2.2 GB and was still going after an hour on a normal
   connection. The part Remli actually needs is the ~124 KB of Swift in `swift/`.

2. **`unsafeFlags`.** The `LiteRTLM` target declares
   `linkerSettings: [.unsafeFlags(["-Xlinker", "-all_load"])]`. SwiftPM refuses to build a
   *version-pinned remote* dependency that uses `unsafeFlags`. Local (path-based) packages are
   exempt. So even with unlimited bandwidth, the remote reference would likely have failed to
   build — vendoring locally is what makes the flag legal.

### Updating to a new upstream version

Tag-pinned, so bumping is deliberate:

```sh
TAG=v0.15.0
BASE=https://raw.githubusercontent.com/google-ai-edge/LiteRT-LM/$TAG
cd ios/ThirdParty/LiteRT-LM
curl -sfL "$BASE/Package.swift" -o Package.swift
curl -sfL "$BASE/LICENSE" -o LICENSE
# Re-list swift/ for the new tag — the file set changes between releases.
curl -s "https://api.github.com/repos/google-ai-edge/LiteRT-LM/git/trees/$TAG?recursive=1" \
  | grep -o '"path": "swift/[^"]*"' | sed 's/.*swift\///;s/"//'
# ...then curl each listed file into swift/.
```

Check `Package.swift` against the files you fetched before building. The tagged `Package.swift` and
the one on `main` diverge: `main` adds a `LiteRTLMFoundationModels` target at `swift/apple_fm`, a
path that does not exist at v0.14.0, and carries different binary checksums. Always take
`Package.swift` from the *same tag* as the sources.
