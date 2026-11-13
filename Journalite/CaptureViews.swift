import SwiftUI
import PhotosUI
#if os(iOS)
import UIKit
import VisionKit
#endif

struct CaptureActions: View {
    let model: JournalAppModel
    var notebookID: UUID? = nil
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isImporting = false

    var body: some View {
        // Each control must be its own List row. Sharing one row makes a tap fire both
        // the scanner and the photo picker, which collide and leave capture state stuck.
        Group {
            Button {
                Task {
                    let destination = model.capture.defaultNotebook(viewing: notebookID, notebooks: model.notebooks)
                    await model.capture.scan(notebookID: destination)
                }
            } label: { Label("Scan", systemImage: "doc.viewfinder") }
            .disabled(model.capture.busy || model.capture.saving || model.capture.showReview || model.capture.showScanner)

            PhotosPicker(selection: $selectedPhotos, maxSelectionCount: ImportLimits.pages,
                         selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current) {
                HStack {
                    Label("Import Photos", systemImage: "photo.on.rectangle")
                    if isImporting {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isImporting || model.capture.saving || model.capture.showReview || model.capture.showScanner)
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty, !isImporting, let repository = model.repository else { return }
                let itemsToImport = items
                isImporting = true
                let destination = model.capture.defaultNotebook(viewing: notebookID, notebooks: model.notebooks)
                model.capture.startImport(itemsToImport, notebookID: destination, repository: repository)
                Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    selectedPhotos = []
                    isImporting = false
                }
            }
        }
    }
}

struct CapturePresentation: ViewModifier {
    let model: JournalAppModel
    @Bindable var coordinator: CaptureCoordinator
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $coordinator.showReview) {
                CaptureReviewView(model: model, coordinator: coordinator)
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $coordinator.showScanner) {
                if VNDocumentCameraViewController.isSupported {
                    DocumentScanner(
                        finished: { scan in
                            if let repository = model.repository { coordinator.receivedScan(scan, repository: repository) }
                            else { coordinator.scannerFailed() }
                        },
                        cancelled: { coordinator.scannerCancelled() },
                        failed: { coordinator.scannerFailed() }
                    ).ignoresSafeArea()
                } else {
                    ContentUnavailableView("Scanner unavailable", systemImage: "camera",
                        description: Text("Use Import Photos instead."))
                        .onAppear { coordinator.scannerFailed() }
                }
            }
            #endif
            .alert("Capture", isPresented: Binding(get: { coordinator.message != nil && !coordinator.showReview },
                                                  set: { if !$0 { coordinator.message = nil } })) {
                #if os(iOS)
                if coordinator.cameraDenied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                #endif
                Button("OK", role: .cancel) { coordinator.message = nil }
            } message: { Text(coordinator.message ?? "") }
    }
}

struct CaptureRecoverySection: View {
    let model: JournalAppModel
    var body: some View {
        if !model.capture.recoveries.isEmpty {
            Section("Unfinished imports") {
                ForEach(model.capture.recoveries) { receipt in
                    Button {
                        if let repository = model.repository {
                            Task { await model.capture.resume(receipt, repository: repository) }
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text("Resume import — \(receipt.pages.count) staged pages")
                            Text(receipt.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption)
                        }
                    }
                    .disabled(model.capture.busy || model.capture.saving)
                }
            }
        }
    }
}

struct CaptureReviewView: View {
    let model: JournalAppModel
    @Bindable var coordinator: CaptureCoordinator
    @State private var newNotebook = ""
    @State private var confirmDiscard = false
    @State private var duplicateConsent = false

