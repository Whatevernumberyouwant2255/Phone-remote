// Renders the Phone Remote explainer video frame by frame.
//
//   swiftc -O -parse-as-library video/Render.swift -o .build/render
//   .build/render frames | ffmpeg -f rawvideo -pix_fmt bgra -s 3840x2160 -r 30 -i - …
//   .build/render still 12.5 out.png      # one frame, for checking
//
// Everything is drawn here: no screen recordings, no third-party artwork.

import AppKit
import SwiftUI

// MARK: - Timeline

let fps = 30.0
let designSize = CGSize(width: 1920, height: 1080)
let renderScale: CGFloat = 2 // 3840 × 2160

struct Scene {
    let start: Double
    let end: Double
    let view: (Double) -> AnyView // local time since `start`
}

let fade = 0.6

@MainActor
let scenes: [Scene] = [
    Scene(start: 0, end: 5) { AnyView(TitleScene(t: $0)) },
    Scene(start: 5, end: 17.5) { AnyView(VisionScene(t: $0)) },
    Scene(start: 17.5, end: 28) { AnyView(ChooseScene(t: $0)) },
    Scene(start: 28, end: 40) { AnyView(HowScene(t: $0)) },
    Scene(start: 40, end: 54) { AnyView(InstallScene(t: $0)) },
    Scene(start: 54, end: 64) { AnyView(PairScene(t: $0)) },
    Scene(start: 64, end: 71) { AnyView(EndScene(t: $0)) },
]
let duration = 71.0

@MainActor
struct Frame: View {
    let time: Double

    var body: some View {
        ZStack {
            Color.black
            ForEach(Array(scenes.enumerated()), id: \.offset) { _, scene in
                if time >= scene.start - 0.001 && time < scene.end + fade {
                    let local = time - scene.start
                    let fadeIn = scene.start == 0 ? 1 : ramp(local, 0, fade)
                    let fadeOut = 1 - ramp(time, scene.end, scene.end + fade)
                    scene.view(local).opacity(min(fadeIn, fadeOut))
                }
            }
        }
        .frame(width: designSize.width, height: designSize.height)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Easing

func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
func ease(_ x: Double) -> Double { let t = clamp(x); return t * t * (3 - 2 * t) }
/// 0 before `a`, 1 after `b`, eased in between.
func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double { ease((t - a) / (b - a)) }

extension View {
    /// Fades and slides up into place starting at `at` (scene-local seconds).
    func appear(_ t: Double, at: Double, dy: CGFloat = 24, duration: Double = 0.7) -> some View {
        let p = ramp(t, at, at + duration)
        return opacity(p).offset(y: dy * (1 - p))
    }
}

// MARK: - Palette and type

extension Color {
    static let ink = Color(red: 0.05, green: 0.06, blue: 0.10)
    static let accent = Color(red: 0.36, green: 0.55, blue: 1.0)
    static let mint = Color(red: 0.35, green: 0.85, blue: 0.75)
}

struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.14), Color(red: 0.03, green: 0.03, blue: 0.06)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.accent.opacity(0.22), .clear], center: .init(x: 0.25, y: 0.2), startRadius: 0, endRadius: 900)
            RadialGradient(colors: [Color.purple.opacity(0.16), .clear], center: .init(x: 0.85, y: 0.85), startRadius: 0, endRadius: 900)
        }
    }
}

struct Headline: View {
    let text: String
    var size: CGFloat = 64
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
    }
}

struct Subline: View {
    let text: String
    var size: CGFloat = 30
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(.white.opacity(0.72))
            .multilineTextAlignment(.center)
    }
}

/// Caption pill used over the device scenes.
struct Caption: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 34)
            .padding(.vertical, 18)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
    }
}

// MARK: - iPhone mockup (drawn, generic)

struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.98, green: 0.55, blue: 0.35), Color(red: 0.93, green: 0.33, blue: 0.52),
                                    Color(red: 0.45, green: 0.30, blue: 0.85), Color(red: 0.12, green: 0.45, blue: 0.85)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { g in
                Ellipse()
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.8, blue: 0.5).opacity(0.7), .clear],
                                         center: .center, startRadius: 0, endRadius: g.size.width * 0.7))
                    .frame(width: g.size.width * 1.4, height: g.size.width * 1.1)
                    .offset(x: -g.size.width * 0.5, y: -g.size.height * 0.15)
                Ellipse()
                    .fill(RadialGradient(colors: [Color(red: 0.3, green: 0.9, blue: 0.85).opacity(0.65), .clear],
                                         center: .center, startRadius: 0, endRadius: g.size.width * 0.7))
                    .frame(width: g.size.width * 1.4, height: g.size.width * 1.2)
                    .offset(x: g.size.width * 0.25, y: g.size.height * 0.62)
            }
        }
    }
}

struct AppIconView: View {
    let symbol: String
    let colors: [Color]
    let label: String
    let size: CGFloat
    var highlight: Double = 0
    var glyph: Color = .white

    var body: some View {
        VStack(spacing: size * 0.12) {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(glyph)
                }
                // Gaze highlight, as visionOS shows before a pinch.
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                        .fill(.white.opacity(0.35 * highlight))
                }
                .scaleEffect(1 + 0.06 * highlight)
            Text(label)
                .font(.system(size: size * 0.2, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

struct HomeIcon {
    let symbol: String
    let colors: [Color]
    let label: String
    var glyph: Color = .white
}

let homeIcons: [HomeIcon] = [
    .init(symbol: "message.fill", colors: [Color(red: 0.4, green: 0.9, blue: 0.45), Color(red: 0.15, green: 0.72, blue: 0.3)], label: "Messages"),
    .init(symbol: "calendar", colors: [.white.opacity(0.95), .white.opacity(0.85)], label: "Calendar", glyph: .red),
    .init(symbol: "photo.fill", colors: [Color(red: 1, green: 0.75, blue: 0.3), Color(red: 0.95, green: 0.45, blue: 0.4)], label: "Photos"),
    .init(symbol: "camera.fill", colors: [Color(white: 0.55), Color(white: 0.3)], label: "Camera"),
    .init(symbol: "cloud.sun.fill", colors: [Color(red: 0.35, green: 0.7, blue: 1), Color(red: 0.15, green: 0.45, blue: 0.95)], label: "Weather"),
    .init(symbol: "map.fill", colors: [Color(red: 0.55, green: 0.85, blue: 0.5), Color(red: 0.25, green: 0.65, blue: 0.85)], label: "Maps"),
    .init(symbol: "note.text", colors: [Color(red: 1, green: 0.88, blue: 0.4), Color(red: 1, green: 0.78, blue: 0.2)], label: "Notes"),
    .init(symbol: "clock.fill", colors: [Color(white: 0.2), Color(white: 0.05)], label: "Clock"),
    .init(symbol: "music.note", colors: [Color(red: 1, green: 0.4, blue: 0.5), Color(red: 0.95, green: 0.2, blue: 0.35)], label: "Music"),
    .init(symbol: "book.fill", colors: [Color(red: 1, green: 0.6, blue: 0.25), Color(red: 0.95, green: 0.4, blue: 0.15)], label: "Books"),
    .init(symbol: "heart.fill", colors: [.white.opacity(0.95), .white.opacity(0.85)], label: "Health", glyph: Color(red: 1, green: 0.25, blue: 0.4)),
    .init(symbol: "gearshape.fill", colors: [Color(white: 0.6), Color(white: 0.4)], label: "Settings"),
    .init(symbol: "antenna.radiowaves.left.and.right", colors: [Color(red: 0.75, green: 0.4, blue: 1), Color(red: 0.55, green: 0.25, blue: 0.9)], label: "Podcasts"),
    .init(symbol: "sparkles", colors: [Color(red: 0.4, green: 0.5, blue: 1), Color(red: 0.6, green: 0.35, blue: 0.95)], label: "Tips"),
    .init(symbol: "gamecontroller.fill", colors: [Color(red: 0.3, green: 0.8, blue: 0.95), Color(red: 0.2, green: 0.5, blue: 0.95)], label: "Games"),
    .init(symbol: "folder.fill", colors: [Color(red: 0.35, green: 0.65, blue: 1), Color(red: 0.2, green: 0.45, blue: 0.95)], label: "Files"),
]
let dockIcons: [HomeIcon] = [
    .init(symbol: "phone.fill", colors: [Color(red: 0.4, green: 0.9, blue: 0.45), Color(red: 0.15, green: 0.72, blue: 0.3)], label: ""),
    .init(symbol: "safari.fill", colors: [Color(red: 0.4, green: 0.75, blue: 1), Color(red: 0.15, green: 0.45, blue: 0.95)], label: ""),
    .init(symbol: "envelope.fill", colors: [Color(red: 0.35, green: 0.7, blue: 1), Color(red: 0.15, green: 0.45, blue: 0.95)], label: ""),
    .init(symbol: "music.note", colors: [Color(red: 1, green: 0.4, blue: 0.5), Color(red: 0.95, green: 0.2, blue: 0.35)], label: ""),
]

struct StatusBar: View {
    let width: CGFloat
    var dark = false
    var body: some View {
        HStack {
            Text("9:41").font(.system(size: width * 0.045, weight: .semibold))
            Spacer()
            HStack(spacing: width * 0.012) {
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
            }
            .font(.system(size: width * 0.038, weight: .semibold))
        }
        .foregroundStyle(dark ? .black : .white)
        .padding(.horizontal, width * 0.09)
        .padding(.top, width * 0.045)
    }
}

struct HomeScreen: View {
    let width: CGFloat
    var highlight: (index: Int, amount: Double)? = nil

    var body: some View {
        let icon = width * 0.15
        ZStack(alignment: .top) {
            Wallpaper()
            VStack(spacing: 0) {
                StatusBar(width: width)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 4), spacing: width * 0.065) {
                    ForEach(Array(homeIcons.enumerated()), id: \.offset) { index, item in
                        AppIconView(symbol: item.symbol, colors: item.colors, label: item.label, size: icon,
                                    highlight: highlight?.index == index ? highlight!.amount : 0, glyph: item.glyph)
                    }
                }
                .padding(.horizontal, width * 0.05)
                .padding(.top, width * 0.11)
                Spacer()
                HStack(spacing: width * 0.075) {
                    ForEach(Array(dockIcons.enumerated()), id: \.offset) { _, item in
                        AppIconView(symbol: item.symbol, colors: item.colors, label: "", size: icon)
                    }
                }
                .padding(.vertical, width * 0.045)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: width * 0.1, style: .continuous).fill(.white.opacity(0.18)))
                .padding(.horizontal, width * 0.035)
                .padding(.bottom, width * 0.045)
            }
        }
    }
}

