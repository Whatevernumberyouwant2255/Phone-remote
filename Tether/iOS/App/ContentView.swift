import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedReceiver: AppModel.Receiver?
    @State private var isAddingDevice = false
    @State private var stopFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    if model.pairings.isEmpty || isAddingDevice {
                        pairingSection
                    } else {
                        pairedSection
                    }
                    privacyNote
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .toolbar {
                if isAddingDevice {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isAddingDevice = false }
                    }
                }
            }
        }
        .sheet(item: $selectedReceiver) { receiver in
            PairingCodeSheet(receiver: receiver) {
                isAddingDevice = false
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                model.reloadPairings()
                model.startBrowsing()
            } else {
                model.stopBrowsing()
            }
        }
        .task(id: scenePhase) {
            while scenePhase == .active, !Task.isCancelled {
                await model.refreshControlStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 54, weight: .regular))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: model.isMirroring)
                .padding(.top, 28)
            Text("Phone Remote")
                .font(.largeTitle.bold())
            Text("Your iPhone screen, in a window on Apple Vision Pro or Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Paired

    private var pairedSection: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your Devices")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(model.pairings) { pairing in
                        pairedRow(pairing)
                        Divider().padding(.leading, 74)
                    }
                    Button {
                        isAddingDevice = true
                    } label: {
                        Label("Pair Another Device", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
            }

            BroadcastButton {
                Label(model.isMirroring ? "Stop Mirroring" : "Start Mirroring",
                      systemImage: model.isMirroring ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(.white)
                    .background(model.isMirroring ? Color.red : Color.accentColor, in: .rect(cornerRadius: 16))
            }

            controlStatus

            VStack(alignment: .leading, spacing: 12) {
                tip("macbook.and.visionpro", "Mirroring goes to whichever device has Phone Remote open. If both are open, the one you used last.")
                tip("hand.tap", "Tap Start Mirroring, then Start Broadcast.")
                tip("record.circle", "To stop, tap the red indicator at the top of the screen, or use Control Center.")
                tip("lock.shield", "Passwords and some protected video are hidden by iOS while mirroring.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
        }
    }

    private func pairedRow(_ pairing: Pairing) -> some View {
        let open = model.isOpen(pairing)
        return HStack(spacing: 14) {
            Image(systemName: symbol(for: pairing.receiverKind, filled: true))
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(pairing.headsetName)
                    .font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(open ? .green : .secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(open ? "Phone Remote is open" : "Not open")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Forget This Device", systemImage: "trash", role: .destructive) {
                    model.forget(pairing)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .accessibilityLabel("Options for \(pairing.headsetName)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func symbol(for kind: ReceiverKind, filled: Bool = false) -> String {
        switch kind {
        case .visionPro: filled ? "visionpro.fill" : "visionpro"
        case .mac: "macbook"
        }
    }

    private var controlStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: model.controlAvailable ? "hand.tap.fill" : "hand.tap")
                .foregroundStyle(model.controlAvailable ? .green : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.controlAvailable ? "Remote control: On" : "Remote control: Off")
                    .font(.subheadline.weight(.semibold))
                Text(model.controlAvailable
                     ? "Tap and swipe from your Vision Pro or Mac. Your iPhone stays awake while mirroring."
                     : "Mirroring works. Controlling the iPhone needs a one-time developer setup with a Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.controlAvailable {
                    Button("Turn Off Control", role: .destructive) {
                        Task { stopFailed = !(await model.turnOffControl()) }
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.top, 2)
                    if stopFailed {
                        Text("This version of the control helper can't be stopped from the iPhone. Quit Phone Remote on the Mac, or stop the script there.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("See docs/CONTROL.md on the project page to turn it on.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }

    private func tip(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(.tint)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pairing

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair a Device")
                .font(.title3.bold())
            Text("Open Phone Remote on your Apple Vision Pro or Mac. It appears below when both devices are on the same Wi-Fi network.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                if model.receivers.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for devices…")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(model.receivers) { receiver in
                        Button {
                            selectedReceiver = receiver
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: symbol(for: receiver.kind))
                                    .foregroundStyle(.tint)
                                    .frame(width: 26)
                                Text(receiver.serviceName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if model.isPaired(receiver) {
                                    Text("Paired")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(16)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        if receiver != model.receivers.last {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))

            if model.browserFailed {
                Label {
                    Text("Phone Remote needs Local Network access to find your devices. Turn it on in Settings › Privacy & Security › Local Network.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.footnote)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.footnote.bold())
            }
        }
    }

    private var privacyNote: some View {
        Text("Your screen goes straight from your iPhone to your Vision Pro or Mac over your local network, encrypted with your pairing code. Nothing is sent to the internet or collected.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}

private struct PairingCodeSheet: View {
    let receiver: AppModel.Receiver
    let onPaired: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isPairing = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    private var isComplete: Bool {
        TetherWire.normalized(code).count == TetherConstants.codeLength
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Enter the code shown in Phone Remote on \(receiver.serviceName).")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                TextField("ABCD-2345", text: $code)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .focused($fieldFocused)
                    .padding(.vertical, 14)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
                    .onChange(of: code) { _, newValue in
                        let formatted = TetherWire.displayCode(String(TetherWire.normalized(newValue).prefix(TetherConstants.codeLength)))
                        if formatted != newValue { code = formatted }
                        errorMessage = nil
                    }
                    .onSubmit(pair)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button(action: pair) {
                    Group {
                        if isPairing {
                            ProgressView().tint(.white)
                        } else {
                            Text("Pair")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .disabled(!isComplete || isPairing)

                Spacer()
            }
            .padding(24)
            .navigationTitle("Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { fieldFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func pair() {
        guard isComplete, !isPairing else { return }
        isPairing = true
        Task {
            do {
                try await model.pair(with: receiver, code: code)
                onPaired()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isPairing = false
        }
    }
}