    var body: some View {
        NavigationStack {
            if let receipt = coordinator.receipt {
                List {
                    if coordinator.busy {
                        Section {
                            ProgressView(coordinator.progress)
                            Button("Cancel Loading", role: .cancel) { coordinator.cancelLoading() }
                        }
                    }
                    if let message = coordinator.message {
                        Section("Notice") { Text(message) }
                    }
                    if receipt.phase == .saving || receipt.phase == .committed {
                        Section {
                            Text("This save was started. Its page order and destination are locked so retrying cannot duplicate entries. Restore the original notebook if needed, then retry.")
                        }
                    }
                    Section("Entry") {
                        Picker("Notebook", selection: field(\.notebookID, default: nil)) {
                            Text("Choose a notebook").tag(UUID?.none)
                            ForEach(model.notebooks) { notebook in Text(notebook.name).tag(Optional(notebook.id)) }
                        }
                        HStack {
                            TextField("New notebook name", text: $newNotebook)
                            Button("Create") { Task { await createNotebook() } }
                                .disabled(newNotebook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving)
                        }
                        TextField("Title", text: field(\.title, default: ""))
                        DatePicker("Journal date", selection: field(\.journalDate, default: Date()), displayedComponents: .date)
                        Text("Capture time is recorded separately from the journal date.").font(.footnote)
                        if receipt.pages.allSatisfy({ $0.sourceKind == "photoImport" }) {
                            Toggle("Separate entry for each photo", isOn: field(\.separateEntries, default: false))
                            Text("Off: save all pages in one entry, in the order below. On: save one entry per photo, with the same journal date and numbered titles.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(coordinator.busy || coordinator.saving || receipt.phase != .review)
                    if !receipt.failures.isEmpty {
                        Section("Items that did not load") {
                            ForEach(Array(receipt.failures.enumerated()), id: \.offset) { _, failure in Text(failure) }
                            Toggle("Save only the successfully loaded pages", isOn: field(\.acknowledgedFailures, default: false))
                                .disabled(coordinator.busy || coordinator.saving || receipt.phase != .review)
                        }
                    }
                    if !coordinator.duplicates.isEmpty {
                        Section("Possible exact duplicates") {
                            Text("Some source bytes match pages already saved or another page in this import. Nothing has been discarded.")
                            Toggle("Keep these duplicate pages too", isOn: $duplicateConsent)
                        }
                    }
                    Section("Pages — \(receipt.pages.count)") {
                        ForEach(receipt.pages) { page in
                            StagedPageRow(page: page, receiptID: receipt.id, files: coordinator.files,
                                duplicate: coordinator.duplicates.contains(page.id))
                        }
                        .onDelete { offsets in coordinator.receipt?.pages.remove(atOffsets: offsets) }
                        .onMove { offsets, destination in coordinator.receipt?.pages.move(fromOffsets: offsets, toOffset: destination) }
                        .deleteDisabled(coordinator.busy || coordinator.saving || receipt.phase != .review)
                        .moveDisabled(coordinator.busy || coordinator.saving || receipt.phase != .review)
                    }
                    Section {
                        Text("Limits: 20 pages, 25 MB per image, 150 MB per import, 48 megapixels per image. Use still images; animated or multipage image files are not supported.")
                        Text("Imported source bytes are kept unchanged and may contain location or other metadata. Scans are high-quality JPEG renderings of VisionKit’s processed pages, not the original camera exposure. Derived previews and ordinary shared copies omit location metadata.")
                    }.font(.footnote).foregroundStyle(.secondary)
                }
                .navigationTitle("Review Pages")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if receipt.phase == .review && !coordinator.busy {
                            Button("Cancel") { confirmDiscard = true }.disabled(coordinator.saving)
                        } else if receipt.phase == .saving && !coordinator.saving {
                            Button("Keep for Later") { coordinator.showReview = false }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        EditButton().disabled(coordinator.busy || coordinator.saving || receipt.phase != .review)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(receipt.phase == .saving ? "Retry Save" : "Save") {
                            Task { await coordinator.save(model: model) }
                        }
                        .disabled(coordinator.busy || coordinator.saving || model.isSaving || receipt.pages.isEmpty ||
                            receipt.notebookID == nil || (!receipt.failures.isEmpty && !receipt.acknowledgedFailures) ||
                            (!coordinator.duplicates.isEmpty && !duplicateConsent))
                    }
                }
                .onChange(of: receipt.title) { _, _ in persist() }
                .onChange(of: receipt.journalDate) { _, _ in persist() }
                .onChange(of: receipt.notebookID) { _, _ in persist() }
                .onChange(of: receipt.separateEntries) { _, _ in persist() }
                .onChange(of: receipt.acknowledgedFailures) { _, _ in persist() }
                .onChange(of: receipt.pages.map(\.id)) { _, _ in persist() }
                .confirmationDialog("Discard these staged pages?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("Discard Import", role: .destructive) { Task { await coordinator.discardReview() } }
                    Button("Keep Reviewing", role: .cancel) {}
                } message: { Text("No journal entries have been created yet.") }
            }
        }
        .interactiveDismissDisabled()
    }

    private func field<Value>(_ key: WritableKeyPath<IngestionReceipt, Value>, default fallback: Value) -> Binding<Value> {
        Binding(get: { coordinator.receipt?[keyPath: key] ?? fallback },
                set: { coordinator.receipt?[keyPath: key] = $0 })
    }

    private func persist() { Task { await coordinator.persistReview() } }

    private func createNotebook() async {
        let success = await model.change { repository in
            let id = try await repository.createNotebook(name: newNotebook)
            coordinator.receipt?.notebookID = id
        }
        if success { newNotebook = ""; await coordinator.persistReview() }
    }
}

private struct StagedPageRow: View {
    let page: StagedPage
    let receiptID: UUID
    let files: IngestionFiles
    let duplicate: Bool
    @State private var url: URL?

    var body: some View {
        HStack {
            if let url {
                AsyncImage(url: url) { image in image.resizable().scaledToFit() }
                    placeholder: { ProgressView() }
                    .frame(width: 72, height: 96)
                    .accessibilityLabel("Page thumbnail")
            }
            VStack(alignment: .leading) {
                Text(page.sourceKind == "photoImport" ? "Imported photo" : "Processed document scan")
                if duplicate { Label("Exact duplicate", systemImage: "exclamationmark.triangle") }
                Text("\(page.width) × \(page.height) pixels").font(.caption)
            }
        }
        .task { url = await files.thumbnailURL(receiptID: receiptID, pageID: page.id) }
    }
}