/// A generic weather screen for the "open an app" moment.
struct WeatherScreen: View {
    let width: CGFloat
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.25, green: 0.55, blue: 0.95), Color(red: 0.45, green: 0.72, blue: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: width * 0.02) {
                StatusBar(width: width)
                Spacer().frame(height: width * 0.12)
                Text("San Francisco").font(.system(size: width * 0.085, weight: .regular))
                Text("21°").font(.system(size: width * 0.3, weight: .thin))
                Text("Mostly Sunny").font(.system(size: width * 0.05, weight: .medium)).opacity(0.9)
                Text("H:24°  L:15°").font(.system(size: width * 0.05, weight: .medium)).opacity(0.9)
                HStack(spacing: width * 0.055) {
                    ForEach(0..<5) { i in
                        VStack(spacing: width * 0.025) {
                            Text(["Now", "10", "11", "12", "13"][i]).font(.system(size: width * 0.04, weight: .semibold))
                            Image(systemName: i < 3 ? "sun.max.fill" : "cloud.sun.fill")
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: width * 0.07))
                            Text(["21°", "22°", "23°", "24°", "23°"][i]).font(.system(size: width * 0.045, weight: .semibold))
                        }
                    }
                }
                .padding(width * 0.05)
                .background(RoundedRectangle(cornerRadius: width * 0.06, style: .continuous).fill(.white.opacity(0.18)))
                .padding(.top, width * 0.08)
            }
            .foregroundStyle(.white)
        }
    }
}

