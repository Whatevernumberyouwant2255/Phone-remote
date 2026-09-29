import SwiftUI

@main
struct TetherVisionApp: App {
    @State private var model = ViewerModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .windowStyle(.plain)
        // The window follows the phone's shape, including rotation.
        .windowResizability(.contentSize)
        .onChange(of: scenePhase, initial: true) { _, phase in
            // visionOS suspends background apps, which would drop the stream anyway.
            if phase == .active { model.start() } else if phase == .background { model.stop() }
        }
    }
}
