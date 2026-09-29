import ReplayKit
import SwiftUI

/// The system broadcast picker is the only way to start a screen broadcast.
/// It is laid invisibly over our own button so taps reach it directly.
struct BroadcastButton<Label: View>: View {
    @ViewBuilder var label: Label

    var body: some View {
        label
            .overlay { BroadcastPicker() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
    }
}

private struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView()
        picker.preferredExtension = SigningInfo.broadcastExtensionID
        picker.showsMicrophoneButton = false
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {
        // Stretch the picker's internal button over the whole label and hide
        // its icon; the label underneath provides the visuals.
        for case let button as UIButton in picker.subviews {
            button.frame = picker.bounds
            button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            button.imageView?.alpha = 0
            button.setImage(nil, for: .normal)
        }
    }
}