struct PhoneMockup<Screen: View>: View {
    let width: CGFloat
    @ViewBuilder var screen: Screen

    var body: some View {
        let height = width * 2.17
        let radius = width * 0.16
        let bezel = width * 0.035
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.06), Color(white: 0.16)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            screen
                .frame(width: width - bezel * 2, height: height - bezel * 2)
                .clipShape(RoundedRectangle(cornerRadius: radius - bezel, style: .continuous))
            Capsule()
                .fill(.black)
                .frame(width: width * 0.3, height: width * 0.085)
                .offset(y: -height / 2 + bezel + width * 0.06)
        }
        .frame(width: width, height: height)
    }
}

/// The window chrome under the phone in Phone Remote: Home + "•••".
struct UnderPhoneControls: View {
    let scale: CGFloat
    var body: some View {
        HStack(spacing: 12 * scale) {
            Text("Home")
                .font(.system(size: 17 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22 * scale)
                .padding(.vertical, 10 * scale)
                .background(Capsule().fill(Color.accent))
            Image(systemName: "ellipsis")
                .font(.system(size: 15 * scale, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40 * scale, height: 40 * scale)
                .background(Circle().fill(.white.opacity(0.18)))
        }
    }
}

// MARK: - Environments

/// A calm sky with mountains, in the spirit of a visionOS environment.
struct SkyEnvironment: View {
    var body: some View {
        GeometryReader { g in
            ZStack {
                LinearGradient(colors: [Color(red: 0.18, green: 0.26, blue: 0.45), Color(red: 0.45, green: 0.55, blue: 0.72),
                                        Color(red: 0.93, green: 0.78, blue: 0.66)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color(red: 1, green: 0.85, blue: 0.7).opacity(0.55), .clear],
                               center: .init(x: 0.7, y: 0.78), startRadius: 0, endRadius: g.size.width * 0.5)
                ForEach(0..<3) { layer in
                    Mountains(seed: layer)
                        .fill(Color(red: 0.16 + Double(layer) * 0.07, green: 0.2 + Double(layer) * 0.07, blue: 0.3 + Double(layer) * 0.07)
                              .opacity(0.95))
                        .frame(height: g.size.height * (0.32 - Double(layer) * 0.07))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }
}

struct Mountains: Shape {
    let seed: Int
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.maxY))
        let peaks = 7 + seed * 2
        for i in 0...peaks {
            let x = rect.width * CGFloat(i) / CGFloat(peaks)
            let wobble = sin(Double(i * (seed + 3)) * 1.7) * 0.5 + 0.5
            let y = rect.height * CGFloat(0.15 + wobble * 0.55)
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct MacDesktop: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.12, green: 0.18, blue: 0.45), Color(red: 0.45, green: 0.3, blue: 0.7),
                                    Color(red: 0.95, green: 0.55, blue: 0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 22) {
                Text("Phone Remote").fontWeight(.bold)
                Text("File"); Text("Edit"); Text("iPhone"); Text("View"); Text("Window")
                Spacer()
                Image(systemName: "wifi")
                Text("Mon 9:41")
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 30)
            .background(Color.black.opacity(0.25))
        }
    }
}

// MARK: - Scenes

struct TitleScene: View {
    let t: Double
    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 34) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 260, height: 260)
                    .scaleEffect(0.85 + 0.15 * ramp(t, 0.1, 1.2))
                    .opacity(ramp(t, 0.1, 0.9))
                Headline(text: "Phone Remote", size: 96).appear(t, at: 0.7)
                Subline(text: "Your iPhone, in a window on Apple Vision Pro or Mac.", size: 38).appear(t, at: 1.3)
            }
        }
    }
}

