import SwiftUI

struct ContentView: View {
    @Environment(ViewerModel.self) private var model
    @State private var showPairing = false
    /// Hidden by default: the window is just the phone and Home.
    @AppStorage("showControls") private var showControls = false
    @State private var showKeyboard = false

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
        .sheet(isPresented: $showPairing) {
            PairingSheet()
        }
        .sheet(isPresented: $showKeyboard) {
            KeyboardSheet()
        }
    }

    private var phone: some View {
        let longEdge = model.windowSize.longEdge
        let size = model.isLandscape
            ? CGSize(width: longEdge * 1.25, height: longEdge * 1.25 * model.displayAspect)
            : CGSize(width: longEdge * model.displayAspect, height: longEdge)
        let radius = min(size.width, size.height) * 0.13

        return VStack(spacing: 10) {
            screen(size: size, radius: radius)
            // A full-size button beside Home: a small, faint target at the
            // window's edge lost pinches to the system's window bar.
            HStack(spacing: 12) {
                if model.canControl {
                    Button {
                        model.press(.home)
                    } label: {
                        Text("Home")
                            .font(.headline)
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Go to the iPhone's Home Screen")
                    .transition(.opacity)
                }
                controlsToggle
            }
        }
        .animation(.default, value: model.canControl)
        .ornament(
            visibility: showControls ? .visible : .hidden,
            attachmentAnchor: .scene(.bottom),
            contentAlignment: .top
        ) {
            controls
        }
    }

    /// A discreet arrow that shows or hides the control bar, so the window
    /// can be just the phone and its Home button.
    private var controlsToggle: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showControls.toggle()
            }
        } label: {
            Label(showControls ? "Hide Controls" : "Show Controls",
                  systemImage: showControls ? "chevron.down" : "ellipsis")
                .labelStyle(.iconOnly)
                .font(.headline)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help(showControls ? "Hide Controls" : "Show Controls")
    }


    private func screen(size: CGSize, radius: CGFloat) -> some View {
        VideoSurface(renderer: model.renderer, quarterTurns: model.quarterTurns)
            .frame(width: size.width, height: size.height)
            .overlay {
                if model.canControl {
                    TouchSurface(landscape: model.isLandscape)
                }
            }
            .overlay { statusOverlay }
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: radius + 10, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(white: 0.22), Color(white: 0.04), .black, Color(white: 0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius + 10, style: .continuous)
                            .stroke(LinearGradient(
                                colors: [.white.opacity(0.34), .white.opacity(0.04), .black],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ), lineWidth: 1.2)
                    }
            }
            .accessibilityLabel(accessibilityDescription)
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
        VStack(spacing: 14) {
            ProgressView()
            Text(text)
                .font(.headline)
        }
        .padding(24)
        .glassBackgroundEffect()
    }

    private var controls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(deviceName)
                    .font(.headline)
                    .lineLimit(1)
            }
            .padding(.leading, 6)

            Picker("Size", selection: Binding(get: { model.windowSize }, set: { model.windowSize = $0 })) {
                Image(systemName: "textformat.size.smaller").tag(ViewerModel.WindowSize.small)
                    .accessibilityLabel("Small")
                Image(systemName: "textformat.size").tag(ViewerModel.WindowSize.medium)
                    .accessibilityLabel("Medium")
                Image(systemName: "textformat.size.larger").tag(ViewerModel.WindowSize.large)
                    .accessibilityLabel("Large")
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            if model.canControl {
                Divider().frame(height: 30)
                Button { showKeyboard = true } label: {
                    Label("Type", systemImage: "keyboard")
                }
                .help("Type on the iPhone")
                Button { model.press(.volumeDown) } label: {
                    Label("Volume Down", systemImage: "speaker.minus")
                }
                Button { model.press(.volumeUp) } label: {
                    Label("Volume Up", systemImage: "speaker.plus")
                }
                Button { model.press(.lock) } label: {
                    Label("Lock", systemImage: "lock.fill")
                }
                .help("Lock the iPhone")
                Divider().frame(height: 30)
            }

            Button {
                showPairing = true
            } label: {
                Label("Pairing", systemImage: "key")
            }
            .help("Pairing code")

            Button(role: .destructive) {
                model.stopMirroring()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .help("Stop mirroring on the iPhone")
        }
        .labelStyle(.iconOnly)
        .padding(12)
        .glassBackgroundEffect()
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

    private var accessibilityDescription: Text {
        Text("Screen of \(deviceName)")
    }
}

