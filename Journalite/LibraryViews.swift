import SwiftUI

enum NotebookColor: String, CaseIterable, Identifiable {
    case ink, blue, green, purple, orange
    var id: String { rawValue }
    var name: LocalizedStringResource {
        switch self {
        case .ink: "Ink"
        case .blue: "Blue"
        case .green: "Green"
        case .purple: "Purple"
        case .orange: "Orange"
        }
    }
    var color: Color {
        switch self {
        case .ink: .primary
        case .blue: .blue
        case .green: .green
        case .purple: .purple
        case .orange: .orange
        }
    }
}

enum NotebookSymbol: String, CaseIterable, Identifiable {
    case book = "book.closed", leaf = "leaf", heart = "heart", letter = "envelope", star = "star"
    var id: String { rawValue }
    var name: LocalizedStringResource {
        switch self {
        case .book: "Book"
        case .leaf: "Leaf"
        case .heart: "Heart"
        case .letter: "Letter"
        case .star: "Star"
        }
    }
}

struct NotebookRow: View {
    let notebook: NotebookSummary

    var body: some View {
        let color = NotebookColor(rawValue: notebook.colorToken) ?? .ink
        let symbol = NotebookSymbol(rawValue: notebook.symbolName) ?? .book
        HStack(alignment: .top) {
            Image(systemName: symbol.rawValue)
                .foregroundStyle(color.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(notebook.name).font(.headline)
                Text("\(color.name) · \(symbol.name)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct EntryRow: View {
    let entry: EntrySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(entry.title.isEmpty ? String(localized: "Untitled entry") : entry.title).font(.headline)
                if entry.isFavorite {
                    Image(systemName: "star.fill").accessibilityLabel("Favorite")
                }
            }
            if let date = entry.journalDate {
                Text(date, format: .dateTime.year().month().day()).font(.subheadline)
            }
            if entry.notebookUnavailable {
                Label("Notebook unavailable — open to recover", systemImage: "exclamationmark.triangle")
            } else if let name = entry.notebookName {
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct LibraryView: View {
    let model: JournalAppModel
    @State private var creating = false

    var body: some View {
        List {
            Section { CaptureActions(model: model) }
            CaptureRecoverySection(model: model)
            if model.notebooks.isEmpty {
                ContentUnavailableView("No notebooks yet", systemImage: "book.closed",
                    description: Text("Create a notebook for the pages you want to preserve."))
            } else {
                Section("Notebooks") {
                    ForEach(model.notebooks) { notebook in
                        NavigationLink(value: notebook.id) { NotebookRow(notebook: notebook) }
                    }
                }
            }
            Section("Recent entries") {
                if model.recentEntries.isEmpty {
                    Text("No entries yet. Scan or import photos to preserve your first pages.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.recentEntries) { entry in
                        NavigationLink(value: EntryRoute(entryID: entry.id)) { EntryRow(entry: entry) }
                    }
                }
            }
        }
        .navigationTitle("Notebooks")
        .toolbar {
            Button("New Notebook", systemImage: "plus") { creating = true }
        }
        .sheet(isPresented: $creating) { NotebookEditor(model: model, notebook: nil) }
        .refreshable {
            do { try await model.refresh() } catch { model.operationError = true }
        }
    }
}

struct NotebookEditor: View {
    let model: JournalAppModel
    let notebook: NotebookSummary?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: NotebookColor
    @State private var symbol: NotebookSymbol

    init(model: JournalAppModel, notebook: NotebookSummary?) {
        self.model = model
        self.notebook = notebook
        _name = State(initialValue: notebook?.name ?? "")
        _color = State(initialValue: NotebookColor(rawValue: notebook?.colorToken ?? "") ?? .ink)
        _symbol = State(initialValue: NotebookSymbol(rawValue: notebook?.symbolName ?? "") ?? .book)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Notebook name", text: $name)
                    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Enter a name containing more than spaces.").foregroundStyle(.secondary)
                    }
                }
                Picker("Color", selection: $color) {
                    ForEach(NotebookColor.allCases) { color in
                        Label { Text(color.name) } icon: { Image(systemName: "circle.fill").foregroundStyle(color.color) }
                            .tag(color)
                    }
                }
                Picker("Symbol", selection: $symbol) {
                    ForEach(NotebookSymbol.allCases) { symbol in
                        Label { Text(symbol.name) } icon: { Image(systemName: symbol.rawValue) }.tag(symbol)
                    }
                }
            }
            .navigationTitle(notebook == nil ? "New Notebook" : "Edit Notebook")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(model.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(model.isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(model.isSaving)
        }
    }

    private func save() async {
        let saved = await model.change { repository in
            if let notebook {
                try await repository.updateNotebook(id: notebook.id, name: name, colorToken: color.rawValue, symbolName: symbol.rawValue)
            } else {
                _ = try await repository.createNotebook(name: name, colorToken: color.rawValue, symbolName: symbol.rawValue)
            }
        }
        if saved { dismiss() }
    }
}

struct NotebookDetailView: View {
    let model: JournalAppModel
    let notebookID: UUID

    var body: some View {
        Group {
            if let notebook = model.notebooks.first(where: { $0.id == notebookID }) {
                // Every page in the notebook, swipeable left to right.
                NotebookPagerView(model: model, scope: .notebook(notebookID), notebook: notebook)
            } else {
                RecoveryNotice(model: model)
            }
        }
    }
}

struct RecoveryNotice: View {
    let model: JournalAppModel

    var body: some View {
        ContentUnavailableView {
            Label("Item unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text("It may be in Recently Deleted, or a related record may not be available yet. Retry or check Recently Deleted in Settings.")
        } actions: {
            Button("Retry") {
                Task {
                    do { try await model.refresh() } catch { model.operationError = true }
                }
            }
        }
    }
}

struct RemoveNotebookView: View {
    let model: JournalAppModel
    let notebook: NotebookSummary
    @Environment(\.dismiss) private var dismiss
    @State private var destination: UUID?
    @State private var confirming = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Keep the entries in another notebook, or move this notebook and its contents to Recently Deleted.")
                    Picker("Move entries to", selection: $destination) {
                        Text("Choose a notebook").tag(UUID?.none)
                        ForEach(model.notebooks.filter { $0.id != notebook.id }) { item in
                            Text(item.name).tag(Optional(item.id))
                        }
                    }
                    Button("Move All Entries and Remove Notebook") {
                        Task {
                            if let destination, await model.change({
                                try await $0.trashNotebook(id: notebook.id, movingEntriesTo: destination)
                            }) { dismiss() }
                        }
                    }
                    .disabled(destination == nil || model.isSaving)
                    Text("Previously deleted entries stay in Recently Deleted after a move. Create another notebook first if needed.")
                        .font(.footnote)
                }
                Section {
                    Button("Move Notebook and Contents to Recently Deleted", role: .destructive) { confirming = true }
                        .disabled(model.isSaving)
                } footer: {
                    Text("Nothing expires automatically. You can restore these items later.")
                }
            }
            .navigationTitle("Remove Notebook")
            .toolbar { Button("Cancel") { dismiss() }.disabled(model.isSaving) }
            .confirmationDialog("Move this notebook and all its live entries to Recently Deleted?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Move to Recently Deleted", role: .destructive) {
                    Task {
                        if await model.change({ try await $0.trashNotebook(id: notebook.id) }) { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(model.isSaving)
        }
    }
}
