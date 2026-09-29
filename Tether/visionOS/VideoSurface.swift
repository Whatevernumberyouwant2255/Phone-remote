import AVFoundation
import SwiftUI
import UIKit

/// Hosts the renderer's layer and rotates it so the picture is upright.
struct VideoSurface: UIViewRepresentable {
    let renderer: VideoRenderer
    let quarterTurns: Int

    func makeUIView(context: Context) -> SurfaceView {
        SurfaceView(displayLayer: renderer.displayLayer)
    }

    func updateUIView(_ view: SurfaceView, context: Context) {
        view.quarterTurns = quarterTurns
    }

    final class SurfaceView: UIView {
        let displayLayer: AVSampleBufferDisplayLayer
        var quarterTurns = 0 {
            didSet { if quarterTurns != oldValue { setNeedsLayout() } }
        }

        init(displayLayer: AVSampleBufferDisplayLayer) {
            self.displayLayer = displayLayer
            super.init(frame: .zero)
            backgroundColor = .black
            layer.addSublayer(displayLayer)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let sideways = quarterTurns % 2 != 0
            displayLayer.bounds = CGRect(
                x: 0, y: 0,
                width: sideways ? bounds.height : bounds.width,
                height: sideways ? bounds.width : bounds.height
            )
            displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(quarterTurns) * .pi / 2))
            CATransaction.commit()
        }
    }
}
