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
swift run Hostig
```

To build and launch the app bundle, use the current Xcode build output and open that bundle rather than an older copy:

```bash
xcodebuild -project Hostig.xcodeproj -scheme Hostig -destination 'platform=macOS' build
open build/Release/Hostig.app
```

## Notes

- SSH probing uses `/usr/bin/ssh` with `BatchMode=yes`, so it will not prompt for passwords.
- SSH user, keys, and related options are resolved by your normal `~/.ssh/config`; the app does not inject `user@host` or `-i`.
- First contact uses `StrictHostKeyChecking=accept-new` to avoid blocking on unknown host keys.
- Remote CPU and memory metrics are best-effort and support both macOS and Linux targets.
