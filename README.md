# Mountain 64 for Apple Vision Pro

An unofficial fan port of **Celeste 64: Fragments of the Mountain** to Apple Vision Pro:
the game world rendered in stereo in a full immersive space, head tracking, and
game-controller input.

Celeste 64 was made by the Celeste team (Maddy Makes Games, Inc.) for Celeste's sixth
anniversary and released with its source code. This port is **not made or endorsed by the
Celeste team**. It is free and non-commercial.

## Play

- TestFlight: <https://testflight.apple.com/join/bGjuRjfg> (requires Apple Vision Pro and the TestFlight app)
- App Store: coming soon

## Requirements

- Apple Vision Pro with visionOS 27 or newer
- A game controller (Xbox, PlayStation or another extended gamepad)

## Build from source

To play, use the TestFlight link above (App Store coming soon); building from source is only
needed for development.

A Mac with Xcode 27 (with the visionOS platform installed) and the .NET SDK 10.0.4xx.

1. Clone this repository:

       git clone https://github.com/LowRiderXR/mountain64-visionos-app.git AvpCeleste64
       cd AvpCeleste64

2. Get the FMOD Engine yourself. Create an account on [fmod.com](https://www.fmod.com),
   download "FMOD Engine" for Apple platforms (version 2.02.35, FMOD license), and copy its
   `FMOD Programmers API` folder to `ThirdParty/fmod-2.02.35/` (git-ignored), or point
   `FMOD_API_DIR` at the package's `api` directory. If you distribute a build, register your
   project on fmod.com as the FMOD license requires.

3. Run the setup script:

       ./setup.sh

   It checks Xcode and .NET, clones Celeste 64 and the two forks (Foster, SDL3) at pinned
   commits into `Source/` (git-ignored), applies the port's patch to Celeste 64 and builds the
   three frameworks into `Frameworks/`. Without the FMOD package it stops after cloning and
   tells you what to do.

4. Open `AvpCeleste64.xcodeproj`. Under Signing & Capabilities choose your team and change
   the bundle identifier to one of your own. Select the scheme **AvpCeleste64** and your
   Vision Pro, then Run. The app appears as "Mountain 64".

After changes, rebuild a single framework with the scripts under `scripts/`:
`build-fmod.sh`, `build-sdl3.sh`, `build-game.sh` (or `./setup.sh --rebuild` for all three).

## FMOD

The FMOD Engine is licensed by Firelight Technologies and must never be committed to this
repository: no SDK files, no built `FMOD.framework`. Every build must keep the credit line
"Audio: FMOD Studio by Firelight Technologies Pty Ltd." on the title screen and in
`AvpCeleste64/Acknowledgements.txt`.

## For developers

The repository holds only the visionOS host, the wrapper, the SDL GPU kit, the Mac tools and
the scripts. Celeste 64 is changed exclusively through `Patches/celeste64-usefoster.patch`
(`scripts/celeste-patch.sh apply|revert|status`); the forks live in their own repositories.
`setup.sh` pins all three sources to fixed commits. Layout after setup:

```
AvpCeleste64/
  AvpCeleste64/              host app (SwiftUI, CompositorServices, Metal)
  Wrapper/Celeste64.VisionOS native wrapper around the game (C# Native AOT, celeste_* exports)
  Kit/sdl-gpu-kit            SDL GPU multiview helpers (C, Metal)
  Tools/Celeste64.MacHost    Mac host that drives the game for measurements and dumps
  Patches/                   the Celeste 64 patch
  scripts/                   build and check scripts
  Source/Celeste64           EXOK/Celeste64 at the pinned commit (git-ignored)
  Source/foster-visionos     Foster fork, branch visionos (git-ignored)
  Source/sdl-visionos        SDL3 fork, branch visionos-kit (git-ignored)
  ThirdParty/fmod-2.02.35    your FMOD package (git-ignored)
  Frameworks/                build output, embedded by the Xcode project (git-ignored)
```

`scripts/celeste-mac.sh ref|machost` builds the original game and the Mac host for comparing
images and timings on the Mac. The Mac host and `scripts/build-game.sh mac-check` need the
macOS SDL3 library, which `setup.sh` does not build: run `scripts/build-sdl3.sh macos` once
(needs cmake); it writes `Frameworks/macos/libSDL3.0.dylib`. Working rules for contributors
and AI agents are in `CLAUDE.md`.

| Repository | Content | License |
|---|---|---|
| [mountain64-visionos-app](https://github.com/LowRiderXR/mountain64-visionos-app) | this app: host, wrapper, kit, tools, patch, scripts | MIT (own code) |
| [foster-visionos](https://github.com/LowRiderXR/foster-visionos) | Foster framework with the visionOS changes | MIT |
| [sdl-visionos](https://github.com/LowRiderXR/sdl-visionos) | SDL3 with the visionOS GPU changes | zlib |
| [Celeste64](https://github.com/EXOK/Celeste64) | the game (upstream, not forked) | source MIT, content owned by Maddy Makes Games |

## Disclaimer

This project is provided "as is", without warranty of any kind. Use it at your own risk. The
author is not liable for any damage, data loss or other issues arising from building,
installing or using it.

## License

The code written for this repository is MIT-licensed (`LICENSE`). Celeste 64's source code is
MIT-licensed; the Celeste IP and everything in its `Content` folder are owned by Maddy Makes
Games, Inc. and are used under the permission its ReadMe gives to non-commercial fan games
("as long as it's clear it is not made by the Celeste team or endorsed by us"). The game
content is not part of this repository; `setup.sh` clones it from the upstream repository.
Foster is MIT, SDL3 is zlib, the .NET runtime is MIT, the FMOD Engine has its own EULA. The
full texts are in `AvpCeleste64/Acknowledgements.txt`, which ships inside the app. Privacy:
`PRIVACY.md`.

## Acknowledgements

Thanks to the Celeste team at Maddy Makes Games and EXOK for releasing Celeste 64 with its
source, to Noel Berry for Foster, and to the SDL project. Large parts of this port were
written with the help of AI coding agents, reviewed and tested by the maintainer.
