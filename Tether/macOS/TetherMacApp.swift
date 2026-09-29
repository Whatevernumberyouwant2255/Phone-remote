import AppKit
import SwiftUI

@main
struct TetherMacApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = ViewerModel()
    @State private var control = ControlLauncher()

    var body: some Scene {
        Window("Phone Remote", id: "main") {
            MacContentView()
                .environment(model)
                .environment(control)
                // Transparent around the phone; dragging there moves the window.
                .containerBackground(.clear, for: .window)
                .background(WindowConfigurator())
                .onAppear {
                    model.start()
                    if control.canStart { control.start() }
                    appDelegate.onQuit = { control.stop() }
                }
        }
        // Borderless: no title bar or window buttons, just the phone.
        .windowStyle(.plain)
        .windowBackgroundDragBehavior(.enabled)
        // The window follows the phone's shape, including rotation.
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("iPhone") {
                Button("Home") { model.press(.home) }
                    .keyboardShortcut("1")
                Button("App Switcher") { model.press(.appSwitcher) }
                    .keyboardShortcut("2")
                Button("Spotlight") { model.press(.spotlight) }
                    .keyboardShortcut("3")
                Divider()
                Button("Volume Up") { model.press(.volumeUp) }
                    .keyboardShortcut(.upArrow)
                Button("Volume Down") { model.press(.volumeDown) }
                    .keyboardShortcut(.downArrow)
                Button("Lock") { model.press(.lock) }
                    .keyboardShortcut("l")
                Divider()
                if control.isOn {
                    Button("Turn Off Control") { control.stop() }
                } else {
                    Button("Turn On Control") { control.start() }
                        .disabled(!control.canStart)
                }
                Button("Stop Mirroring") { model.stopMirroring() }
                    .keyboardShortcut(".")
            }
            CommandGroup(after: .toolbar) {
                Button("Larger") { model.windowSize = model.windowSize.larger }
                    .keyboardShortcut("+")
                Button("Actual Size") { model.windowSize = .medium }
                    .keyboardShortcut("0")
                Button("Smaller") { model.windowSize = model.windowSize.smaller }
                    .keyboardShortcut("-")
                Divider()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onQuit: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        onQuit?()
    }
}

/// Keeps the borderless window see-through and shadowed, and inside the
/// screen when it grows (rotation, size changes). Reapplied on updates
/// because SwiftUI may reset window properties.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(view.window) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observer: NSObjectProtocol?

        func attach(_ window: NSWindow?) {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = true
            guard window !== self.window else { return }
            self.window = window
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepOnScreen() }
            }
            keepOnScreen()
        }

        private func keepOnScreen() {
            guard let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            var frame = window.frame
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
            if frame.minX < visible.minX { frame.origin.x = visible.minX }
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
            if frame.origin != window.frame.origin { window.setFrameOrigin(frame.origin) }
        }
    }
}
