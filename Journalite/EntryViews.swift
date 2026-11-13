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

enum EntryViewMode: String, CaseIterable, Identifiable {
    case photo, text, compare
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .photo: "Photo"
        case .text: "Text"
        case .compare: "Compare"
        }
    }
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

struct EntryListView: View {
    let model: JournalAppModel
    let notebookID: UUID
    @State private var pager = EntryPager()

    var body: some View {
        List {
            Section { CaptureActions(model: model, notebookID: notebookID) }
            if pager.failed {
                Button("Couldn’t load entries. Retry") { Task { await reload() } }
            } else if pager.entries.isEmpty && !pager.isLoading {
                ContentUnavailableView("No entries in this notebook", systemImage: "doc",
                    description: Text("This notebook is ready for your journal pages. Choose Scan or Import Photos to get started."))
            }
            ForEach(pager.entries) { entry in
                NavigationLink(value: EntryRoute(entryID: entry.id)) { EntryRow(entry: entry) }
            }
            if pager.isLoading { ProgressView("Loading entries…") }
            if pager.hasMore {
                Button("Load More Entries") {
                    Task { await pager.load(model: model, notebookID: notebookID, reset: false) }
                }
                .disabled(pager.isLoading)
            }
        }
        .task(id: model.revision) { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        await pager.load(model: model, notebookID: notebookID, reset: true)
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
                    Text("Apple Vision on-device OCR is recognizing text.")
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

struct EntryDetailView: View {
    let model: JournalAppModel
    let route: EntryRoute
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var entry: EntrySummary?
    @State private var pages: [PageSummary] = []
    @State private var selectedPageID: UUID?
    @State private var pageDetail: PageDetail?
    @State private var pageImageURL: URL?

    @State private var mode: EntryViewMode = .text
    @State private var drafts = EntryDraftCoordinator()
    @FocusState private var editorFocused: Bool

    @State private var loadedOnce = false
    @State private var failed = false
    @State private var pageFailed = false

    @State private var editingEntry = false
    @State private var trashing = false
    @State private var leaving = false
    @State private var showingManagePages = false
    @State private var showingRevisions = false
    @State private var showingConflict = false
    @State private var retryTarget: PageDetail?
    @State private var notice: String?

    /// Only show a page once its detail matches the selection, so typing can never reach another page.
    private var currentPage: PageDetail? {
        pageDetail?.id == selectedPageID ? pageDetail : nil
    }

    private var currentIndex: Int {
        pages.firstIndex { $0.id == selectedPageID } ?? 0
    }

    private var unsavedPageIDs: Set<UUID> {
        drafts.dirtyPageIDs.intersection(pages.map(\.id))
    }

    var body: some View {
        content
            .navigationTitle(entryTitle)
            .navigationBarTitleDisplayMode(.inline)
            // Hiding the system back button also disables swipe-back, so drafts can't be lost by accident.
            .navigationBarBackButtonHidden(!unsavedPageIDs.isEmpty)
            .toolbar { toolbarContent }
            .task(id: "\(route.entryID)-\(model.revision)-\(model.ocr.revision)") { await reload() }
            .onChange(of: selectedPageID) { _, _ in
                Task { await reloadPageDetail() }
            }
            .sheet(isPresented: $editingEntry) {
                if let entry { EntryEditor(model: model, entry: entry) }
            }
            .sheet(isPresented: $showingManagePages) {
                ManagePagesView(model: model, entryID: route.entryID, unsavedPageIDs: unsavedPageIDs) { newID in
                    selectedPageID = newID
                }
            }
            .sheet(isPresented: $showingRevisions) {
                if let page = currentPage {
                    RevisionHistorySheet(model: model, page: page, pageNumber: currentIndex + 1) {
                        Task { await reload() }
                    }
                }
            }
            .sheet(isPresented: $showingConflict) {
                if let page = currentPage {
                    DraftConflictSheet(page: page, pageNumber: currentIndex + 1, drafts: drafts) {
                        Task { await save(page, resolvingConflict: true) }
                    }
                }
            }
            .alert("Retry OCR?", isPresented: Binding(
                get: { retryTarget != nil },
                set: { if !$0 { retryTarget = nil } }
            ), presenting: retryTarget) { page in
                Button("Retry OCR") { Task { await runRetry(pageID: page.id) } }
                Button("Cancel", role: .cancel) {}
            } message: { page in
                Text(retryExplanation(for: page))
            }
            .alert("Journalite", isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil } }
            )) {
                Button("OK", role: .cancel) { notice = nil }
            } message: {
                Text(notice ?? "")
            }
            .confirmationDialog("Leave without saving?", isPresented: $leaving, titleVisibility: .visible) {
                Button("Discard Drafts and Leave", role: .destructive) {
                    drafts.clearAll()
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text(unsavedSummary)
            }
            .confirmationDialog("Move this entry to Recently Deleted?", isPresented: $trashing, titleVisibility: .visible) {
                Button("Move to Recently Deleted", role: .destructive) {
                    Task {
                        if await model.change({ try await $0.trashEntry(id: route.entryID) }) {
                            drafts.clearAll()
                            dismiss()
                        }
                    }
                }
            } message: {
                if !unsavedPageIDs.isEmpty { Text("\(unsavedSummary) Saved pages and revisions are kept with the entry.") }
            }
    }

    private var entryTitle: String {
        guard let entry, !entry.title.isEmpty else { return String(localized: "Untitled entry") }
        return entry.title
    }

    private var unsavedSummary: String {
        unsavedPageIDs.count == 1
            ? String(localized: "1 page has an unsaved draft. Leaving discards it.")
            : String(localized: "\(unsavedPageIDs.count) pages have unsaved drafts. Leaving discards them.")
    }

    @ViewBuilder
    private var content: some View {
        if !loadedOnce {
            ProgressView("Opening entry…")
        } else if failed || entry == nil {
            ContentUnavailableView {
                Label("Entry unavailable", systemImage: "doc.badge.ellipsis")
            } description: {
                Text("It may be in Recently Deleted or not available yet. Any unsaved drafts are still kept while this screen is open.")
            } actions: {
                Button("Retry") { Task { await reload() } }
            }
        } else {
            VStack(spacing: 0) {
                Picker("View", selection: $mode) {
                    ForEach(EntryViewMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)

                if !pages.isEmpty {
                    pageNavigationHeader
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
                Divider()

                if pages.isEmpty {
                    ContentUnavailableView("No pages", systemImage: "doc",
                        description: Text("Choose Add or Manage Pages from the Actions menu."))
                } else if let page = currentPage {
                    switch mode {
                    case .photo: photoView(page: page)
                    case .text: textView(page: page)
                    case .compare: compareView(page: page)
                    }
                } else if pageFailed {
                    ContentUnavailableView {
                        Label("Page unavailable", systemImage: "doc.questionmark")
                    } description: {
                        Text("The page could not be loaded. Its photo and text have not been changed.")
                    } actions: {
                        Button("Retry") { Task { await reloadPageDetail() } }
                    }
                } else {
                    ProgressView("Loading page…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !unsavedPageIDs.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button { leaving = true } label: { Label("Back", systemImage: "chevron.backward") }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showingManagePages = true } label: {
                    Label("Add or Manage Pages", systemImage: "square.stack.3d.up")
                }
                if let page = currentPage {
                    Button { copy(page) } label: { Label("Copy Page Text", systemImage: "doc.on.doc") }
                    Button { requestRetry(page) } label: { Label("Retry OCR", systemImage: "arrow.clockwise") }
                }
                Button { editingEntry = true } label: { Label("Edit Entry Details", systemImage: "pencil") }
                Divider()
                Button(role: .destructive) { trashing = true } label: {
                    Label("Move to Recently Deleted", systemImage: "trash")
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
        }
        ToolbarItemGroup(placement: .keyboard) {
            Button("Done") { editorFocused = false }
            Spacer()
            if let page = currentPage {
                Button("Save") { Task { await save(page) } }
                    .bold()
                    .disabled(!drafts.canSave(page) || model.isSaving)
            }
        }
    }

    // MARK: Page Navigation

    private var pageNavigationHeader: some View {
        let index = currentIndex
        return HStack(spacing: 4) {
            Button { selectPage(at: index - 1) } label: {
                Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44)
            }
            .disabled(index <= 0)
            .accessibilityLabel("Previous page")

            Spacer(minLength: 0)

            Menu {
                ForEach(Array(pages.enumerated()), id: \.element.id) { offset, page in
                    Button { selectedPageID = page.id } label: {
                        let title = unsavedPageIDs.contains(page.id)
                            ? String(localized: "Page \(offset + 1) — unsaved draft")
                            : String(localized: "Page \(offset + 1)")
                        if page.id == selectedPageID {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Page \(index + 1) of \(pages.count)").font(.headline)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                    if let id = selectedPageID, unsavedPageIDs.contains(id) {
                        Text("Unsaved draft").font(.caption).foregroundStyle(.orange)
                    } else if !unsavedPageIDs.isEmpty {
                        Text("Unsaved drafts on other pages").font(.caption).foregroundStyle(.orange)
                    }
                }
                .multilineTextAlignment(.center)
            }
            .accessibilityHint("Choose a page")

            Spacer(minLength: 0)

            Button { selectPage(at: index + 1) } label: {
                Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44)
            }
            .disabled(index + 1 >= pages.count)
            .accessibilityLabel("Next page")
        }
    }

    /// Drafts are kept per page, so changing pages never discards typing.
    private func selectPage(at index: Int) {
        guard pages.indices.contains(index) else { return }
        selectedPageID = pages[index].id
    }

    // MARK: Compare (zoomable page above the editor)

    private func compareView(page: PageDetail) -> some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                editingHeader(page: page)

                if drafts.conflict(for: page) != .noConflict {
                    conflictBanner
                }

                pagePhoto
                    .frame(height: photoHeight(available: proxy.size.height))

                if !editorFocused {
                    OCRStatusBanner(coordinator: model.ocr, page: page) { requestRetry(page) }
                }

                if page.canonicalResolution.allowsEditing {
                    TextEditor(text: Binding(
                        get: { drafts.draft(for: page) },
                        set: { drafts.setDraft($0, for: page) }
                    ))
                    .focused($editorFocused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .frame(minHeight: 88, maxHeight: .infinity)
                    .layoutPriority(1)
                    .accessibilityLabel("Transcription for page \(currentIndex + 1)")
                } else {
                    missingRevisionPanel
                    Spacer(minLength: 0)
                }

                if !editorFocused {
                    compareActions(page: page)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    /// The photo yields space to the editor while typing and at accessibility text sizes.
    private func photoHeight(available: CGFloat) -> CGFloat {
        let fraction: CGFloat
        if editorFocused {
            fraction = 0.25
        } else if dynamicTypeSize.isAccessibilitySize {
            fraction = 0.28
        } else {
            fraction = 0.4
        }
        return max(80, available * fraction)
    }

    private func editingHeader(page: PageDetail) -> some View {
        AdaptiveStack(spacing: 6) {
            Label("Editing page \(currentIndex + 1) of \(pages.count)", systemImage: "pencil.line")
                .font(.subheadline.weight(.semibold))
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            if drafts.isDirty(for: page.id) {
                Text("Unsaved").font(.caption.bold()).foregroundStyle(.orange)
            } else if page.isReviewed {
                Label("Reviewed", systemImage: "checkmark.seal.fill").font(.caption.bold()).foregroundStyle(.green)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var pagePhoto: some View {
        if let url = pageImageURL {
            ZoomablePage(url: url)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                .accessibilityLabel("Photo of page \(currentIndex + 1). Pinch to zoom.")
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemBackground))
                .overlay(ProgressView("Loading photo…"))
        }
    }

    private func compareActions(page: PageDetail) -> some View {
        HStack(spacing: 12) {
            if drafts.isDirty(for: page.id) {
                Button("Revert", role: .destructive) { drafts.clearDraft(for: page.id) }
            }
            Spacer(minLength: 0)
            Menu {
                Button { copy(page) } label: { Label("Copy Saved Text", systemImage: "doc.on.doc") }
                Button { showingRevisions = true } label: {
                    Label("Revisions (\(page.revisions.count))", systemImage: "clock.arrow.circlepath")
                }
                Button { requestRetry(page) } label: { Label("Retry OCR", systemImage: "arrow.clockwise") }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            Button("Save") { Task { await save(page) } }
                .buttonStyle(.borderedProminent)
                .disabled(!drafts.canSave(page) || model.isSaving)
        }
    }

    private var conflictBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This page changed while you were editing", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Your draft is kept. Review the changes to choose what to keep.")
                .font(.caption)
            Button("Review Changes") { showingConflict = true }
                .font(.caption.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
            Button("Check Again") { Task { await reload() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Text

    private func textView(page: PageDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OCRStatusBanner(coordinator: model.ocr, page: page) { requestRetry(page) }

                if drafts.isDirty(for: page.id) {
                    AdaptiveStack {
                        Label("You have an unsaved draft for this page. The saved text is shown below.",
                              systemImage: "pencil.circle")
                            .font(.subheadline)
                        Button("Continue Editing") { mode = .compare }
                            .buttonStyle(.bordered)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                AdaptiveStack {
                    if page.isReviewed {
                        Label("Reviewed", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Needs review", systemImage: "text.badge.checkmark")
                            .foregroundStyle(.orange)
                    }
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    Button(page.isReviewed ? "Mark as Needs Review" : "Mark as Reviewed") {
                        Task {
                            _ = await model.change { try await $0.markPageReviewed(pageID: page.id, reviewed: !page.isReviewed) }
                            await reload()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!page.canonicalResolution.allowsReview || model.isSaving)
                }
                .font(.subheadline.bold())

                Divider()

                canonicalText(page: page)

                if page.lowConfidenceLineCount > 0, case .rawOCR = page.canonicalResolution {
                    Label("\(page.lowConfidenceLineCount) recognized lines have low confidence. Compare them with the photo.",
                          systemImage: "exclamationmark.magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Button { mode = .compare } label: {
                    Label("Edit in Compare Mode", systemImage: "pencil.and.scribble")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                AdaptiveStack {
                    Button { copy(page) } label: { Label("Copy Text", systemImage: "doc.on.doc") }
                    Button { showingRevisions = true } label: {
                        Label("Revisions (\(page.revisions.count))", systemImage: "clock.arrow.circlepath")
                    }
                    Button { requestRetry(page) } label: { Label("Retry OCR", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func canonicalText(page: PageDetail) -> some View {
        switch page.canonicalResolution {
        case .manualRevision(_, let text, let isBlank):
            if isBlank {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This page’s saved transcription is intentionally blank.")
                        .font(.body.italic())
                    Text("Blank is a saved choice. Edit in Compare mode to add text.")
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
            } else {
                Text(text).font(.body).textSelection(.enabled)
            }
        case .missingSelectedRevision:
            missingRevisionPanel
        case .rawOCR(_, let text, let isBlank):
            if isBlank {
                Text("No text was recognized on this page. Retry OCR, or type the text in Compare mode.")
                    .font(.body.italic())
                    .foregroundStyle(.secondary)
            } else {
                Text(text).font(.body).textSelection(.enabled)
            }
        case .emptyNoTranscription:
            Text("Not transcribed yet. Choose Transcribe above, or type the text in Compare mode.")
                .font(.body.italic())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Photo

    private func photoView(page: PageDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            OCRStatusBanner(coordinator: model.ocr, page: page) { requestRetry(page) }
                .padding(.horizontal)

            pagePhoto
                .frame(maxHeight: .infinity)
                .padding(.horizontal)

            AdaptiveStack {
                Text("Pinch to zoom.").font(.caption).foregroundStyle(.secondary)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                if let url = pageImageURL {
                    ShareLink(item: url) {
                        Label("Share Copy Without Location", systemImage: "square.and.arrow.up")
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
    }

    // MARK: Actions

    private func save(_ page: PageDetail, resolvingConflict: Bool = false) async {
        guard drafts.canSave(page) else { return }
        if !resolvingConflict, drafts.conflict(for: page) != .noConflict {
            showingConflict = true
            return
        }
        let text = drafts.draft(for: page)
        let base = drafts.baseRevisionID(for: page.id)
        // Exactly the user's text: no trimming, correction or rewriting.
        let saved = await model.change {
            try await $0.appendCorrection(pageID: page.id, text: text, baseRevisionID: .some(base))
        }
        if saved {
            drafts.clearDraft(for: page.id)
            await reload()
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
            parts.append(String(localized: "The current OCR text will be replaced."))
        } else {
            parts.append(String(localized: "Your saved corrections are retained in Revisions and can be restored at any time."))
        }
        if drafts.isDirty(for: page.id) {
            parts.append(String(localized: "Your unsaved draft is kept, and you can choose what to keep when the new text arrives."))
        }
        return parts.joined(separator: " ")
    }

    private func runRetry(pageID: UUID) async {
        await model.ocr.retry(pageID: pageID)
        await reload()
    }

    private func copy(_ page: PageDetail) {
        let unsavedNote = drafts.isDirty(for: page.id) ? " " + String(localized: "Your unsaved draft was not copied.") : ""
        switch page.canonicalResolution.displayText {
        case .some(let text) where !text.isEmpty:
            #if os(iOS)
            UIPasteboard.general.string = text
            #endif
            notice = String(localized: "Copied page \(currentIndex + 1)’s saved text as plain text.") + unsavedNote
        case .some:
            notice = String(localized: "This page’s saved transcription is blank, so nothing was copied.") + unsavedNote
        case .none:
            notice = String(localized: "There’s no saved text to copy for this page yet.") + unsavedNote
        }
    }

    private func reload() async {
        await reloadEntry()
        await reloadPageDetail()
    }

    /// Refreshes in place. The editor is never replaced by a loading state after the first load.
    private func reloadEntry() async {
        do {
            guard let repository = model.repository else { throw PersistenceError.notLoaded }
            let summary = try await repository.entry(id: route.entryID)
            let fetched = try await repository.pages(entryID: route.entryID)
            guard !Task.isCancelled else { return }
            entry = summary
            pages = fetched
            failed = false
            if selectedPageID == nil || !fetched.contains(where: { $0.id == selectedPageID }) {
                let target = route.targetPageID.flatMap { id in fetched.contains { $0.id == id } ? id : nil }
                selectedPageID = target ?? fetched.first?.id
            }
        } catch {
            if !Task.isCancelled { failed = true }
        }
        loadedOnce = true
    }

    private func reloadPageDetail() async {
        guard let pageID = selectedPageID, let repository = model.repository else {
            pageDetail = nil
            pageImageURL = nil
            return
        }
        do {
            let detail = try await repository.pageDetail(pageID: pageID)
            let needsImage = pageDetail?.id != pageID || pageDetail?.imageVersion != detail?.imageVersion || pageImageURL == nil
            let image = needsImage
                ? try? await JournalImageCache.shared.image(pageID: pageID, repository: repository, kind: .display)
                : pageImageURL
            guard !Task.isCancelled, pageID == selectedPageID else { return }
            if let detail { drafts.reconcile(with: detail) }
            pageImageURL = image
            pageDetail = detail
            pageFailed = detail == nil
        } catch {
            if pageID == selectedPageID { pageFailed = true }
        }
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
                    Text("OCR text is stored separately and never overwrites your revisions.")
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
