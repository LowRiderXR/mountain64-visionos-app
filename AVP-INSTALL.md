# Installing Mountain 64 on Apple Vision Pro

Mountain 64 is an unofficial, free fan port of Celeste 64: Fragments of the Mountain to Apple Vision Pro, built on the game's official source release with Foster and SDL3 forks for visionOS. It is not made or endorsed by the Celeste team.

The easiest way to play is the App Store release: <https://apps.apple.com/app/id6832320956>. Beta builds are on TestFlight: <https://testflight.apple.com/join/bGjuRjfg>. The steps below build it from source.

## Requirements

- A Mac with Xcode 27 or later, with the visionOS platform installed
- Apple Vision Pro on visionOS 27 or later
- An Apple ID (a free developer account works; sideloaded apps then need re-signing every 7 days)
- The .NET SDK 10.0.4xx (<https://dotnet.microsoft.com/download/dotnet/10.0>)
- A free fmod.com account, for the FMOD Engine 2.02.35
- A game controller (Xbox, PlayStation or another extended gamepad)

## Game files

You don't supply any. Celeste 64 was released with its source and content, and `setup.sh` clones it from <https://github.com/EXOK/Celeste64> at a pinned commit. This repository contains no game content.

## Build

Start from a checkout of this repository. (The AVP Ports Index gives players a command that clones this repo at the exact commit it scanned, with submodules, so these steps should work from any existing checkout.)

1. Make sure Xcode has the visionOS platform (Xcode > Settings > Components) and is the selected Xcode:

       sudo xcode-select -s /Applications/Xcode.app

2. Get the FMOD Engine yourself: sign in on <https://www.fmod.com>, download "FMOD Engine" 2.02.35 for Apple platforms, and copy its `FMOD Programmers API` folder to `ThirdParty/fmod-2.02.35/`, so that `ThirdParty/fmod-2.02.35/FMOD Programmers API/api` exists. (Or point `FMOD_API_DIR` at the package's `api` folder.) Never commit it.
3. Run the setup script from the repository root:

       ./setup.sh

   It checks Xcode and .NET, clones Celeste 64 (EXOK/Celeste64), LowRiderXR/foster-visionos and LowRiderXR/sdl-visionos at pinned commits into `Source/`, applies `Patches/celeste64-usefoster.patch`, and builds the FMOD, SDL3 and game frameworks into `Frameworks/`. If FMOD is missing, it stops after cloning and says what to do.
4. Open `AvpCeleste64.xcodeproj`.
5. Select the **AvpCeleste64** target. Under Signing & Capabilities, choose your team and change the bundle identifier to one of your own.

## Install on Apple Vision Pro

1. Pair the headset with Xcode, if you haven't already (on the headset: Settings > General > Remote Devices; in Xcode: Window > Devices and Simulators).
2. Select the scheme **AvpCeleste64** and your Vision Pro as the destination, then Run. The app appears as "Mountain 64".
3. On first launch with a free account, trust your developer profile on the headset in Settings > General > VPN & Device Management.

## Controls and known issues

- Play with a connected game controller; the game world surrounds you in a full immersive space, and the camera follows Madeline and turns with the controller.
- After changing code, rebuild one framework with `scripts/build-fmod.sh`, `scripts/build-sdl3.sh` or `scripts/build-game.sh`, or all three with `./setup.sh --rebuild`.
- If you distribute a build, register your project on fmod.com as the FMOD license requires, and keep the FMOD credit line.
- Report problems in this repository's issues.
