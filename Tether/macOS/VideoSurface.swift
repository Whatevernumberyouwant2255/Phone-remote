import AVFoundation
import SwiftUI

/// Hosts the renderer's layer and rotates it so the picture is upright.
struct VideoSurface: NSViewRepresentable {
    let renderer: VideoRenderer
    let quarterTurns: Int

    func makeNSView(context: Context) -> SurfaceView {
        SurfaceView(displayLayer: renderer.displayLayer)
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        view.quarterTurns = quarterTurns
    }

    final class SurfaceView: NSView {
        let displayLayer: AVSampleBufferDisplayLayer
        var quarterTurns = 0 {
            didSet { if quarterTurns != oldValue { needsLayout = true } }
        }

        init(displayLayer: AVSampleBufferDisplayLayer) {
            self.displayLayer = displayLayer
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = .black
            layer?.addSublayer(displayLayer)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let sideways = quarterTurns % 2 != 0
            displayLayer.bounds = CGRect(
                x: 0, y: 0,
                width: sideways ? bounds.height : bounds.width,
                height: sideways ? bounds.width : bounds.height
            )
            displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            // AppKit layers are not flipped, so a clockwise turn is negative.
            displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(quarterTurns) * .pi / 2))
            CATransaction.commit()
        }
    }
}