struct VisionScene: View {
    let t: Double
    var body: some View {
        let phoneWidth: CGFloat = 330
        let highlight = ramp(t, 4.0, 4.6) * (1 - ramp(t, 5.4, 5.7))
        let opened = ramp(t, 5.4, 6.0) * (1 - ramp(t, 9.2, 9.8))
        ZStack {
            SkyEnvironment()
            VStack(spacing: 18) {
                PhoneMockup(width: phoneWidth) {
                    ZStack {
                        HomeScreen(width: phoneWidth, highlight: (4, highlight))
                        WeatherScreen(width: phoneWidth)
                            .opacity(opened)
                            .scaleEffect(0.3 + 0.7 * opened)
                    }
                }
                .shadow(color: .black.opacity(0.45), radius: 40, y: 24)
                UnderPhoneControls(scale: 1)
                    .opacity(ramp(t, 8.3, 9.0))
            }
            .scaleEffect(0.92 + 0.08 * ramp(t, 0, 1.4))
            .offset(y: -10 + 6 * sin(t * 0.8))
            .opacity(ramp(t, 0.2, 1.2))

            VStack {
                Spacer()
                ZStack {
                    Caption(text: "Your iPhone's live screen, floating in Apple Vision Pro.")
                        .opacity(ramp(t, 1.2, 1.8) * (1 - ramp(t, 3.6, 4.0)))
                    Caption(text: "Look and pinch to tap. Swipe, scroll and type.")
                        .opacity(ramp(t, 4.0, 4.6) * (1 - ramp(t, 8.0, 8.4)))
                    Caption(text: "Home is right under the phone. More controls when you want them.")
                        .opacity(ramp(t, 8.4, 9.0))
                }
                .padding(.bottom, 56)
            }
        }
    }
}

struct ChooseScene: View {
    let t: Double
    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 30) {
                Headline(text: "Apple Vision Pro or Mac. Your choice.", size: 60).appear(t, at: 0.2)
                HStack(spacing: 44) {
                    panel(title: "Apple Vision Pro", symbol: "visionpro") {
                        ZStack {
                            SkyEnvironment()
                            VStack(spacing: 8) {
                                PhoneMockup(width: 150) { HomeScreen(width: 150) }
                                    .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
                                UnderPhoneControls(scale: 0.5)
                            }
                        }
                    }
                    .appear(t, at: 0.8, dy: 40)
                    panel(title: "Mac", symbol: "macbook") {
                        ZStack {
                            MacDesktop()
                            VStack(spacing: 8) {
                                PhoneMockup(width: 150) { WeatherScreen(width: 150) }
                                    .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
                                UnderPhoneControls(scale: 0.5)
                            }
                            .padding(.top, 20)
                        }
                    }
                    .appear(t, at: 1.3, dy: 40)
                }
                Subline(text: "The iPhone app mirrors to whichever one has Phone Remote open.", size: 30).appear(t, at: 2.4)
                HStack(spacing: 14) {
                    ForEach(["Click to tap", "Drag or scroll", "Type on the keyboard", "⌘1 Home"], id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(Capsule().fill(.white.opacity(0.1)))
                    }
                }
                .appear(t, at: 4.2)
            }
        }
    }

    func panel<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 14) {
            content()
                .frame(width: 640, height: 470)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 1))
            Label(title, systemImage: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

struct HowScene: View {
    let t: Double
    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 56) {
                Headline(text: "How it works", size: 64).appear(t, at: 0.2)
                HStack(spacing: 0) {
                    device("iphone", "iPhone", "Shares its screen\n(you tap Start Broadcast)").appear(t, at: 0.8)
                    arrow(label: "Home Wi-Fi, direct\nencrypted with a pairing code", progress: ramp(t, 1.6, 2.6))
                    VStack(spacing: 36) {
                        device("visionpro", "Apple Vision Pro", nil).appear(t, at: 2.4)
                        device("macbook", "Mac", nil).appear(t, at: 2.7)
                    }
                }
                HStack(spacing: 24) {
                    bullet("lock.fill", "No cloud, no account, nothing collected").appear(t, at: 4.2)
                    bullet("hand.tap.fill", "Control: a Mac starts Apple's developer testing tool on the iPhone").appear(t, at: 5.4)
                }
                Subline(text: "That's also why it isn't on the App Store: Apple doesn't allow that tool in distributed apps.", size: 26)
                    .appear(t, at: 7.0)
            }
            .padding(.horizontal, 80)
        }
    }

    func device(_ symbol: String, _ name: String, _ note: String?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 92, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 200, height: 130)
                .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(.white.opacity(0.08)))
            Text(name).font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
            if let note {
                Text(note).font(.system(size: 20)).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
            }
        }
        .frame(width: 330)
    }

    func arrow(label: String, progress: Double) -> some View {
        VStack(spacing: 16) {
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12)).frame(width: 420, height: 6)
                Capsule().fill(LinearGradient(colors: [.accent, .mint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 420 * progress, height: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.mint)
                    .offset(x: 420 * progress - 14)
                    .opacity(progress)
            }
            Label(label, systemImage: "lock.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .opacity(progress)
        }
    }

    func bullet(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 24).padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.08)))
    }
}

