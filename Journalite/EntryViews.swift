import SwiftUI
import Observation
import PhotosUI
#if os(iOS)
import UIKit
import VisionKit
import AVFoundation
#endif

private func safeMessage(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

@MainActor
@Observable
final class EntryPager {
    private(set) var entries: [EntrySummary] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var failed = false
    private var generation = 0

    func load(model: JournalAppModel, notebookID: UUID? = nil, trashed: Bool = false, reset: Bool) async {
        if !reset && isLoading { return }
        if reset {
            generation += 1
            entries = []
            hasMore = false
        }
        let current = generation
        isLoading = true
        failed = false
        do {
            guard let repository = model.repository else { throw PersistenceError.notLoaded }
            let batch = try await repository.entries(notebookID: notebookID, trashed: trashed, offset: entries.count)
            guard current == generation else { return }
            entries += batch.entries
            hasMore = batch.hasMore
        } catch {
            if current == generation { failed = true }
        }
        if current == generation { isLoading = false }
    }
}

// MARK: - OCR Status Banner

struct OCRStatusBanner: View {
    let coordinator: OCRCoordinator
    let page: PageDetail
    let onRetry: () -> Void

    var body: some View {
        let job = coordinator.jobs.first { $0.key.pageID == page.id }
        if job?.state == .running {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcribing on this iPhone…")
                        .font(.subheadline.weight(.semibold))
                    Text("Recognizing text on this iPhone. Nothing is uploaded.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    if let key = job?.key {
                        Task { await coordinator.cancel(key) }
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
            .padding(10)
            .background(Color.blue.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if job?.state == .waiting {
            HStack(spacing: 12) {
                Image(systemName: "clock")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting to transcribe…")
                        .font(.subheadline.weight(.semibold))
                    Text("Pages are transcribed sequentially on your device.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    if let key = job?.key {
                        Task { await coordinator.cancel(key) }
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
            .padding(10)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if job?.state == .failed {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn't transcribe this page")
                        .font(.subheadline.weight(.semibold))
                    Text("Your photo is safe. Retry or edit manually.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Retry OCR") {
                    onRetry()
                }
                .font(.caption.bold())
                .buttonStyle(.borderedProminent)
            }
            .padding(10)
            .background(Color.red.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if job?.state == .cancelled {
            HStack(spacing: 12) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcription cancelled")
                        .font(.subheadline.weight(.semibold))
                    Text("Your photo is safe.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Transcribe") {
                    onRetry()
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if page.canonicalResolution == .emptyNoTranscription {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not transcribed yet")
                        .font(.subheadline.weight(.semibold))
                    Text("Run on-device text recognition on this iPhone.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Transcribe") {
                    onRetry()
                }
                .font(.caption.bold())
                .buttonStyle(.borderedProminent)
            }
            .padding(10)
            .background(Color.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Layout Helpers

/// Horizontal at ordinary text sizes; stacks vertically at accessibility Dynamic Type sizes.
private struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var spacing: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(spacing: spacing))
        layout { content }
    }
}

private func transcriptPreview(_ text: String?) -> String {
    guard let text else { return String(localized: "Not transcribed") }
    if text.isEmpty { return String(localized: "Blank") }
    return text.count > 40 ? String(text.prefix(40)) + "…" : text
}

// MARK: - Entry Detail View

/// Opens an entry (from Search or Recent Entries) in the same page-above, text-below pager
/// used by notebooks, starting at the requested page.
struct EntryDetailView: View {
    let model: JournalAppModel
    let route: EntryRoute

    var body: some View {
        NotebookPagerView(model: model, scope: .entry(route.entryID), initialPageID: route.targetPageID)
    }
}

// MARK: - Revision History Sheet

struct RevisionHistorySheet: View {
    let model: JournalAppModel
    let page: PageDetail
    let pageNumber: Int
    let onRestored: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var restoring = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Restoring an earlier revision saves its text as a new revision. Nothing in this history is ever deleted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Manual revisions") {
                    if page.revisions.isEmpty {
                        Text("No manual revisions saved yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(page.revisions) { revision in
                        VStack(alignment: .leading, spacing: 6) {
                            AdaptiveStack(spacing: 6) {
                                Text(revision.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                                    .font(.subheadline.bold())
                                if revision.isSelected {
                                    Text("Current")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                }
                            }
                            if revision.text.isEmpty {
                                Text("Blank").font(.callout.italic()).foregroundStyle(.secondary)
                            } else {
                                Text(revision.text).font(.body).lineLimit(6)
                            }
                            if let version = revision.imageVersion, version != page.imageVersion {
                                Text("Saved for an earlier version of this page’s photo.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !revision.isSelected {
                                Button("Restore as New Revision") { Task { await restore(revision) } }
                                    .buttonStyle(.bordered)
                                    .disabled(restoring || model.isSaving)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    if let raw = page.rawOCRText, page.ocrResultID != nil {
                        if raw.isEmpty {
                            Text("OCR found no text.").font(.callout.italic()).foregroundStyle(.secondary)
                        } else {
                            Text(raw).font(.body).lineLimit(8).textSelection(.enabled)
                        }
                    } else {
                        Text("No OCR result yet.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Latest OCR result")
                } footer: {
                    if let engine = OCREngine.displayName(page.ocrEngine) {
                        Text("Transcribed by \(engine). OCR text is stored separately and never overwrites your revisions.")
                    } else {
                        Text("OCR text is stored separately and never overwrites your revisions.")
                    }
                }
            }
            .navigationTitle("Page \(pageNumber) Revisions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func restore(_ revision: TranscriptRevisionSummary) async {
        restoring = true
        defer { restoring = false }
        let restored = await model.change { try await $0.restoreRevision(pageID: page.id, revisionID: revision.id) }
        if restored {
            onRestored()
            dismiss()
        }
    }
}

// MARK: - Draft Conflict Sheet

struct DraftConflictSheet: View {
    let page: PageDetail
    let pageNumber: Int
    let drafts: EntryDraftCoordinator
    let onSaveDraft: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Page \(pageNumber)’s saved text changed while you were editing — for example, a new OCR result, a restored revision, or a change from another device. Your draft has not been touched.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    comparison(title: "Your draft", text: drafts.draft(for: page), tint: .orange)
                    comparison(title: "Latest saved text", text: page.canonicalResolution.displayText, tint: .secondary)

                    VStack(spacing: 12) {
                        Button {
                            onSaveDraft()
                            dismiss()
                        } label: {
                            Text("Save My Draft as a New Revision").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            drafts.mergeWithLatest(for: page)
                            dismiss()
                        } label: {
                            Text("Merge: Add Latest Text Below My Draft").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            drafts.keepDraftAsLatest(for: page)
                            dismiss()
                        } label: {
                            Text("Keep My Draft and Continue Editing").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            drafts.adoptCurrentText(for: page)
                            dismiss()
                        } label: {
                            Text("Discard My Draft and Use Latest").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 8)

                    Text("Merging places both texts in the editor exactly as written, so you can combine them yourself before saving.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Review Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
            }
        }
    }

    private func comparison(title: LocalizedStringKey, text: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Group {
                if let text, !text.isEmpty {
                    Text(text).textSelection(.enabled)
                } else {
                    Text(text == nil ? "No saved text" : "Blank").italic().foregroundStyle(.secondary)
                }
            }
            .font(.body)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Adding Pages

/// The single path for adding scanned or imported pages to an existing entry. It applies the
/// same per-image and per-import limits as new captures, reports every item that could not be
/// added, and hands new pages to OCR through the local ownership receipt.
@MainActor
enum EntryPageAdder {
    struct Outcome {
        var addedPageIDs: [UUID] = []
        var failures: [String] = []
    }

    static func importPhotos(_ items: [PhotosPickerItem], to entryID: UUID, model: JournalAppModel) async -> Outcome {
        var drafts: [PageDraft] = []
        var failures: [String] = []
        var totalBytes = 0
        for (index, item) in items.enumerated() {
            do {
                guard let loaded = try await item.loadTransferable(type: PickedImageFile.self) else {
                    throw IngestionError.invalidImage
                }
                defer { try? FileManager.default.removeItem(at: loaded.url) }
                let info = try ImageProcessing.inspect(loaded.url)
                guard totalBytes + info.byteCount <= ImportLimits.totalBytes else { throw IngestionError.limit }
                let data = try Data(contentsOf: loaded.url)
                totalBytes += data.count
                drafts.append(PageDraft(sourceData: data, contentType: info.contentType,
                    pixelWidth: Int64(info.width), pixelHeight: Int64(info.height),
                    sourceKind: "photoImport", sourceHash: ImageProcessing.hash(data)))
            } catch {
                failures.append(String(localized: "Photo \(index + 1): ") + safeMessage(error))
            }
        }
        return await add(drafts, to: entryID, model: model, failures: failures)
    }

    #if os(iOS)
    static func addScan(_ scan: VNDocumentCameraScan, to entryID: UUID, model: JournalAppModel) async -> Outcome {
        var drafts: [PageDraft] = []
        var failures: [String] = []
        var totalBytes = 0
        for index in 0..<scan.pageCount {
            do {
                // VisionKit owns its results. Hold only one returned UIImage at a time.
                let draft = try autoreleasepool { () throws -> PageDraft in
                    let image = scan.imageOfPage(at: index)
                    let width = Int(image.size.width * image.scale)
                    let height = Int(image.size.height * image.scale)
                    guard width > 0, height > 0, width <= 16_000, height <= 16_000,
                          width * height <= ImportLimits.pixels,
                          let data = image.jpegData(compressionQuality: 0.95),
                          data.count <= ImportLimits.imageBytes else { throw IngestionError.limit }
                    return PageDraft(sourceData: data, contentType: "public.jpeg",
                        pixelWidth: Int64(width), pixelHeight: Int64(height),
                        sourceKind: "processedDocumentScan", sourceHash: ImageProcessing.hash(data))
                }
                guard totalBytes + draft.sourceData.count <= ImportLimits.totalBytes else { throw IngestionError.limit }
                totalBytes += draft.sourceData.count
                drafts.append(draft)
            } catch {
                failures.append(String(localized: "Scan page \(index + 1): ") + safeMessage(error))
            }
        }
        return await add(drafts, to: entryID, model: model, failures: failures)
    }
    #endif

    private static func add(_ drafts: [PageDraft], to entryID: UUID, model: JournalAppModel, failures: [String]) async -> Outcome {
        var failures = failures
        guard !drafts.isEmpty else { return Outcome(failures: failures) }
        var newIDs: [UUID] = []
        let saved = await model.change { newIDs = try await $0.addPages(to: entryID, drafts: drafts) }
        guard saved, let repository = model.repository else {
            failures.append(String(localized: "The pages could not be saved, so nothing was added. Try again."))
            return Outcome(failures: failures)
        }
        do {
            var keys: [OCRPageKey] = []
            for id in newIDs {
                if let page = try await repository.ocrPage(id: id) { keys.append(page.key) }
            }
            try await model.capture.files.recordOwnership(keys: keys)
            await model.ocr.ingestionSaved()
        } catch {
            failures.append(String(localized: "The pages were added. Open each new page and choose Transcribe to run OCR."))
        }
        return Outcome(addedPageIDs: newIDs, failures: failures)
    }
}

// MARK: - Manage Pages View (Add, Reorder, Remove, Restore)

struct ManagePagesView: View {
    let model: JournalAppModel
    let entryID: UUID
    var unsavedPageIDs: Set<UUID> = []
    let onPageAdded: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var livePages: [PageSummary] = []
    @State private var removedPages: [PageSummary] = []
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isAdding = false

    #if os(iOS)
    @State private var showScanner = false
    @State private var cameraDenied = false
    #endif

    @State private var pendingRemoval: PageSummary?
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Drag to reorder. Removed pages stay in this entry’s Removed Pages list with their photos and revisions, and can be restored at any time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Pages (\(livePages.count))") {
                    ForEach(Array(livePages.enumerated()), id: \.element.id) { offset, page in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Page \(offset + 1)").font(.headline)
                            Text(transcriptPreview(page.text))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if unsavedPageIDs.contains(page.id) {
                                Text("Unsaved draft").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .onMove { offsets, destination in
                        var updated = livePages
                        updated.move(fromOffsets: offsets, toOffset: destination)
                        livePages = updated
                        Task {
                            let order = updated.map(\.id)
                            let saved = await model.change { try await $0.reorderPages(entryID: entryID, pageIDs: order) }
                            if !saved { await reload() }
                        }
                    }
                    .onDelete { offsets in
                        if let first = offsets.first { pendingRemoval = livePages[first] }
                    }
                    .moveDisabled(isAdding || model.isSaving)
                    .deleteDisabled(isAdding || model.isSaving)
                }

                Section {
                    #if os(iOS)
                    Button { Task { await startScan() } } label: {
                        Label("Scan Pages", systemImage: "doc.viewfinder")
                    }
                    .disabled(isAdding)
                    #endif
                    PhotosPicker(selection: $selectedPhotos, maxSelectionCount: ImportLimits.pages,
                                 selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current) {
                        Label("Import Photos", systemImage: "photo.on.rectangle")
                    }
                    .disabled(isAdding)
                    if isAdding {
                        ProgressView("Adding pages…")
                    }
                } header: {
                    Text("Add Pages")
                } footer: {
                    Text("New pages are added at the end and transcribed on this iPhone. Limits: 20 pages, 25 MB per image, 150 MB per import.")
                }

                if !removedPages.isEmpty {
                    Section("Removed Pages (\(removedPages.count))") {
                        ForEach(removedPages) { page in
                            AdaptiveStack {
                                Text(transcriptPreview(page.text))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                                Button("Restore") {
                                    Task {
                                        _ = await model.change { try await $0.restorePage(id: page.id) }
                                        await reload()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.isSaving)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Manage Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(isAdding)
                }
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
            }
            .interactiveDismissDisabled(isAdding)
            .task { await reload() }
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty, !isAdding else { return }
                let itemsToImport = items
                selectedPhotos = []
                Task {
                    await finish(adding: { await EntryPageAdder.importPhotos(itemsToImport, to: entryID, model: model) })
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner(
                    finished: { scan in
                        showScanner = false
                        Task { await finish(adding: { await EntryPageAdder.addScan(scan, to: entryID, model: model) }) }
                    },
                    cancelled: { showScanner = false },
                    failed: {
                        showScanner = false
                        statusMessage = String(localized: "The document scanner could not finish. No pages were added.")
                    }
                )
                .ignoresSafeArea()
            }
            #endif
            .alert("Manage Pages", isPresented: Binding(
                get: { statusMessage != nil },
                set: { if !$0 { statusMessage = nil } }
            )) {
                #if os(iOS)
                if cameraDenied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                #endif
                Button("OK", role: .cancel) { statusMessage = nil }
            } message: {
                Text(statusMessage ?? "")
            }
            .confirmationDialog("Remove this page?", isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ), titleVisibility: .visible, presenting: pendingRemoval) { page in
                Button("Remove Page", role: .destructive) {
                    Task {
                        _ = await model.change { try await $0.removePage(id: page.id) }
                        await reload()
                    }
                }
            } message: { page in
                if unsavedPageIDs.contains(page.id) {
                    Text("Its photo and saved revisions move to Removed Pages and can be restored. This page’s unsaved draft will not be available until the page is restored.")
                } else {
                    Text("Its photo and saved revisions move to Removed Pages and can be restored.")
                }
            }
        }
    }

    #if os(iOS)
    private func startScan() async {
        cameraDenied = false
        #if targetEnvironment(simulator)
        let supported = false
        #else
        let supported = VNDocumentCameraViewController.isSupported
        #endif
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch CameraDecision.resolve(supported: supported, authorized: status == .authorized, notDetermined: status == .notDetermined) {
        case .unsupported:
            statusMessage = String(localized: "Document scanning is unavailable on this device. Use Import Photos instead.")
        case .denied:
            denyCamera()
        case .request:
            if await AVCaptureDevice.requestAccess(for: .video) { showScanner = true } else { denyCamera() }
        case .scan:
            showScanner = true
        }
    }

    private func denyCamera() {
        cameraDenied = true
        statusMessage = String(localized: "Camera access is off or restricted. Use Import Photos, or enable Camera for Journalite in Settings.")
    }
    #endif

    private func finish(adding work: () async -> EntryPageAdder.Outcome) async {
        isAdding = true
        let outcome = await work()
        isAdding = false
        await reload()
        if !outcome.failures.isEmpty {
            statusMessage = outcome.failures.joined(separator: "\n")
        }
        if let first = outcome.addedPageIDs.first { onPageAdded(first) }
    }

    private func reload() async {
        guard let repository = model.repository else { return }
        do {
            livePages = try await repository.pages(entryID: entryID)
            removedPages = try await repository.deletedPages(entryID: entryID)
        } catch {
            statusMessage = String(localized: "Pages could not be loaded. Nothing was changed. Close and try again.")
        }
    }
}


// MARK: - Entry Editor

struct EntryEditor: View {
    let model: JournalAppModel
    let entry: EntrySummary
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var date: Date
    @State private var favorite: Bool
    @State private var notebookID: UUID?

    init(model: JournalAppModel, entry: EntrySummary) {
        self.model = model
        self.entry = entry
        _title = State(initialValue: entry.title)
        _date = State(initialValue: entry.journalDate ?? Date())
        _favorite = State(initialValue: entry.isFavorite)
        _notebookID = State(initialValue: entry.notebookUnavailable ? nil : entry.notebookID)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                DatePicker("Journal date", selection: $date, displayedComponents: .date)
                Toggle("Favorite", isOn: $favorite)
                Picker("Notebook", selection: $notebookID) {
                    Text("Choose a notebook").tag(UUID?.none)
                    ForEach(model.notebooks) { notebook in
                        Text(notebook.name).tag(Optional(notebook.id))
                    }
                }
                if model.notebooks.isEmpty {
                    Text("Create a live notebook in the library, then return to move this entry.")
                }
            }
            .navigationTitle("Edit Entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(model.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(model.isSaving || notebookID == nil)
                }
            }
            .interactiveDismissDisabled(model.isSaving)
        }
    }

    private func save() async {
        guard let notebookID else { return }
        if await model.change({
            try await $0.updateEntry(id: entry.id, title: title, journalDate: date, isFavorite: favorite, notebookID: notebookID)
        }) { dismiss() }
    }
}
