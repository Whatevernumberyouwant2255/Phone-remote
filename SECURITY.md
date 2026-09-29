# Security

Phone Remote is an experimental personal project. Known limits:

- Pairing: TLS 1.2 with a pre-shared key derived from an 8-character code. Suitable for a home network; a recorded session could be attacked offline. Don't use it on untrusted Wi-Fi.
- Control: DeviceKit accepts commands from any app on the iPhone while it runs (loopback only, no authentication). Turn control off when you're done.
- Release files are ad-hoc signed and not notarized. Verify them with `SHA256SUMS`, or build from source.

Report problems through a GitHub issue. Don't include personal data.
