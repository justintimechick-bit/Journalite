import SwiftUI
import Observation
import PhotosUI
#if os(iOS)
import UIKit
#endif

// MARK: - Model

/// What the pager shows: every live page in a notebook, or the pages of a single entry
/// (used by Search and Recent Entries, including entries whose notebook is unavailable).
enum PagerScope: Hashable {
    case notebook(UUID)
    case entry(UUID)
}

/// One page in the flattened, left-to-right sequence.
struct PagerPage: Identifiable, Hashable {
    let id: UUID
    let entryID: UUID
    let indexInEntry: Int
    let entryPageCount: Int
    let previewText: String?
}

nonisolated enum PagerTitle {
    /// The first non-empty line of the page's text, or "Page N".
    static func title(text: String?, pageNumber: Int) -> String {
        let line = text?
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return String(localized: "Page \(pageNumber)") }
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }
}

/// Loads the pages of a scope and owns per-page detail, images, drafts and auto-save.
@MainActor
@Observable
final class NotebookPagerStore {
    private(set) var pages: [PagerPage] = []
    private(set) var entries: [UUID: EntrySummary] = [:]
    private(set) var details: [UUID: PageDetail] = [:]
    private(set) var imageURLs: [UUID: URL] = [:]
    private(set) var failedDetails: Set<UUID> = []
    private(set) var savingPageIDs: Set<UUID> = []
    private(set) var justSavedPageID: UUID?
    private(set) var loadedOnce = false
    private(set) var failed = false
    let drafts = EntryDraftCoordinator()

    func index(of pageID: UUID?) -> Int? {
        guard let pageID else { return nil }
        return pages.firstIndex { $0.id == pageID }
    }

    /// Reloads the page list in place. Returns the IDs of pages that were not present before.
    @discardableResult
    func load(model: JournalAppModel, scope: PagerScope) async -> [UUID] {
        do {
            guard let repository = model.repository else { throw PersistenceError.notLoaded }
            var summaries: [EntrySummary] = []
            switch scope {
            case .notebook(let notebookID):
                var offset = 0
                while true {
                    let batch = try await repository.entries(notebookID: notebookID, offset: offset, limit: 100)
                    summaries += batch.entries
                    offset += batch.entries.count
                    if !batch.hasMore || batch.entries.isEmpty { break }
                }
                // The store lists newest first; a notebook reads oldest to newest, left to right.
                summaries.reverse()
            case .entry(let entryID):
                summaries = [try await repository.entry(id: entryID)]
            }
            var flattened: [PagerPage] = []
            for entry in summaries {
                let entryPages = try await repository.pages(entryID: entry.id)
                for (index, page) in entryPages.enumerated() {
                    flattened.append(PagerPage(id: page.id, entryID: entry.id, indexInEntry: index,
                                               entryPageCount: entryPages.count, previewText: page.text))
                }
            }
            guard !Task.isCancelled else { return [] }
            let known = Set(pages.map(\.id))
            let wasLoaded = loadedOnce
            entries = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            pages = flattened
            failed = false
            loadedOnce = true
            return wasLoaded ? flattened.map(\.id).filter { !known.contains($0) } : []
        } catch {
            if !Task.isCancelled {
                failed = true
                loadedOnce = true
            }
            return []
        }
    }

    func loadDetail(pageID: UUID, model: JournalAppModel) async {
        guard let repository = model.repository else { return }
        do {
            let detail = try await repository.pageDetail(pageID: pageID)
            let previous = details[pageID]
            let needsImage = imageURLs[pageID] == nil || previous?.imageVersion != detail?.imageVersion
            let image = needsImage
                ? try? await JournalImageCache.shared.image(pageID: pageID, repository: repository, kind: .display)
                : imageURLs[pageID]
            guard !Task.isCancelled else { return }
            if let detail {
                drafts.reconcile(with: detail)
                details[pageID] = detail
                failedDetails.remove(pageID)
            } else {
                failedDetails.insert(pageID)
            }
            if let image { imageURLs[pageID] = image }
        } catch {
            if !Task.isCancelled { failedDetails.insert(pageID) }
        }
    }

