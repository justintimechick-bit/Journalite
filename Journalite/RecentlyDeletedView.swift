import SwiftUI

private struct DeletionSelection {
    let id: UUID
    let isNotebook: Bool
}

struct RecentlyDeletedView: View {
    let model: JournalAppModel
    @State private var notebooks: [NotebookSummary] = []
    @State private var pager = EntryPager()
    @State private var failed = false
    @State private var pending: DeletionSelection?
    @State private var confirming = false

    var body: some View {
        List {
            Section {
                Text("Items remain here until you permanently delete them. There is no automatic expiry.")
                Text("Restore returns an entry to its original live notebook. If that notebook is unavailable, it goes to Restored Entries.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if failed || pager.failed {
                Button("Couldn’t load deleted items. Retry") { Task { await reload() } }
            }
            if notebooks.isEmpty && pager.entries.isEmpty && !pager.isLoading && !failed && !pager.failed {
                ContentUnavailableView("Nothing in Recently Deleted", systemImage: "trash")
            }
            Section("Notebooks") {
                ForEach(notebooks) { notebook in
                    VStack(alignment: .leading, spacing: 8) {
                        NotebookRow(notebook: notebook)
                        Button("Restore Notebook and Its Entries") {
                            Task { _ = await model.change { try await $0.restoreNotebook(id: notebook.id) } }
                        }
                        Button("Permanently Delete Notebook", role: .destructive) {
                            pending = DeletionSelection(id: notebook.id, isNotebook: true)
                            confirming = true
                        }
                    }
                    .disabled(model.isSaving)
                }
            }
            Section("Entries") {
                ForEach(pager.entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        EntryRow(entry: entry)
                        Button("Restore Entry") {
                            Task { _ = await model.change { try await $0.restoreEntry(id: entry.id) } }
                        }
                        Button("Permanently Delete Entry", role: .destructive) {
                            pending = DeletionSelection(id: entry.id, isNotebook: false)
                            confirming = true
                        }
                    }
                    .disabled(model.isSaving)
                }
                if pager.isLoading { ProgressView("Loading deleted entries…") }
                if pager.hasMore {
                    Button("Load More Deleted Entries") {
                        Task { await pager.load(model: model, trashed: true, reset: false) }
                    }
                    .disabled(pager.isLoading)
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .task(id: model.revision) { await reload() }
        .refreshable { await reload() }
        .confirmationDialog("Permanently delete?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Permanently Delete", role: .destructive) {
                guard let selection = pending else { return }
                Task {
                    _ = await model.change { try await $0.permanentlyDelete(id: selection.id, notebook: selection.isNotebook) }
                    pending = nil
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            if pending?.isNotebook == true {
                Text("This permanently removes the notebook and ALL entries still in it, including previously deleted entries, photos and revision history. This cannot be undone.")
            } else {
                Text("This permanently removes the entry, its photos and revision history. This cannot be undone.")
            }
        }
    }

    private func reload() async {
        do {
            guard let repository = model.repository else { throw PersistenceError.notLoaded }
            notebooks = try await repository.notebooks(trashed: true)
            failed = false
        } catch { failed = true }
        await pager.load(model: model, trashed: true, reset: true)
    }
}
