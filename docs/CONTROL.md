# Control your iPhone from Apple Vision Pro or Mac

Phone Remote always mirrors your iPhone. Controlling it (pinch to tap, swipe, type, Home, Lock, volume) needs one extra piece that Apple does not allow in App Store apps: **DeviceKit**, an XCTest runner that you build and start from your Mac.

## Once per session

You need a Mac with Xcode, your Apple developer Team ID (Xcode › Settings › Accounts; a free Personal Team works), and your iPhone connected (cable or same Wi-Fi) with Developer Mode on.

- **Mac app:** Phone Remote for Mac starts control by itself. If it was downloaded (DMG), enter your Team ID once when it asks.
- **Terminal:**

```bash
./scripts/enable-control.sh YOUR_TEAM_ID
```

Leave the script running. Within a few seconds, Phone Remote on the iPhone shows **Remote control: On**, and the Vision Pro or Mac window gets a Home button and controls. To stop, tap **Turn Off Control** in the iPhone app.

## What to expect

- Keep the iPhone unlocked. While control is on, Phone Remote keeps it from auto-locking during mirroring.
- If the Mac sleeps or the script stops, control turns off. Mirroring keeps working.
- DeviceKit listens only on the iPhone itself (`127.0.0.1:12004`), never on your network.

DeviceKit is made by Mobile Next and licensed under the Functional Source License 1.1. It is not part of Phone Remote; the script downloads it for you.
