# Hostig

`Hostig` is a SwiftUI macOS app that:

- discovers `_ssh._tcp` Bonjour services on the local network
- lets you add and remove non-Bonjour hosts from an editable host list
- pings every discovered host and shows latency plus packet loss
- attempts non-interactive SSH login using your existing `~/.ssh/config` and SSH agent
- fetches remote uptime, load average, CPU, disk, memory, and logged-in user count for hosts where SSH succeeds
- allows rebooting authenticated hosts via `sudo reboot`, prompting for a remote sudo password only when required

## Run

```bash
xcodebuild -project Hostig.xcodeproj -scheme Hostig -destination 'platform=macOS' build
```

Open the generated app bundle from DerivedData, or run the `Hostig` scheme directly in Xcode.

## Project Layout

- `Hostig.xcodeproj` is the app project.
- `App/HostigMac` contains the macOS SwiftUI/AppKit shell and assets.
- `Packages/HostigCore` contains local Swift packages for reusable logic.
- `HostigModels` has the shared Codable host, metrics, ping, and reboot data contracts.
- `HostigLink` has the shared companion-link service constants, identity, snapshot payload, and snapshot-provider protocol for macOS-to-visionOS data exchange.
- `HostigLocalServices` has Bonjour discovery, host monitoring, ping, SSH, reboot, persistence, and a `HostStore` snapshot provider used by the macOS app.

## Notes

- SSH probing uses `/usr/bin/ssh` with `BatchMode=yes`, so it will not prompt for passwords.
- SSH user, keys, and related options are resolved by your normal `~/.ssh/config`; the app does not inject `user@host` or `-i`.
- First contact uses `StrictHostKeyChecking=accept-new` to avoid blocking on unknown host keys.
- Remote CPU and memory metrics are best-effort and support both macOS and Linux targets.
- For a companion visionOS app, start by linking `HostigModels` and `HostigLink`. `HostigLocalServices` compiles on visionOS but local process-backed ping and SSH operations report `unsupportedPlatform` outside macOS.