    /// Saves the page's draft as a new manual revision, exactly as typed. Drafts whose saved
    /// text changed underneath them are never auto-saved; the page shows a Review Changes banner.
    @discardableResult
    func save(pageID: UUID, model: JournalAppModel, resolvingConflict: Bool = false) async -> Bool {
        guard let page = details[pageID] else { return false }
        guard drafts.canSave(page) else { return !drafts.isDirty(for: pageID) }
        guard !savingPageIDs.contains(pageID) else { return false }
        if !resolvingConflict, drafts.conflict(for: page) != .noConflict { return false }

        savingPageIDs.insert(pageID)
        defer { savingPageIDs.remove(pageID) }
        // Another page may be mid-save; writes are serialized by the app model.
        for _ in 0..<50 where model.isSaving {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let text = drafts.draft(for: page)
        let base = drafts.baseRevisionID(for: pageID)
        let saved = await model.change {
            try await $0.appendCorrection(pageID: pageID, text: text, baseRevisionID: .some(base))
        }
        guard saved else { return false }
        await loadDetail(pageID: pageID, model: model)
        if let latest = details[pageID], drafts.isDirty(for: pageID) {
            if drafts.draft(for: latest) == text {
                drafts.clearDraft(for: pageID)
            } else if latest.canonicalResolution.displayText == text {
                // The user kept typing while this save ran. Keep that text, based on the revision just saved.
                drafts.keepDraftAsLatest(for: latest)
            }
        }
        justSavedPageID = pageID
        Task {
            try? await Task.sleep(for: .seconds(2))
            if justSavedPageID == pageID { justSavedPageID = nil }
        }
        return true
    }

    func saveAllDirty(model: JournalAppModel) async {
        for pageID in drafts.dirtyPageIDs {
            await save(pageID: pageID, model: model)
        }
    }

    /// Dirty pages that cannot be auto-saved because their saved text changed while editing.
    var blockedDraftPageIDs: Set<UUID> {
        Set(drafts.dirtyPageIDs.filter { id in
            guard let page = details[id] else { return true }
            return drafts.conflict(for: page) != .noConflict || !page.canonicalResolution.allowsEditing
        })
    }
}

// MARK: - Pager

struct NotebookPagerView: View {
    let model: JournalAppModel
    let scope: PagerScope
    var notebook: NotebookSummary? = nil
    var initialPageID: UUID? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var store = NotebookPagerStore()
    @State private var activePageID: UUID?
    @FocusState private var focusedPageID: UUID?
    @State private var awaitingNewPage = false

    @State private var showingOverview = false
    @State private var lightboxPageID: UUID?
    @State private var revisionsPageID: UUID?
    @State private var conflictPageID: UUID?
    @State private var retryTarget: PageDetail?
    @State private var editingEntry: EntrySummary?
    @State private var managingEntryID: UUID?
    @State private var trashingEntryID: UUID?
    @State private var editingNotebook = false
    @State private var removingNotebook = false
    @State private var leaving = false
    @State private var showingPhotoPicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var reviewedFeedback = 0

    private var activeIndex: Int { store.index(of: activePageID) ?? 0 }
    private var activePage: PagerPage? { store.pages.first { $0.id == activePageID } }

    private var notebookID: UUID? {
        if case .notebook(let id) = scope { return id }
        return nil
    }

    private var title: String {
        switch scope {
        case .notebook:
            return notebook?.name ?? String(localized: "Notebook")
        case .entry(let id):
            guard let entry = store.entries[id], !entry.title.isEmpty else { return String(localized: "Entry") }
            return entry.title
        }
    }

    private var captureBusy: Bool {
        model.capture.busy || model.capture.saving || model.capture.showReview || model.capture.showScanner || isImporting
    }

    var body: some View {
        presentations(sheets(lifecycle(content)))
    }

