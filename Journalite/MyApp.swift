import SwiftUI

@main struct MyApp: App {
    @State private var model = JournalAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