/// Turns pinches on the picture into taps and swipes on the iPhone. The cells
/// only give visionOS gaze targets to highlight; the touch keeps its exact
/// position, so precision is not limited to the grid.
private struct TouchSurface: View {
    let landscape: Bool
    @Environment(ViewerModel.self) private var model
    @State private var gestureStart: Date?

    var body: some View {
        let columns = landscape ? 18 : 8
        let rows = landscape ? 8 : 18
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { _ in
                    HStack(spacing: 0) {
                        ForEach(0..<columns, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(.white)
                                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 7))
                                .hoverEffect { effect, isActive, _ in
                                    effect
                                        .opacity(isActive ? 0.22 : 0.001)
                                        .scaleEffect(isActive ? 0.94 : 1)
                                }
                        }
                    }
                }
            }
            .contentShape(.rect)
            .gesture(
                // One recognizer decides after release, so a slightly moving
                // pinch never sends both a tap and a swipe.
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if gestureStart == nil { gestureStart = .now }
                    }
                    .onEnded { value in
                        let size = geometry.size
                        let start = CGPoint(x: value.startLocation.x / size.width, y: value.startLocation.y / size.height)
                        let end = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
                        let duration = Date.now.timeIntervalSince(gestureStart ?? .now)
                        gestureStart = nil
                        if hypot(value.translation.width, value.translation.height) < 12 {
                            model.tap(at: start)
                        } else {
                            model.swipe(from: start, to: end, duration: duration)
                        }
                    }
            )
        }
        .accessibilityLabel("iPhone screen")
        .accessibilityHint("Pinch to tap. Pinch and drag to swipe.")
    }
}

private struct KeyboardSheet: View {
    @Environment(ViewerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Type on iPhone", systemImage: "keyboard")
                .font(.title2.weight(.semibold))
            Text("Tap a text field on the iPhone first, then type here.")
                .foregroundStyle(.secondary)
            TextField("Text to send", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .onSubmit(send)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.isEmpty)
            }
        }
        .padding(32)
        .frame(width: 560)
    }

    private func send() {
        guard !text.isEmpty else { return }
        model.type(text)
        dismiss()
    }
}

/// Shown until an iPhone starts mirroring: explains the setup and shows the code.
private struct WaitingView: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 56))
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .foregroundStyle(.tint)
                Text("Waiting for your iPhone")
                    .font(.extraLargeTitle2)
                Text("Keep this window open while you mirror.")
                    .foregroundStyle(.secondary)
            }

            if let device = model.recentlyPairedDevice {
                Label("\(device) is paired. Tap Start Mirroring on it.", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: 16) {
                step(1, "Install Phone Remote on your iPhone and open it.")
                step(2, "Choose **\(model.headsetName)** and enter this code:")
                CodeView(code: model.code)
                    .frame(maxWidth: .infinity)
                step(3, "Tap **Start Mirroring**, then **Start Broadcast**.")
            }
            .padding(26)
            .frame(width: 480)
            .background(.regularMaterial, in: .rect(cornerRadius: 30))

            if let error = model.listenerError {
                Label("Phone Remote can't use the network right now: \(error)", systemImage: "wifi.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(width: 480)
            }

            Text("Your iPhone and Apple Vision Pro need to be on the same Wi-Fi network.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(width: 600)
        .glassBackgroundEffect()
        .animation(.default, value: model.recentlyPairedDevice)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .frame(width: 30, height: 30)
                .background(.tint.opacity(0.3), in: .circle)
            Text(text)
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CodeView: View {
    let code: String

    var body: some View {
        Text(TetherWire.displayCode(code))
            .font(.system(size: 44, weight: .semibold, design: .monospaced))
            .kerning(4)
            .textSelection(.enabled)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.thinMaterial, in: .rect(cornerRadius: 18))
            .accessibilityLabel(Text(code.map(String.init).joined(separator: " ")))
    }
}

private struct PairingSheet: View {
    @Environment(ViewerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmNewCode = false

    var body: some View {
        VStack(spacing: 22) {
            Text("Pairing Code")
                .font(.title)
            Text("Enter this code in Phone Remote on another iPhone to pair it with \(model.headsetName).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            CodeView(code: model.code)
            HStack {
                Button("New Code", role: .destructive) {
                    confirmNewCode = true
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(34)
        .frame(width: 520)
        .confirmationDialog("Create a new code?", isPresented: $confirmNewCode) {
            Button("New Code", role: .destructive) {
                model.generateNewCode()
            }
        } message: {
            Text("Every paired iPhone will need to pair again. Any current mirroring stops.")
        }
    }
}