    private func lifecycle(_ view: some View) -> some View {
        view
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            // Drafts that can't be auto-saved need an explicit choice before leaving.
            .navigationBarBackButtonHidden(!store.blockedDraftPageIDs.isEmpty)
            .toolbar { toolbarContent }
            .task(id: "\(model.revision)-\(model.ocr.revision)") { await reload() }
            .onChange(of: activePageID) { old, new in
                if let old, old != new {
                    if focusedPageID == old { focusedPageID = nil }
                    autoSave(old)
                }
            }
            .onChange(of: focusedPageID) { old, new in
                if let old, old != new { autoSave(old) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { Task { await store.saveAllDirty(model: model) } }
            }
            .onDisappear {
                let store = store
                Task { await store.saveAllDirty(model: model) }
            }
            .sensoryFeedback(.selection, trigger: activePageID) { old, new in old != nil && new != nil }
            .sensoryFeedback(.success, trigger: reviewedFeedback)
    }

    private func sheets(_ view: some View) -> some View {
        view
            .sheet(isPresented: $showingOverview) {
                PageOverviewGrid(model: model, store: store, activePageID: activePageID) { id in
                    activePageID = id
                }
            }
            .fullScreenCover(item: Binding(
                get: { lightboxPageID.map(IdentifiedPage.init) },
                set: { lightboxPageID = $0?.id }
            )) { item in
                PageLightbox(model: model, pageID: item.id, pageNumber: (store.index(of: item.id) ?? 0) + 1)
            }
            .sheet(item: Binding(
                get: { revisionsPageID.flatMap { store.details[$0] }.map(IdentifiedDetail.init) },
                set: { revisionsPageID = $0?.id }
            )) { item in
                RevisionHistorySheet(model: model, page: item.detail, pageNumber: (store.index(of: item.id) ?? 0) + 1) {
                    Task { await store.loadDetail(pageID: item.id, model: model) }
                }
            }
            .sheet(item: Binding(
                get: { conflictPageID.flatMap { store.details[$0] }.map(IdentifiedDetail.init) },
                set: { conflictPageID = $0?.id }
            )) { item in
                DraftConflictSheet(page: item.detail, pageNumber: (store.index(of: item.id) ?? 0) + 1, drafts: store.drafts) {
                    Task { await store.save(pageID: item.id, model: model, resolvingConflict: true) }
                }
            }
            .sheet(item: $editingEntry) { entry in
                EntryEditor(model: model, entry: entry)
            }
            .sheet(item: Binding(
                get: { managingEntryID.map(IdentifiedPage.init) },
                set: { managingEntryID = $0?.id }
            )) { item in
                ManagePagesView(model: model, entryID: item.id,
                                unsavedPageIDs: store.drafts.dirtyPageIDs) { newID in
                    awaitingNewPage = false
                    activePageID = newID
                }
            }
            .sheet(isPresented: $editingNotebook) {
                if let notebook { NotebookEditor(model: model, notebook: notebook) }
            }
            .sheet(isPresented: $removingNotebook) {
                if let notebook { RemoveNotebookView(model: model, notebook: notebook) }
            }
    }

    private func presentations(_ view: some View) -> some View {
        view
            .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhotos,
                          maxSelectionCount: ImportLimits.pages, selectionBehavior: .ordered,
                          matching: .images, preferredItemEncoding: .current)
            .onChange(of: selectedPhotos) { _, items in startImport(items) }
            .alert("Retry Transcription?", isPresented: Binding(
                get: { retryTarget != nil },
                set: { if !$0 { retryTarget = nil } }
            ), presenting: retryTarget) { page in
                Button("Retry") { Task { await runRetry(pageID: page.id) } }
                Button("Cancel", role: .cancel) {}
            } message: { page in
                Text(retryExplanation(for: page))
            }
            .confirmationDialog("Move this entry to Recently Deleted?", isPresented: Binding(
                get: { trashingEntryID != nil },
                set: { if !$0 { trashingEntryID = nil } }
            ), titleVisibility: .visible, presenting: trashingEntryID) { entryID in
                Button("Move to Recently Deleted", role: .destructive) { Task { await trashEntry(entryID) } }
            } message: { entryID in
                let count = store.pages.filter { $0.entryID == entryID }.count
                Text("All \(count) pages of this entry move with it, including their photos and revisions. You can restore it later.")
            }
            .confirmationDialog("Leave with unsaved changes?", isPresented: $leaving, titleVisibility: .visible) {
                Button("Discard Unsaved Changes and Leave", role: .destructive) {
                    for id in store.blockedDraftPageIDs { store.drafts.clearDraft(for: id) }
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Some pages changed while you were editing, so your text wasn’t saved automatically. Open those pages and choose Review Changes to keep your text.")
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !store.loadedOnce {
            ProgressView("Opening pages…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.failed {
            ContentUnavailableView {
                Label("Pages unavailable", systemImage: "doc.badge.ellipsis")
            } description: {
                Text("They may be in Recently Deleted or not available yet. Nothing has been changed.")
            } actions: {
                Button("Retry") { Task { await reload() } }
                    .buttonStyle(.borderedProminent)
            }
        } else if store.pages.isEmpty {
            emptyState
        } else {
            pager
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No pages yet", systemImage: "doc.viewfinder")
        } description: {
            Text("Scan a handwritten page or import photos. Pages are transcribed on this iPhone and nothing is uploaded.")
        } actions: {
            if notebookID != nil {
                Button { startScan() } label: {
                    Label("Scan Page", systemImage: "camera.viewfinder")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(captureBusy)

                Button { showingPhotoPicker = true } label: {
                    Label("Import Photos", systemImage: "photo.on.rectangle")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(captureBusy)
            } else if case .entry(let entryID) = scope {
                Button { managingEntryID = entryID } label: {
                    Label("Add Pages", systemImage: "plus")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var pager: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(store.pages.enumerated()), id: \.element.id) { offset, page in
                        NotebookPageColumn(
                            model: model,
                            store: store,
                            page: page,
                            entry: store.entries[page.entryID],
                            pageNumber: offset + 1,
                            pageCount: store.pages.count,
                            imageHeight: max(160, proxy.size.height * 0.38),
                            focus: $focusedPageID,
                            onZoom: { lightboxPageID = page.id },
                            onRetry: { requestRetry($0) },
                            onRevisions: { revisionsPageID = page.id },
                            onReviewConflict: { conflictPageID = page.id },
                            onToggleReviewed: { toggleReviewed($0) }
                        )
                        .containerRelativeFrame(.horizontal, count: 1, span: 1, spacing: 0)
                    }
                }
                .scrollTargetLayout()
            }
            .modifier(OnePageSnapping())
            .scrollPosition(id: $activePageID)
            .overlay(alignment: .bottom) {
                if focusedPageID == nil {
                    PagePill(store: store, activePageID: $activePageID)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: focusedPageID == nil)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !store.blockedDraftPageIDs.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button { leaving = true } label: { Label("Back", systemImage: "chevron.backward") }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showingOverview = true } label: {
                Label("Page Overview", systemImage: "square.grid.2x2")
            }
            .disabled(store.pages.isEmpty)

            addPageMenu
            moreMenu
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { focusedPageID = nil }
                .bold()
        }
    }

    @ViewBuilder
    private var addPageMenu: some View {
        switch scope {
        case .notebook:
            Menu {
                Button { startScan() } label: { Label("Scan Page", systemImage: "camera.viewfinder") }
                Button { showingPhotoPicker = true } label: { Label("Import Photos", systemImage: "photo.on.rectangle") }
            } label: {
                if isImporting {
                    ProgressView()
                } else {
                    Label("Add Page", systemImage: "plus")
                }
            }
            .disabled(captureBusy)
        case .entry(let entryID):
            Button { managingEntryID = entryID } label: { Label("Add Page", systemImage: "plus") }
        }
    }

    private var moreMenu: some View {
        Menu {
            if let page = activePage {
                Section("This Entry") {
                    if let entry = store.entries[page.entryID] {
                        Button { editingEntry = entry } label: { Label("Edit Entry Details", systemImage: "pencil") }
                    }
                    Button { managingEntryID = page.entryID } label: {
                        Label("Reorder or Remove Pages", systemImage: "square.stack.3d.up")
                    }
                    Button(role: .destructive) { trashingEntryID = page.entryID } label: {
                        Label("Move Entry to Recently Deleted", systemImage: "trash")
                    }
                }
            }
            if notebook != nil {
                Section("Notebook") {
                    Button { editingNotebook = true } label: { Label("Edit Notebook", systemImage: "book.closed") }
                    Button(role: .destructive) { removingNotebook = true } label: {
                        Label("Remove Notebook", systemImage: "trash")
                    }
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    // MARK: Actions

    private func reload() async {
        let wasLoaded = store.loadedOnce
        let previousIndex = store.index(of: activePageID)
        let newIDs = await store.load(model: model, scope: scope)
        let ids = store.pages.map(\.id)
        if !wasLoaded {
            activePageID = EntryNavigation.pageToShow(current: nil, livePageIDs: ids, target: initialPageID)
        } else if awaitingNewPage, let first = newIDs.first {
            awaitingNewPage = false
            withAnimation(.snappy) { activePageID = first }
        } else if let current = activePageID, !ids.contains(current) {
            // The page was removed; stay at the same position in the notebook.
            activePageID = ids.isEmpty ? nil : ids[min(previousIndex ?? 0, ids.count - 1)]
        } else if activePageID == nil {
            activePageID = ids.first
        }
    }

    private func autoSave(_ pageID: UUID) {
        guard store.drafts.isDirty(for: pageID) else { return }
        Task { await store.save(pageID: pageID, model: model) }
    }

    private func startScan() {
        guard let notebookID else { return }
        awaitingNewPage = true
        Task { await model.capture.scan(notebookID: notebookID) }
    }

    private func startImport(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, !isImporting, let repository = model.repository, let notebookID else { return }
        isImporting = true
        awaitingNewPage = true
        model.capture.startImport(items, notebookID: notebookID, repository: repository)
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            selectedPhotos = []
            isImporting = false
        }
    }

    private func toggleReviewed(_ page: PageDetail) {
        Task {
            // Review applies to saved text, so save what's on screen first.
            if store.drafts.isDirty(for: page.id) {
                guard await store.save(pageID: page.id, model: model) else {
                    if let latest = store.details[page.id], store.drafts.conflict(for: latest) != .noConflict {
                        conflictPageID = page.id
                    }
                    return
                }
            }
            guard let latest = store.details[page.id] else { return }
            let marking = !latest.isReviewed
            if await model.change({ try await $0.markPageReviewed(pageID: page.id, reviewed: marking) }) {
                await store.loadDetail(pageID: page.id, model: model)
                if marking { reviewedFeedback += 1 }
            }
        }
    }

    /// Pages with saved text get an explanation first; untranscribed pages run straight away.
    private func requestRetry(_ page: PageDetail) {
        if page.ocrResultID == nil && page.selectedRevisionID == nil {
            Task { await runRetry(pageID: page.id) }
        } else {
            retryTarget = page
        }
    }

    private func retryExplanation(for page: PageDetail) -> String {
        var parts = [String(localized: "Text recognition runs again on this page’s original photo, and the new result becomes the page’s current text.")]
        if page.revisions.isEmpty {
            parts.append(String(localized: "The current transcription will be replaced."))
        } else {
            parts.append(String(localized: "Your saved corrections are retained in Revisions and can be restored at any time."))
        }
        if store.drafts.isDirty(for: page.id) {
            parts.append(String(localized: "Your unsaved text is kept, and you can choose what to keep when the new text arrives."))
        }
        return parts.joined(separator: " ")
    }

    private func runRetry(pageID: UUID) async {
        await model.ocr.retry(pageID: pageID)
        await store.loadDetail(pageID: pageID, model: model)
    }

    private func trashEntry(_ entryID: UUID) async {
        let pageIDs = store.pages.filter { $0.entryID == entryID }.map(\.id)
        if await model.change({ try await $0.trashEntry(id: entryID) }) {
            for id in pageIDs { store.drafts.clearDraft(for: id) }
            if case .entry = scope { dismiss() }
        }
    }
}

/// Wraps a UUID so optional-ID state can drive `sheet(item:)`.
private struct IdentifiedPage: Identifiable {
    let id: UUID
}

private struct IdentifiedDetail: Identifiable {
    let detail: PageDetail
    var id: UUID { detail.id }
}

// MARK: - Page Column

private struct NotebookPageColumn: View {
    let model: JournalAppModel
    let store: NotebookPagerStore
    let page: PagerPage
    let entry: EntrySummary?
    let pageNumber: Int
    let pageCount: Int
    let imageHeight: CGFloat
    var focus: FocusState<UUID?>.Binding
    let onZoom: () -> Void
    let onRetry: (PageDetail) -> Void
    let onRevisions: () -> Void
    let onReviewConflict: () -> Void
    let onToggleReviewed: (PageDetail) -> Void

    @State private var copied = false
    @State private var copyFeedback = 0

    private var detail: PageDetail? { store.details[page.id] }
    private var isEditing: Bool { focus.wrappedValue == page.id }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    PageImageCard(url: store.imageURLs[page.id], pageNumber: pageNumber,
                                  height: isEditing ? imageHeight * 0.55 : imageHeight, onZoom: onZoom)

                    if let detail {
                        statusBar(detail)
                        OCRStatusBanner(coordinator: model.ocr, page: detail) { onRetry(detail) }
                        transcriptionCard(detail)
                            .id("transcription")
                    } else if store.failedDetails.contains(page.id) {
                        ContentUnavailableView {
                            Label("Page unavailable", systemImage: "doc.questionmark")
                        } description: {
                            Text("This page could not be loaded. Its photo and text have not been changed.")
                        } actions: {
                            Button("Retry") { Task { await store.loadDetail(pageID: page.id, model: model) } }
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                // Room for the floating page pill.
                .padding(.bottom, 88)
                .animation(.snappy, value: isEditing)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: isEditing) { _, editing in
                guard editing else { return }
                Task {
                    // Wait for the keyboard to settle before bringing the editor into view.
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation(.snappy) { reader.scrollTo("transcription", anchor: .top) }
                }
            }
        }
        .task(id: "\(page.id)-\(model.revision)-\(model.ocr.revision)") {
            await store.loadDetail(pageID: page.id, model: model)
        }
        .sensoryFeedback(.success, trigger: copyFeedback)
    }

    // MARK: Status bar

    private func statusBar(_ detail: PageDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PagerTitle.title(text: store.drafts.draft(for: detail), pageNumber: pageNumber))
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let date = entry?.journalDate {
                        Text(date, format: .dateTime.month(.abbreviated).day().year())
                    }
                    if page.entryPageCount > 1 {
                        if entry?.journalDate != nil { Text("·") }
                        Text("Page \(page.indexInEntry + 1) of \(page.entryPageCount) in this entry")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 10) {
                reviewPill(detail)
                Spacer(minLength: 0)
                iconButton(copied ? "Copied" : "Copy Text",
                           systemImage: copied ? "checkmark" : "doc.on.doc",
                           tint: copied ? .green : nil) { copy(detail) }
                    .disabled(store.drafts.draft(for: detail).isEmpty)
                iconButton("Retry Transcription", systemImage: "arrow.clockwise") { onRetry(detail) }
                iconButton("Revisions (\(detail.revisions.count))", systemImage: "clock.arrow.circlepath",
                           action: onRevisions)
                    .overlay(alignment: .topTrailing) {
                        if !detail.revisions.isEmpty {
                            Text("\(detail.revisions.count)")
                                .font(.caption2.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor, in: Capsule())
                                .offset(x: 4, y: -4)
                                .accessibilityHidden(true)
                        }
                    }
            }
        }
    }

    private func reviewPill(_ detail: PageDetail) -> some View {
        let reviewed = detail.isReviewed
        let tint: Color = reviewed ? .green : .orange
        return Button { onToggleReviewed(detail) } label: {
            Label(reviewed ? "Reviewed" : "Needs Review",
                  systemImage: reviewed ? "checkmark.seal.fill" : "exclamationmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(tint.opacity(0.15), in: Capsule())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!detail.canonicalResolution.allowsReview || model.isSaving)
        .opacity(detail.canonicalResolution.allowsReview ? 1 : 0.5)
        .accessibilityLabel(reviewed ? "Reviewed" : "Needs Review")
        .accessibilityHint(reviewed ? "Double-tap to mark as needs review" : "Double-tap to mark as reviewed")
    }

    private func iconButton(_ label: LocalizedStringKey, systemImage: String, tint: Color? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(tint ?? .accentColor)
                .frame(width: 40, height: 40)
                .background(Color(.tertiarySystemGroupedBackground), in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    // MARK: Transcription

    private func transcriptionCard(_ detail: PageDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Transcription", systemImage: "text.alignleft")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                saveState(detail)
            }

            if store.drafts.conflict(for: detail) != .noConflict {
                conflictBanner
            }

            if detail.canonicalResolution.allowsEditing {
                TextField(placeholder(for: detail), text: Binding(
                    get: { store.drafts.draft(for: detail) },
                    set: { store.drafts.setDraft($0, for: detail) }
                ), axis: .vertical)
                .font(.body)
                .lineSpacing(4)
                .focused(focus, equals: page.id)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                // Tapping the empty space below short text also starts editing.
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { focus.wrappedValue = page.id }
                }
                .accessibilityLabel("Transcription for page \(pageNumber)")
            } else {
                missingRevisionPanel
            }

            if detail.lowConfidenceLineCount > 0, case .rawOCR = detail.canonicalResolution {
                Label("\(detail.lowConfidenceLineCount) lines have low confidence. Compare them with the photo.",
                      systemImage: "exclamationmark.magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text(footer(for: detail))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func saveState(_ detail: PageDetail) -> some View {
        Group {
            if store.savingPageIDs.contains(page.id) {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Saving…")
                }
            } else if store.drafts.isDirty(for: page.id) {
                Text("Edited")
            } else if store.justSavedPageID == page.id {
                Label("Saved", systemImage: "checkmark")
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .transition(.opacity)
    }

    private func placeholder(for detail: PageDetail) -> String {
        switch detail.canonicalResolution {
        case .emptyNoTranscription: String(localized: "Not transcribed yet. Tap to type this page’s text.")
        case .rawOCR(_, _, true), .manualRevision(_, _, true): String(localized: "This page is blank. Tap to add text.")
        default: String(localized: "Tap to type this page’s text.")
        }
    }

    private func footer(for detail: PageDetail) -> String {
        let engine = OCREngine.displayName(detail.ocrEngine)
        switch detail.canonicalResolution {
        case .manualRevision:
            if let engine { return String(localized: "Edited by you. Originally transcribed by \(engine).") }
            return String(localized: "Edited by you. Saved on this iPhone.")
        case .rawOCR:
            if let engine { return String(localized: "Transcribed by \(engine)") }
            return String(localized: "Transcribed on this iPhone. Nothing is uploaded.")
        case .missingSelectedRevision, .emptyNoTranscription:
            return String(localized: "Transcription runs on this iPhone. Nothing is uploaded.")
        }
    }

    private var conflictBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This page changed while you were editing", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Your text is kept but wasn’t saved automatically. Review the changes to choose what to keep.")
                .font(.caption)
            Button("Review Changes", action: onReviewConflict)
                .font(.caption.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var missingRevisionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for the selected revision")
                    .font(.headline)
            }
            Text("This page’s chosen transcription hasn’t arrived on this iPhone yet. Journalite keeps that choice instead of showing other text, and editing is paused until it arrives.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Check Again") { Task { await store.loadDetail(pageID: page.id, model: model) } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copy(_ detail: PageDetail) {
        let text = store.drafts.draft(for: detail)
        guard !text.isEmpty else { return }
        #if os(iOS)
        UIPasteboard.general.string = text
        #endif
        copyFeedback += 1
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = false }
        }
    }
}

// MARK: - Image Card

private struct PageImageCard: View {
    let url: URL?
    let pageNumber: Int
    let height: CGFloat
    let onZoom: () -> Void

    var body: some View {
        Button(action: onZoom) {
            ZStack {
                if let url {
                    LocalJPEGView(url: url)
                        .padding(8)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5)
            }
            .overlay(alignment: .bottomTrailing) {
                Label("Tap to zoom", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(10)
            }
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .accessibilityLabel("Photo of page \(pageNumber)")
        .accessibilityHint("Opens the photo full screen to zoom")
    }
}

// MARK: - Lightbox

private struct PageLightbox: View {
    let model: JournalAppModel
    let pageID: UUID
    let pageNumber: Int
    @Environment(\.dismiss) private var dismiss
    @State private var displayURL: URL?
    @State private var shareURL: URL?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let displayURL {
                    #if os(iOS)
                    ZoomablePage(url: displayURL, background: .black)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityLabel("Photo of page \(pageNumber). Pinch or double-tap to zoom.")
                    #else
                    LocalJPEGView(url: displayURL)
                    #endif
                } else if failed {
                    ContentUnavailableView("Photo unavailable", systemImage: "photo",
                        description: Text("The image could not be opened. Its original record has not been changed."))
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle("Page \(pageNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Label("Share Copy Without Location", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .task {
            do {
                guard let repository = model.repository else { throw PersistenceError.notLoaded }
                displayURL = try await JournalImageCache.shared.image(pageID: pageID, repository: repository, kind: .display)
                shareURL = try await JournalImageCache.shared.image(pageID: pageID, repository: repository, kind: .share)
            } catch {
                failed = displayURL == nil
            }
        }
    }
}

// MARK: - Page Pill

private struct PagePill: View {
    let store: NotebookPagerStore
    @Binding var activePageID: UUID?

    var body: some View {
        let index = store.index(of: activePageID) ?? 0
        let count = store.pages.count
        HStack(spacing: 0) {
            Button { select(index - 1) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .disabled(index <= 0)
            .accessibilityLabel("Previous page")

            Menu {
                ForEach(Array(store.pages.enumerated()), id: \.element.id) { offset, page in
                    Button { select(offset) } label: {
                        let name = PagerTitle.title(text: page.previewText, pageNumber: offset + 1)
                        let label = name == String(localized: "Page \(offset + 1)")
                            ? name
                            : String(localized: "\(offset + 1). \(name)")
                        if page.id == activePageID {
                            Label(label, systemImage: "checkmark")
                        } else if store.drafts.isDirty(for: page.id) {
                            Label(label, systemImage: "pencil")
                        } else {
                            Text(label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Page \(index + 1) of \(count)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 6)
                .frame(minHeight: 44)
            }
            .accessibilityHint("Choose a page")

            Button { select(index + 1) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .disabled(index + 1 >= count)
            .accessibilityLabel("Next page")
        }
        .font(.body.weight(.semibold))
        .padding(.horizontal, 4)
        .modifier(PillBackground())
    }

    private func select(_ index: Int) {
        guard store.pages.indices.contains(index) else { return }
        withAnimation(.snappy) { activePageID = store.pages[index].id }
    }
}

/// Snaps exactly one page per swipe. `.alwaysByOne` needs iOS 18; on iOS 17 the default
/// view-aligned behavior already limits horizontal paging to one view at compact widths.
private struct OnePageSnapping: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        } else {
            content.scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        }
    }
}

private struct PillBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }
}

// MARK: - Overview Grid

private struct PageOverviewGrid: View {
    let model: JournalAppModel
    let store: NotebookPagerStore
    let activePageID: UUID?
    let onSelect: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    private struct NumberedPage: Identifiable {
        let number: Int
        let page: PagerPage
        var id: UUID { page.id }
    }

    private struct PageGroup: Identifiable {
        let id: UUID
        let entry: EntrySummary?
        var pages: [NumberedPage]
    }

    /// Consecutive pages of the same entry form one section.
    private var groups: [PageGroup] {
        var result: [PageGroup] = []
        for (offset, page) in store.pages.enumerated() {
            let item = NumberedPage(number: offset + 1, page: page)
            if let last = result.last, last.id == page.entryID {
                result[result.count - 1].pages.append(item)
            } else {
                result.append(PageGroup(id: page.entryID, entry: store.entries[page.entryID], pages: [item]))
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 14)],
                              spacing: 18, pinnedViews: .sectionHeaders) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.pages) { item in
                                    thumbnail(item.page, number: item.number)
                                        .id(item.page.id)
                                }
                            } header: {
                                header(group)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
                .background(Color(.systemGroupedBackground))
                .onAppear {
                    if let activePageID { reader.scrollTo(activePageID, anchor: .center) }
                }
            }
            .navigationTitle("\(store.pages.count) Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func header(_ group: PageGroup) -> some View {
        HStack(spacing: 6) {
            if let title = group.entry?.title, !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            if let date = group.entry?.journalDate {
                Text(date, format: .dateTime.month(.abbreviated).day().year())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func thumbnail(_ page: PagerPage, number: Int) -> some View {
        let active = page.id == activePageID
        return Button {
            onSelect(page.id)
            dismiss()
        } label: {
            VStack(spacing: 6) {
                PageThumbnail(model: model, pageID: page.id)
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(active ? Color.accentColor : Color(.separator).opacity(0.5),
                                          lineWidth: active ? 3 : 0.5)
                    }
                Text("\(number)")
                    .font(.caption.weight(active ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(active ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(number)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct PageThumbnail: View {
    let model: JournalAppModel
    let pageID: UUID
    @State private var url: URL?

    var body: some View {
        Group {
            if let url {
                LocalJPEGView(url: url).padding(4)
            } else {
                ProgressView()
            }
        }
        .task(id: pageID) {
            guard let repository = model.repository else { return }
            url = try? await JournalImageCache.shared.image(pageID: pageID, repository: repository, kind: .thumbnail)
        }
    }
}
