import SwiftUI

@main
struct SimNapDemoApp: App {
    init() {
        ScenarioRunner.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