struct InstallScene: View {
    let t: Double
    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 40) {
                Headline(text: "Install", size: 64).appear(t, at: 0.2)
                HStack(alignment: .top, spacing: 40) {
                    card(title: "A · With a Mac and Xcode", badge: "Includes control", lines: [
                        "Download the project from GitHub",
                        "Connect your iPhone and Vision Pro",
                        "Run one command:",
                    ], code: "./scripts/install.sh YOUR_TEAM_ID",
                         footer: "Builds and installs everything, adds the Mac app, turns on control. A free Apple ID works.")
                        .appear(t, at: 0.9, dy: 40)
                    card(title: "B · Sideload the release files", badge: "Mirroring", lines: [
                        "PhoneRemote-iOS.ipa  →  iPhone",
                        "PhoneRemote-visionOS.ipa  →  Vision Pro",
                        "PhoneRemote-macOS.dmg  →  Mac",
                    ], code: nil,
                         footer: "Install the IPAs with AltStore, SideStore or Sideloadly. For control, the Mac app asks for your Team ID (Xcode needed).")
                        .appear(t, at: 2.2, dy: 40)
                }
                Subline(text: "Free and open source. Not signed by any developer: your tool signs it with your own Apple ID.", size: 26)
                    .appear(t, at: 4.5)
            }
            .padding(.horizontal, 90)
        }
    }

    func card(title: String, badge: String, lines: [String], code: String?, footer: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(title).font(.system(size: 32, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Text(badge)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.mint)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(Color.mint.opacity(0.15)))
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("\(index + 1)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.accent.opacity(0.5)))
                    Text(line).font(.system(size: 24, weight: .medium, design: line.contains(".") ? .monospaced : .default))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            if let code {
                Text(code)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.mint)
                    .padding(.horizontal, 22).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.45)))
            }
            Spacer(minLength: 0)
            Text(footer).font(.system(size: 21)).foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(36)
        .frame(width: 830, height: 470, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

struct PairScene: View {
    let t: Double
    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 44) {
                Headline(text: "Pair once, then start", size: 64).appear(t, at: 0.2)
                    .padding(.bottom, 10)
                HStack(alignment: .top, spacing: 60) {
                    step(1, "Open Phone Remote on your Vision Pro or Mac. It shows a code.") {
                        VStack(spacing: 14) {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .font(.system(size: 40)).foregroundStyle(Color.accent)
                            Text("Waiting for your iPhone").font(.system(size: 20, weight: .semibold))
                            Text("ABCD-2345")
                                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.1)))
                        }
                        .foregroundStyle(.white)
                        .frame(width: 400, height: 390)
                        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white.opacity(0.08)))
                    }
                    .appear(t, at: 0.8, dy: 40)
                    step(2, "On the iPhone, choose it and enter the code.") {
                        PhoneMockup(width: 178) {
                            ZStack {
                                Color(white: 0.1)
                                VStack(spacing: 14) {
                                    Text("Pairing Code").font(.system(size: 13, weight: .semibold))
                                    Text("ABCD-2345")
                                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                                        .padding(8)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12)))
                                    Text("Pair")
                                        .font(.system(size: 13, weight: .semibold))
                                        .frame(width: 120, height: 30)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accent))
                                }
                                .foregroundStyle(.white)
                            }
                        }
                        .frame(height: 390)
                    }
                    .appear(t, at: 1.8, dy: 40)
                    step(3, "Tap Start Mirroring, then Start Broadcast.") {
                        PhoneMockup(width: 178) {
                            ZStack {
                                Color(white: 0.1)
                                VStack(spacing: 12) {
                                    Text("Phone Remote").font(.system(size: 16, weight: .bold))
                                    Label("Start Mirroring", systemImage: "play.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .frame(width: 130, height: 34)
                                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.accent))
                                    Text("Start Broadcast")
                                        .font(.system(size: 12, weight: .semibold))
                                        .frame(width: 130, height: 34)
                                        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.18)))
                                        .opacity(ramp(t, 3.6, 4.2))
                                }
                                .foregroundStyle(.white)
                            }
                        }
                        .frame(height: 390)
                    }
                    .appear(t, at: 2.8, dy: 40)
                }
                Subline(text: "Next time, just open the app on the device you want and tap Start.", size: 28)
                    .appear(t, at: 5.0)
            }
        }
    }

    func step<Content: View>(_ number: Int, _ text: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 24) {
            content()
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(number)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.accent.opacity(0.6)))
                Text(text)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 400, alignment: .leading)
        }
    }
}

