import SwiftUI

struct MacContentView: View {
    @Environment(ViewerModel.self) private var model
    @Environment(ControlLauncher.self) private var control
    @State private var showPairing = false
    @State private var showKeyboardHelp = false
    /// Hidden by default: the window is just the phone and Home.
    @AppStorage("showControls") private var showControls = false
    /// Keeps the Mac's display awake while mirroring.
    @State private var awake: NSObjectProtocol?

    var body: some View {
        Group {
            switch model.phase {
            case .waiting:
                WaitingView()
            case .connecting, .mirroring, .reconnecting:
                phone
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.isLandscape)
        .animation(.easeInOut(duration: 0.3), value: model.phase)
        .animation(.easeInOut(duration: 0.25), value: model.windowSize)
        // No title bar: let the phone use the whole window.
        .ignoresSafeArea()
        .sheet(isPresented: $showPairing) { PairingSheet() }
        .onChange(of: model.phase) { _, phase in
            if case .waiting = phase {
                if let awake { ProcessInfo.processInfo.endActivity(awake) }
                awake = nil
            } else if awake == nil {
                awake = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .userInitiated],
                    reason: "Mirroring an iPhone"
                )
            }
        }
    }

    // MARK: Phone

    private var phone: some View {
        let longEdge = model.windowSize.longEdge
        let size = model.isLandscape
            ? CGSize(width: longEdge * 1.25, height: longEdge * 1.25 * model.displayAspect)
            : CGSize(width: longEdge * model.displayAspect, height: longEdge)
        let radius = min(size.width, size.height) * 0.13

        return VStack(spacing: 10) {
            VideoSurface(renderer: model.renderer, quarterTurns: model.quarterTurns)
                .frame(width: size.width, height: size.height)
                .overlay {
                    if model.canControl {
                        PhoneInteractionView(model: model)
                    }
                }
                .overlay { statusOverlay }
                .clipShape(.rect(cornerRadius: radius, style: .continuous))
                .padding(9)
                .background {
                    RoundedRectangle(cornerRadius: radius + 9, style: .continuous)
                        .fill(.clear)
                        .contentShape(.rect(cornerRadius: radius + 9, style: .continuous))
                        .gesture(WindowDragGesture())
                }
                .background {
                    RoundedRectangle(cornerRadius: radius + 9, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(white: 0.22), Color(white: 0.04), .black, Color(white: 0.14)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .overlay {
                            RoundedRectangle(cornerRadius: radius + 9, style: .continuous)
                                .stroke(LinearGradient(
                                    colors: [.white.opacity(0.34), .white.opacity(0.04), .black],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ), lineWidth: 1.2)
                        }
                }

            HStack(spacing: 10) {
                if model.canControl {
                    Button {
                        model.press(.home)
                    } label: {
                        Text("Home").padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Go to the iPhone's Home Screen (⌘1)")
                }
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showControls.toggle() }
                } label: {
                    Image(systemName: showControls ? "chevron.down" : "ellipsis")
                        .frame(width: 18)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help(showControls ? "Hide Controls" : "Show Controls")
            }

            if showControls {
                controls
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        // The screen takes clicks as taps, so the window moves by everything
        // around it: the phone's frame, the margins, beside Home. Nearly
        // invisible fill so those transparent areas still receive the mouse.
        .background {
            Color.black.opacity(0.01)
                .gesture(WindowDragGesture())
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch model.phase {
        case .connecting(let name):
            overlayMessage("Connecting to \(name)…")
        case .reconnecting:
            overlayMessage("Reconnecting…")
        default:
            EmptyView()
        }
    }

    private func overlayMessage(_ text: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).font(.headline)
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(deviceName)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if model.canControl {
                controlButton("App Switcher (⌘2)", "square.stack") { model.press(.appSwitcher) }
                controlButton("Volume Down (⌘↓)", "speaker.minus") { model.press(.volumeDown) }
                controlButton("Volume Up (⌘↑)", "speaker.plus") { model.press(.volumeUp) }
                controlButton("Lock (⌘L)", "lock.fill") { model.press(.lock) }
            } else {
                ControlStatusLabel()
            }
            controlButton("Pairing Code", "key") { showPairing = true }
            controlButton("Keyboard Tips", "keyboard") { showKeyboardHelp.toggle() }
                .popover(isPresented: $showKeyboardHelp) { KeyboardHelp() }
            controlButton("Stop Mirroring (⌘.)", "stop.fill") { model.stopMirroring() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
        .frame(maxWidth: 520)
    }

    private func controlButton(_ help: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var deviceName: String {
        switch model.phase {
        case .connecting(let name), .mirroring(let name), .reconnecting(let name): name
        case .waiting: ""
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .mirroring: .green
        case .connecting, .reconnecting: .orange
        case .waiting: .gray
        }
    }
}

/// Whether the Mac can control the iPhone, and why not.
private struct ControlStatusLabel: View {
    @Environment(ControlLauncher.self) private var control

    var body: some View {
        switch control.state {
        case .starting:
            Label("Starting control…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            HStack(spacing: 6) {
                Label("Control off", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(message)
                Button("Retry") { control.start() }
                    .buttonStyle(.link)
            }
            .font(.caption)
        case .off where !control.canStart:
            TeamIDField()
        case .off:
            Button("Turn On Control") { control.start() }
                .font(.caption)
        case .on, .external:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }
}

/// Asks once for the user's Apple developer Team ID, needed to sign the
/// control helper on their own account.
private struct TeamIDField: View {
    @Environment(ControlLauncher.self) private var control
    @State private var team = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField("Team ID", text: $team)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .help("Your Apple developer Team ID: Xcode › Settings › Accounts")
                .onSubmit(save)
            Button("Turn On Control", action: save)
                .disabled(team.trimmingCharacters(in: .whitespaces).count != 10)
        }
        .font(.caption)
    }

    private func save() {
        control.enteredTeamID = team.uppercased()
        control.start()
    }
}

private struct KeyboardHelp: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            row("Click", "Tap")
            row("Click and hold", "Long press")
            row("Drag, scroll", "Swipe")
            row("Type", "Types on the iPhone")
            row("⌘V", "Paste the Mac's clipboard")
            row("Esc, ⌘1", "Home")
            row("⌘2", "App Switcher")
            row("⌘3", "Spotlight")
            row("⌘↑  ⌘↓", "Volume")
            row("⌘+  ⌘−  ⌘0", "Window size")
        }
        .font(.callout)
        .padding(16)
    }

    private func row(_ keys: String, _ action: LocalizedStringKey) -> some View {
        GridRow {
            Text(keys).font(.callout.monospaced()).foregroundStyle(.secondary)
            Text(action)
        }
    }
}

/// Shown until an iPhone starts mirroring: explains the setup and shows the code.
private struct WaitingView: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 44))
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .foregroundStyle(.tint)
                Text("Waiting for your iPhone")
                    .font(.title.weight(.semibold))
                Text("Keep this window open while you mirror.")
                    .foregroundStyle(.secondary)
            }

            if let device = model.recentlyPairedDevice {
                Label("\(device) is paired. Tap Start Mirroring on it.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 14) {
                step(1, "Open Phone Remote on your iPhone.")
                step(2, "Choose **\(model.headsetName)** and enter this code:")
                Text(TetherWire.displayCode(model.code))
                    .font(.system(size: 36, weight: .semibold, design: .monospaced))
                    .kerning(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: .rect(cornerRadius: 14))
                    .frame(maxWidth: .infinity)
                step(3, "Tap **Start Mirroring**, then **Start Broadcast**.")
            }
            .padding(22)
            .frame(width: 400)
            .background(.background.opacity(0.5), in: .rect(cornerRadius: 22))

            HStack(spacing: 6) {
                Text("Control:")
                ControlStatusLabel()
            }
            .font(.callout)

            if let error = model.listenerError {
                Label("Phone Remote can't use the network right now: \(error)", systemImage: "wifi.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(width: 400)
            }

            Text("Your iPhone and Mac need to be on the same Wi-Fi network.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 480)
        .background(.regularMaterial, in: .rect(cornerRadius: 28))
        .contentShape(.rect(cornerRadius: 28))
        .gesture(WindowDragGesture())
        .padding(8)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .frame(width: 26, height: 26)
                .background(.tint.opacity(0.25), in: .circle)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PairingSheet: View {
    @Environment(ViewerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmNewCode = false

    var body: some View {
        VStack(spacing: 18) {
            Text("Pairing Code").font(.title2.weight(.semibold))
            Text("Enter this code in Phone Remote on another iPhone to pair it with \(model.headsetName).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(TetherWire.displayCode(model.code))
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .kerning(3)
                .textSelection(.enabled)
            HStack {
                Button("New Code", role: .destructive) { confirmNewCode = true }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 420)
        .confirmationDialog("Create a new code?", isPresented: $confirmNewCode) {
            Button("New Code", role: .destructive) { model.generateNewCode() }
        } message: {
            Text("Every paired iPhone will need to pair again. Any current mirroring stops.")
        }
    }
}
