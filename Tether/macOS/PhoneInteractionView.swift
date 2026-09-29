import AppKit
import SwiftUI

/// Turns mouse, trackpad and keyboard input on the phone picture into iPhone
/// touches and typing. Points are sent as fractions of the upright picture.
struct PhoneInteractionView: NSViewRepresentable {
    let model: ViewerModel

    func makeNSView(context: Context) -> InteractionView {
        InteractionView(model: model)
    }

    func updateNSView(_ view: InteractionView, context: Context) {}

    final class InteractionView: NSView {
        private let model: ViewerModel
        private var pressStart: (point: CGPoint, time: TimeInterval)?
        private var pressMoved = false
        private var scrollStart: CGPoint?
        private var scrollOffset = CGSize.zero
        private var scrollBegan: TimeInterval = 0
        private var scrollEndTimer: Timer?
        private var typed = ""
        private var typingTimer: Timer?

        /// Below this movement (in points) a click is a tap or a long press.
        private let clickSlop: CGFloat = 6
        private let longPressDuration: TimeInterval = 0.5

        init(model: ViewerModel) {
            self.model = model
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        // Clicks drive the phone; the window moves by its frame instead.
        override var mouseDownCanMoveWindow: Bool { false }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }

        // MARK: Clicks and drags

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            pressStart = (location(of: event), event.timestamp)
            pressMoved = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = pressStart else { return }
            let point = location(of: event)
            if hypot(point.x - start.point.x, point.y - start.point.y) >= clickSlop { pressMoved = true }
        }

        override func mouseUp(with event: NSEvent) {
            guard let start = pressStart else { return }
            pressStart = nil
            let end = location(of: event)
            let held = event.timestamp - start.time
            if !pressMoved {
                if held >= longPressDuration {
                    model.longPress(at: fraction(start.point), duration: held)
                } else {
                    model.tap(at: fraction(start.point))
                }
            } else {
                model.swipe(from: fraction(start.point), to: fraction(end), duration: min(max(held, 0.08), 1.2))
            }
        }

        // MARK: Scrolling

        override func scrollWheel(with event: NSEvent) {
            // The system's momentum after a flick is replayed by the iPhone's
            // own inertia, so only the fingers' movement is sent.
            guard event.momentumPhase.isEmpty else { return }

            if scrollStart == nil {
                scrollStart = location(of: event)
                scrollOffset = .zero
                scrollBegan = event.timestamp
            }
            // The deltas already follow the user's scroll-direction setting and
            // describe how the content moves, which is how a finger drags it.
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            scrollOffset.width += event.scrollingDeltaX * factor
            scrollOffset.height += event.scrollingDeltaY * factor

            if event.phase == .ended || event.phase == .cancelled {
                finishScroll(at: event.timestamp)
            } else {
                // Mouse wheels send no phases; end after a short pause.
                scrollEndTimer?.invalidate()
                scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                    self?.finishScroll(at: ProcessInfo.processInfo.systemUptime)
                }
            }
        }

        private func finishScroll(at time: TimeInterval) {
            scrollEndTimer?.invalidate()
            scrollEndTimer = nil
            guard let start = scrollStart else { return }
            scrollStart = nil
            guard hypot(scrollOffset.width, scrollOffset.height) >= 4 else { return }
            let end = CGPoint(x: start.x + scrollOffset.width, y: start.y + scrollOffset.height)
            model.swipe(from: fraction(start), to: fraction(end), duration: min(max(time - scrollBegan, 0.08), 0.6))
        }

        // MARK: Keyboard

        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.contains(.command) {
                super.keyDown(with: event)
                return
            }
            switch event.keyCode {
            case 51: // Delete
                queueText("\u{8}")
            case 36, 76: // Return, Enter
                queueText("\n")
            case 48: // Tab
                queueText("\t")
            case 53: // Escape
                model.press(.home)
            default:
                guard let characters = event.characters, !characters.isEmpty,
                      characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
                else {
                    super.keyDown(with: event)
                    return
                }
                queueText(characters)
            }
        }

        /// ⌘V types the Mac's clipboard on the iPhone.
        @objc func paste(_ sender: Any?) {
            if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                queueText(text)
            }
        }

        /// Sends typing in small batches: one DeviceKit call per word instead
        /// of per key keeps up with fast typists.
        private func queueText(_ text: String) {
            typed += text
            typingTimer?.invalidate()
            typingTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                guard let self, !self.typed.isEmpty else { return }
                self.model.type(self.typed)
                self.typed = ""
            }
        }

        // MARK: Geometry

        /// Top-left based point in this view.
        private func location(of event: NSEvent) -> CGPoint {
            let point = convert(event.locationInWindow, from: nil)
            return CGPoint(x: point.x, y: bounds.height - point.y)
        }

        private func fraction(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: min(max(point.x / max(bounds.width, 1), 0), 1),
                y: min(max(point.y / max(bounds.height, 1), 0), 1)
            )
        }
    }
}
