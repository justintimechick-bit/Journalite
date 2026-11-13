import SwiftUI

struct ContentView: View {
    @Bindable var model: JournalAppModel

    var body: some View {
        Group {
            switch model.status {
            case .idle, .loading:
                ProgressView("Opening your journal…")
            case .failed:
                StoreRecoveryView(model: model)
            case .ready:
                if model.hasStarted {
                    JournalTabsView(model: model)
                } else {
                    WelcomeView(model: model)
                }
            }
        }
        .task { await model.load() }
        .modifier(OCRLifecycle(coordinator: model.ocr))
        .modifier(CapturePresentation(model: model, coordinator: model.capture))
        .alert("Couldn’t complete or refresh the change", isPresented: $model.operationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your library before trying again. Your journal files have not been reset or deleted.")
        }
    }
}

private struct WelcomeView: View {
    let model: JournalAppModel
    @State private var selected: Set<String> = []
    private let suggestions = ["Bible Notes", "Personal Motivation", "Letters to My Family"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Keep the page. Find the words.")
                        .font(.title2.bold())
                    Text("Journalite is designed to preserve photos of your handwritten journals and make their words searchable on your iPhone.")
                    Text("Scan or import your pages and keep their photos in notebooks. Transcribe them on this iPhone, review the text beside the photo, and search your pages.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(suggestions, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { selected.contains(name) },
                            set: { if $0 { selected.insert(name) } else { selected.remove(name) } }
                        ))
                    }
                } header: {
                    Text("Optional starter notebooks")
                } footer: {
                    Text("Only the notebooks you choose will be created. You can also start with an empty library.")
                }
                Section {
                    Button("Start on this iPhone") {
                        Task { await model.start(names: suggestions.filter { selected.contains($0) }) }
                    }
                    .disabled(model.isSaving)
                    Text("No account required. No camera or photo-library access is requested on launch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Welcome to Journalite")
        }
    }
}

private struct JournalTabsView: View {
    let model: JournalAppModel

    var body: some View {
        TabView {
            NavigationStack {
                LibraryView(model: model)
                    .navigationDestination(for: UUID.self) { id in
                        NotebookDetailView(model: model, notebookID: id)
                    }
                    .navigationDestination(for: EntryRoute.self) { route in
                        EntryDetailView(model: model, route: route)
                    }
            }
            .tabItem { Label("Notebooks", systemImage: "book.closed") }
            NavigationStack {
                SearchView(model: model)
                    .navigationDestination(for: EntryRoute.self) { route in
                        EntryDetailView(model: model, route: route)
                    }
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            NavigationStack {
                Form {
                    OCRSettingsSection(coordinator: model.ocr)
                    SearchSettingsSection(search: model.search)
                    Section("Storage") {
                        if model.isPreview {
                            Label("Preview — temporary memory only", systemImage: "eye")
                        } else {
                            Label("Your journal is stored on this iPhone", systemImage: "iphone")
                        }
                        Text("iCloud sync and Sign in with Apple are not enabled. Journal content is not uploaded by this app.")
                    }
                    Section {
                        NavigationLink("Recently Deleted") { RecentlyDeletedView(model: model) }
                    } footer: {
                        Text("Deleted items remain until you permanently delete them. There is no automatic expiry.")
                    }
                }
                .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

private struct StoreRecoveryView: View {
    let model: JournalAppModel

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t open your journal", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("Your existing files have not been deleted. Check available device storage and try again. If this continues, keep the app installed and preserve a device backup before seeking recovery help. Archive export is not available in this version; do not delete or reinstall the app to reset it.")
        } actions: {
            Button("Try Again") {
                Task { await model.load() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}


#Preview {
    ContentView(model: JournalAppModel(isPreview: true))
}
