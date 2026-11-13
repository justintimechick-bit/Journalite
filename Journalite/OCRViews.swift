import SwiftUI

struct OCRLifecycle: ViewModifier {
    let coordinator: OCRCoordinator
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content.onChange(of: phase, initial: true) { _, value in
            coordinator.setActive(value == .active)
        }
    }
}

struct OCRSettingsSection: View {
    @Bindable var coordinator: OCRCoordinator

    var body: some View {
        Section("On-device transcription") {
            if coordinator.languages.isEmpty {
                Text("Recognition languages are unavailable.")
                Button("Retry Language and Queue Setup") { Task { await coordinator.retryRecovery() } }
            } else {
                Picker("Recognition language", selection: $coordinator.language) {
                    ForEach(coordinator.languages, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
            }
            if !coordinator.languages.isEmpty && !coordinator.languages.contains(coordinator.language) {
                Text("The previous recognition language is unavailable on this device. Choose a supported language above.")
            }
            Toggle("Use Apple Intelligence for Handwriting", isOn: $coordinator.useHandwritingModel)
            if coordinator.useHandwritingModel {
                Text(coordinator.handwritingAvailability.explanation)
            }
            Text("Runs only on this iPhone with Apple’s on-device model; pages are never uploaded. It copies words exactly as written — spelling, names and verse references included — and writes [illegible] instead of guessing. Apple Vision text recognition is used when this is off, unavailable, or can’t read a page. Applies to new pages and Retry OCR; saved pages aren’t changed.")
            Text("The selected language applies to new pages and retries. Processing pauses when the app is inactive and resumes when you return.")
            Text("Designed for ordinary line-based pages. Cursive and complex columns may need manual correction. No text is expanded or rewritten.")
            if let message = coordinator.message {
                Text(message)
                Button("Retry Queue Recovery") { Task { await coordinator.retryRecovery() } }
            }
        }
        .onAppear { coordinator.refreshHandwritingAvailability() }
    }
}

struct OCRPageView: View {
    let model: JournalAppModel
    let pageID: UUID
    @State private var snapshot: OCRPageSnapshot?
    @State private var failed = false
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot {
                OCRPageStatus(coordinator: model.ocr, snapshot: snapshot)
                if let text = snapshot.text {
                    Text(text.isEmpty ? String(localized: "This page has an empty saved transcription.") : text)
                        .textSelection(.enabled)
                }
                if snapshot.rawText == "" {
                    Text("No text was recognized. Your photo is preserved; you can type a transcription.")
                }
                if snapshot.lowConfidenceLineCount > 0 {
                    Text("Some recognized lines may need extra attention. Compare the text with the photo.")
                        .foregroundStyle(.secondary)
                }
                Button("Type or Edit Transcription") { editing = true }
                .sheet(isPresented: $editing) {
                    ManualTranscriptEditor(model: model, pageID: pageID, initialText: snapshot.text ?? "")
                }
            } else if failed {
                Text("Transcription is unavailable. The page or its notebook may need recovery.")
                Button("Retry") { Task { await reload() } }
            } else {
                ProgressView("Loading transcription…")
            }
        }
        .task(id: "\(model.ocr.revision)-\(model.revision)-\(pageID)") { await reload() }
    }

    private func reload() async {
        do {
            guard let repository = model.repository else { throw PersistenceError.notLoaded }
            snapshot = try await repository.ocrPage(id: pageID)
            failed = snapshot == nil
        } catch { failed = true }
    }
}

private struct OCRPageStatus: View {
    let coordinator: OCRCoordinator
    let snapshot: OCRPageSnapshot

    var body: some View {
        let job = coordinator.jobs.first { $0.key == snapshot.key }
        VStack(alignment: .leading, spacing: 8) {
            if job?.state == .running {
                ProgressView("Transcribing")
                Button("Cancel Transcription") { Task { await coordinator.cancel(snapshot.key) } }
            } else if job?.state == .waiting {
                Label("Waiting to transcribe", systemImage: "clock")
                Button("Cancel Transcription") { Task { await coordinator.cancel(snapshot.key) } }
            } else {
                if job?.state == .failed {
                    Label("Couldn't transcribe", systemImage: "exclamationmark.bubble")
                    Text("The photo and any saved corrections are preserved. Try again or type the text.")
                } else if snapshot.resultID != nil {
                    Label("Needs review", systemImage: "text.badge.checkmark")
                } else if job?.state == .cancelled {
                    Text("Transcription cancelled. Your photo is preserved.")
                } else {
                    Text("This page has not been queued on this iPhone. Choose Transcribe to process it locally.")
                }
                Button(snapshot.resultID == nil && job == nil ? "Transcribe on This iPhone" : "Retry Transcription") {
                    Task { await coordinator.retry(pageID: snapshot.key.pageID) }
                }
                .disabled(coordinator.languages.isEmpty)
            }
        }
        .font(.body)
        if let message = coordinator.message {
            Text(message)
            Button("Retry Queue Recovery") { Task { await coordinator.retryRecovery() } }
        }
    }
}

private struct ManualTranscriptEditor: View {
    let model: JournalAppModel
    let pageID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(model: JournalAppModel, pageID: UUID, initialText: String) {
        self.model = model
        self.pageID = pageID
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading) {
                    PageImageView(model: model, pageID: pageID)
                    TextEditor(text: $text)
                        .frame(minHeight: 240)
                        .accessibilityLabel("Transcription")
                    Text("Save adds a new correction. An empty correction stays empty. Retrying OCR never replaces your correction.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("Edit Transcription")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(model.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await model.change({ _ = try await $0.appendCorrection(pageID: pageID, text: text) }) {
                                dismiss()
                            }
                        }
                    }.disabled(model.isSaving)
                }
            }
            .interactiveDismissDisabled(model.isSaving)
        }
    }
}
