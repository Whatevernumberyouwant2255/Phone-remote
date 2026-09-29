# Third-party notices

## DeviceKit iOS (optional, not included)

- Repository: https://github.com/mobile-next/devicekit-ios
- Pinned commit: `510d10e5e376221397cef7f8d7acb74603c61888`
- License: **Functional Source License, Version 1.1, ALv2 Future License (FSL-1.1-ALv2)**, by Mobile Next HQ, Inc. It allows use for any purpose other than a competing commercial offering; read the upstream `LICENSE`, which is authoritative.
- Use: optional remote control. Phone Remote does not ship DeviceKit. `scripts/enable-control.sh` downloads it on the user's Mac and applies `scripts/devicekit-tether.patch` (faster taps with ready-made coordinates, and a stop command).

## Apple frameworks

Phone Remote uses Apple SDK frameworks (SwiftUI, ReplayKit, VideoToolbox, Network, AVFoundation, CryptoKit). Their use is subject to Apple's SDK terms.
