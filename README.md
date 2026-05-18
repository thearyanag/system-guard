# System Guard

System Guard is a macOS menu bar app that watches for memory pressure before it turns into a machine-wide slowdown.

It is designed for developer workstations running browsers, Docker, local servers, and automation tools. The app stays in the menu bar, warns early, and only offers cleanup actions with explicit confirmation.

## What It Watches

- free memory from `memory_pressure`
- compressor and available pages from `vm_stat`
- swap size and swapfile count
- top processes by resident memory
- Docker, browser automation, and local developer process groups
- stale browser automation processes such as Chrome for Testing, chromedriver, and headless Chromium

## Safety

System Guard is warning-first.

- It does not automatically kill generic development processes.
- Stale cleanup targets only automation-shaped browser processes.
- Destructive actions require confirmation.
- Force Kill shows the exact PID, process name, memory use, and age before sending `SIGKILL`.
- Quit Docker warns before asking Docker Desktop to quit.

## Install

Download the latest DMG from GitHub Releases, open it, and drag System Guard into `/Applications`.

Launch at login is controlled inside the app:

```text
Settings -> Monitoring -> Launch at Login
```

System Guard uses the macOS app-native login item API instead of installing a LaunchAgent.

## Alerts

Use the menu actions to configure notifications:

- `Allow Alerts` requests notification permission.
- `Open Alerts` opens macOS Notification Settings if permission was denied.
- `Test Alert` sends a test notification when alerts are allowed.

## Build From Source

```sh
./scripts/build-app.sh
open "build/System Guard.app"
```

Run the collector without opening the UI:

```sh
"build/System Guard.app/Contents/MacOS/SystemGuard" --snapshot
```

Run parser and classification self-tests:

```sh
"build/System Guard.app/Contents/MacOS/SystemGuard" --self-test
```

## Uninstall

```sh
./scripts/uninstall.sh
```

The uninstall script unregisters the app-native login item before removing the app bundle.
