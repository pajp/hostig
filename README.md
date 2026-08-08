# Hostig

`Hostig` is a SwiftUI host monitor for macOS with a companion visionOS app.

The macOS app:

- discovers `_ssh._tcp` Bonjour services on the local network
- lets you add and remove non-Bonjour hosts from an editable host list
- pings every discovered host and shows latency plus packet loss
- attempts non-interactive SSH login using your existing `~/.ssh/config` and SSH agent
- fetches remote uptime, load average, CPU, disk, memory, logged-in user count, OS, version, and architecture for hosts where SSH succeeds
- allows rebooting authenticated hosts via `sudo reboot`, with confirmation and a remote sudo password prompt only when required
- publishes the current host snapshot to paired companion clients on the local network

The visionOS companion app:

- discovers Hostig Mac sources over Bonjour
- displays the same host snapshot as the Mac app
- pairs with a 6-digit PIN shown by the Mac app on first connection
- derives and stores a long-term per-device encryption key after first pairing
- remembers the last connected Mac and reconnects automatically when it is available

## Run

```bash
swift build --package-path Packages/HostigCore
xcodebuild -project Hostig.xcodeproj -scheme Hostig -destination 'platform=macOS' build
xcodebuild -project Hostig.xcodeproj -scheme HostigVision -destination 'generic/platform=visionOS' build
```

Open the generated app bundles from DerivedData, or run the `Hostig` and `HostigVision` schemes directly in Xcode.

## Project Layout

- `Hostig.xcodeproj` is the traditional Xcode app project.
- `App/HostigMac` contains the macOS SwiftUI/AppKit shell, signing settings, entitlements, and assets.
- `App/HostigVision` contains the visionOS SwiftUI shell, signing settings, entitlements, and assets.
- `Packages/HostigCore` contains local Swift packages for reusable logic.
- `HostigModels` has the shared Codable host, metrics, ping, reboot, and status data contracts.
- `HostigLink` has shared companion-link service constants, persisted app identity helpers, snapshot payloads, and the snapshot-provider protocol.
- `HostigNetworking` has the Bonjour `_hostig._tcp` source browser, TCP snapshot transport, secure envelope, PIN pairing, long-term key storage, and link diagnostics.
- `HostigLocalServices` has macOS Bonjour SSH discovery, host monitoring, ping, SSH, reboot, persistence, and a `HostStore` snapshot provider used by the macOS app.

The logic is intentionally kept in local Swift packages so new Apple-platform targets can reuse the model, link, networking, and host-service layers without copying app UI code.

## Companion Link

The companion link is currently LAN-only TCP discovered through Bonjour service type `_hostig._tcp`.

Initial pairing uses the 6-digit PIN displayed by the Mac app. After a successful PIN exchange, both apps derive a long-term symmetric key from the PIN and the persisted identities of the Mac and companion device. Secret key material is stored in Keychain; non-secret app instance identifiers and remembered source metadata are stored in `UserDefaults`.

The visionOS app can discover multiple Mac sources, remember paired sources, and auto-connect to the last successful source. Entering a complete PIN again re-pairs with the selected source.

The transport layer is isolated in `HostigNetworking` so other transports, such as direct TCP variants, SSH bounce hosts, or routed HTTPS, can be added without changing the shared snapshot model or app presentation code.

## Notes

- SSH probing uses `/usr/bin/ssh` with `BatchMode=yes`, so it will not prompt for passwords.
- SSH user, keys, and related options are resolved by your normal `~/.ssh/config`; the app does not inject `user@host` or `-i`.
- First contact uses `StrictHostKeyChecking=accept-new` to avoid blocking on unknown host keys.
- Remote CPU and memory metrics are best-effort and support both macOS and Linux targets.
- `HostigLocalServices` compiles on visionOS, but local process-backed ping and SSH operations report `unsupportedPlatform` outside macOS.
- Companion-link diagnostics are logged with subsystem `nu.dll.hostig` and category `HostigLink`.