struct EndScene: View {
    let t: Double
    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 30) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .opacity(ramp(t, 0.1, 0.8))
                Headline(text: "Phone Remote", size: 80).appear(t, at: 0.5)
                Subline(text: "Free and open source on GitHub. Source code, IPAs and Mac app.", size: 32).appear(t, at: 1.1)
                Subline(text: "Donations welcome, never required.", size: 26).appear(t, at: 1.7)
                Text("A personal project, provided as is. Not affiliated with Apple. iPhone, Apple Vision Pro and Mac are trademarks of Apple Inc.")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.top, 40)
                    .appear(t, at: 2.3, dy: 0)
            }
            .padding(.horizontal, 160)
        }
    }
}

// MARK: - Output

@MainActor
var appIcon: NSImage = {
    let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for candidate in ["assets/icon.png", "../assets/icon.png", here.appendingPathComponent("../assets/icon.png").path] {
        if let image = NSImage(contentsOfFile: candidate) { return image }
    }
    fatalError("Run from the project folder: assets/icon.png not found")
}()

@MainActor
func render(_ time: Double) -> CGImage {
    let renderer = ImageRenderer(content: Frame(time: time))
    renderer.scale = renderScale
    renderer.isOpaque = true
    return renderer.cgImage!
}

@MainActor
func bgra(_ image: CGImage, into context: CGContext) -> Data {
    context.clear(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
    return Data(bytes: context.data!, count: context.bytesPerRow * context.height)
}

@main
struct Main {
    static func main() {
        MainActor.assumeIsolated {
            let args = CommandLine.arguments
            let width = Int(designSize.width * renderScale), height = Int(designSize.height * renderScale)
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            if args.count >= 4, args[1] == "still" {
                let image = render(Double(args[2])!)
                let rep = NSBitmapImageRep(cgImage: image)
                try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
                return
            }
            let out = FileHandle.standardOutput
            let frames = Int(duration * fps)
            for index in 0..<frames {
                autoreleasepool {
                    out.write(bgra(render(Double(index) / fps), into: context))
                }
                if index % 150 == 0 { FileHandle.standardError.write(Data("frame \(index)/\(frames)\n".utf8)) }
            }
        }
    }
}
