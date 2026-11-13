import Foundation
import Observation

nonisolated struct TranscriptRevisionSummary: Identifiable, Sendable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date
    let baseRevisionID: UUID?
    let imageVersion: UUID?
    let isSelected: Bool
}

nonisolated enum CanonicalTextStatus: Equatable, Sendable {
    case manualRevision(revisionID: UUID, text: String, isBlank: Bool)
    case missingSelectedRevision(pointerID: UUID)
    case rawOCR(resultID: UUID, text: String, isBlank: Bool)
    case emptyNoTranscription

    var displayText: String? {
        switch self {
        case .manualRevision(_, let text, _):
            return text
        case .missingSelectedRevision:
            return nil
        case .rawOCR(_, let text, _):
            return text
        case .emptyNoTranscription:
            return nil
        }
    }

    var isBlank: Bool {
        switch self {
        case .manualRevision(_, _, let isBlank):
            return isBlank
        case .rawOCR(_, _, let isBlank):
            return isBlank
        case .missingSelectedRevision, .emptyNoTranscription:
            return false
        }
    }

    /// Identity of whatever the current text came from: a manual revision, a pending
    /// revision pointer, or an OCR result. Drafts compare against this to detect any
    /// underlying change, including a new OCR result when no manual revision exists.
    var sourceID: UUID? {
        switch self {
        case .manualRevision(let id, _, _): return id
        case .missingSelectedRevision(let id): return id
        case .rawOCR(let id, _, _): return id
        case .emptyNoTranscription: return nil
        }
    }

    /// Editing is blocked while the selected revision has not been delivered, so a save
    /// can never silently replace a pointer the user (or another device) chose.
    var allowsEditing: Bool {
        if case .missingSelectedRevision = self { return false }
        return true
    }

    /// Only text that exists can be marked reviewed.
    var allowsReview: Bool {
        switch self {
        case .manualRevision, .rawOCR: return true
        case .missingSelectedRevision, .emptyNoTranscription: return false
        }
    }
}

nonisolated enum DraftConflictState: Equatable, Sendable {
    case noConflict
    case conflict(baseSourceID: UUID?, currentSourceID: UUID?, currentText: String)
}

nonisolated struct PageDetail: Identifiable, Sendable, Equatable {
    let id: UUID
    let position: Int64
    let imageID: UUID?
    let imageVersion: UUID
    let rawOCRText: String?
    let ocrResultID: UUID?
    let selectedRevisionID: UUID?
    let reviewedRevisionID: UUID?
    let isReviewed: Bool
    let revisions: [TranscriptRevisionSummary]
    let canonicalResolution: CanonicalTextStatus
    let lowConfidenceLineCount: Int
    /// Engine that produced `rawOCRText` (see `OCREngine`).
    var ocrEngine: String? = nil
}

/// Pure, deterministic rules. No view, store, or clock access.
nonisolated enum TranscriptSelectionLogic {
    static func resolveCanonicalText(
        selectedRevisionID: UUID?,
        rawOCRText: String?,
        ocrResultID: UUID?,
        revisions: [TranscriptRevisionSummary]
    ) -> CanonicalTextStatus {
        if let selectedID = selectedRevisionID {
            if let match = revisions.first(where: { $0.id == selectedID }) {
                return .manualRevision(revisionID: selectedID, text: match.text, isBlank: match.text.isEmpty)
            } else {
                return .missingSelectedRevision(pointerID: selectedID)
            }
        } else if let resultID = ocrResultID {
            let text = rawOCRText ?? ""
            return .rawOCR(resultID: resultID, text: text, isBlank: text.isEmpty)
        } else {
            return .emptyNoTranscription
        }
    }

    /// Newest first; identical timestamps (e.g. merged from another device) tie-break by UUID.
    static func orderedRevisions(_ revisions: [TranscriptRevisionSummary]) -> [TranscriptRevisionSummary] {
        revisions.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }
    }

    /// A conflict exists only when the user changed the draft, the underlying source changed
    /// since editing began, and the new text differs from what the user has typed.
    static func detectConflict(
        editingBaseSourceID: UUID?,
        currentSourceID: UUID?,
        currentText: String,
        draftText: String,
        initialDraftText: String
    ) -> DraftConflictState {
        guard draftText != initialDraftText,
              editingBaseSourceID != currentSourceID,
              draftText != currentText else {
            return .noConflict
        }
        return .conflict(baseSourceID: editingBaseSourceID, currentSourceID: currentSourceID, currentText: currentText)
    }

    /// A save requires a deliberate change. Clearing all text is a change and saves a valid blank revision.
    static func canSave(resolution: CanonicalTextStatus, isDirty: Bool) -> Bool {
        resolution.allowsEditing && isDirty
    }

    /// Explicit manual merge: the user's words first, then the latest saved text, unaltered.
    static func merge(draft: String, latest: String) -> String {
        if latest.isEmpty { return draft }
        if draft.isEmpty { return latest }
        return draft + "\n\n" + latest
    }

    static func computeIsReviewed(
        selectedRevisionID: UUID?,
        ocrResultID: UUID?,
        reviewedRevisionID: UUID?
    ) -> Bool {
        guard let reviewedID = reviewedRevisionID else { return false }
        if let selectedID = selectedRevisionID {
            return reviewedID == selectedID
        } else if let resultID = ocrResultID {
            return reviewedID == resultID
        }
        return false
    }
}

/// Per-page unsaved drafts for one open entry. Drafts survive page changes and store reloads;
/// they are only replaced by an explicit user choice.
@MainActor
@Observable
final class EntryDraftCoordinator {
    struct PageDraftEntry: Equatable {
        var draftText: String
        /// Manual revision the draft was based on; recorded as the new revision's base.
        var baseRevisionID: UUID?
        /// Source identity (revision, pointer or OCR result) used for conflict detection.
        var baseSourceID: UUID?
        var initialText: String
    }

    private(set) var drafts: [UUID: PageDraftEntry] = [:]

    func draft(for page: PageDetail) -> String {
        if let existing = drafts[page.id] {
            return existing.draftText
        }
        return page.canonicalResolution.displayText ?? ""
    }

    func setDraft(_ text: String, for page: PageDetail) {
        if var existing = drafts[page.id] {
            existing.draftText = text
            drafts[page.id] = existing
        } else {
            let initial = page.canonicalResolution.displayText ?? ""
            guard text != initial else { return }
            drafts[page.id] = PageDraftEntry(
                draftText: text,
                baseRevisionID: page.selectedRevisionID,
                baseSourceID: page.canonicalResolution.sourceID,
                initialText: initial
            )
        }
    }

    func baseRevisionID(for pageID: UUID) -> UUID? {
        drafts[pageID]?.baseRevisionID
    }

    func isDirty(for pageID: UUID) -> Bool {
        guard let entry = drafts[pageID] else { return false }
        return entry.draftText != entry.initialText
    }

    var dirtyPageIDs: Set<UUID> {
        Set(drafts.compactMap { $0.value.draftText != $0.value.initialText ? $0.key : nil })
    }

    func canSave(_ page: PageDetail) -> Bool {
        TranscriptSelectionLogic.canSave(resolution: page.canonicalResolution, isDirty: isDirty(for: page.id))
    }

    func conflict(for page: PageDetail) -> DraftConflictState {
        guard let entry = drafts[page.id] else { return .noConflict }
        return TranscriptSelectionLogic.detectConflict(
            editingBaseSourceID: entry.baseSourceID,
            currentSourceID: page.canonicalResolution.sourceID,
            currentText: page.canonicalResolution.displayText ?? "",
            draftText: entry.draftText,
            initialDraftText: entry.initialText
        )
    }

    /// Call after loading fresh page data. An unchanged draft follows the new text; a changed
    /// draft is always kept (and surfaces as a conflict if its source moved).
    func reconcile(with page: PageDetail) {
        guard let entry = drafts[page.id] else { return }
        if entry.draftText == entry.initialText {
            drafts.removeValue(forKey: page.id)
        } else if entry.draftText == (page.canonicalResolution.displayText ?? ""),
                  entry.baseSourceID != page.canonicalResolution.sourceID {
            // The saved text already matches what the user typed; nothing remains unsaved.
            drafts.removeValue(forKey: page.id)
        }
    }

    func clearDraft(for pageID: UUID) {
        drafts.removeValue(forKey: pageID)
    }

    func clearAll() {
        drafts.removeAll()
    }

    /// Discard the draft and show the latest saved text.
    func adoptCurrentText(for page: PageDetail) {
        drafts.removeValue(forKey: page.id)
    }

    /// Keep the draft text but base it on the latest saved version, resolving the conflict.
    func keepDraftAsLatest(for page: PageDetail) {
        rebase(page: page, text: drafts[page.id]?.draftText)
    }

    /// Append the latest saved text below the draft so the user can combine them by hand.
    func mergeWithLatest(for page: PageDetail) {
        guard let entry = drafts[page.id] else { return }
        let latest = page.canonicalResolution.displayText ?? ""
        rebase(page: page, text: TranscriptSelectionLogic.merge(draft: entry.draftText, latest: latest))
    }

    private func rebase(page: PageDetail, text: String?) {
        guard let text else { return }
        let current = page.canonicalResolution.displayText ?? ""
        guard text != current else {
            drafts.removeValue(forKey: page.id)
            return
        }
        drafts[page.id] = PageDraftEntry(
            draftText: text,
            baseRevisionID: page.selectedRevisionID,
            baseSourceID: page.canonicalResolution.sourceID,
            initialText: current
        )
    }
}
