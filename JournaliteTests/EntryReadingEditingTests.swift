import CoreData
import Foundation
import Testing
@testable import Journalite

@MainActor
struct EntryReadingEditingTests {
    private func withStore(_ body: (PersistenceController, URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("EntryReading.sqlite")
        let store = PersistenceController(location: .sqlite(url))
        defer {
            try? store.close()
            try? FileManager.default.removeItem(at: folder)
        }
        try await store.load()
        try await body(store, url)
    }

    private func createTestEntry(_ repository: JournalRepository, notebook: UUID) async throws -> (entryID: UUID, pageID: UUID) {
        let draft = PageDraft(
            sourceData: Data(repeating: 0xAB, count: 50_000),
            contentType: "image/jpeg",
            pixelWidth: 100,
            pixelHeight: 100,
            sourceKind: "photoImport",
            sourceHash: "test-hash"
        )
        let entryID = try await repository.createEntry(
            notebookID: notebook,
            title: "Test Journal Entry",
            journalDate: Date(),
            pages: [draft]
        )
        let pages = try await repository.pages(entryID: entryID)
        let pageID = try #require(pages.first?.id)
        return (entryID, pageID)
    }

    private func page(_ id: UUID = UUID(), selected: UUID? = nil, ocrResult: UUID? = UUID(), raw: String? = nil,
                      revisions: [TranscriptRevisionSummary] = []) -> PageDetail {
        PageDetail(
            id: id, position: 0, imageID: UUID(), imageVersion: UUID(), rawOCRText: raw, ocrResultID: ocrResult,
            selectedRevisionID: selected, reviewedRevisionID: nil, isReviewed: false, revisions: revisions,
            canonicalResolution: TranscriptSelectionLogic.resolveCanonicalText(
                selectedRevisionID: selected, rawOCRText: raw, ocrResultID: ocrResult, revisions: revisions),
            lowConfidenceLineCount: 0)
    }

    private func revision(_ text: String, id: UUID = UUID(), at date: Date = Date()) -> TranscriptRevisionSummary {
        TranscriptRevisionSummary(id: id, text: text, createdAt: date, baseRevisionID: nil, imageVersion: nil, isSelected: false)
    }

    // MARK: - 1. Canonical Text Deterministic Rules

    @Test func canonicalTextSelectionDeterministicRules() {
        let revID = UUID()
        let rev1 = TranscriptRevisionSummary(
            id: revID,
            text: "Manual correction text",
            createdAt: Date(),
            baseRevisionID: nil,
            imageVersion: nil,
            isSelected: true
        )

        // Case 1: Manual revision selected and found
        let res1 = TranscriptSelectionLogic.resolveCanonicalText(
            selectedRevisionID: revID,
            rawOCRText: "OCR raw text",
            ocrResultID: UUID(),
            revisions: [rev1]
        )
        #expect(res1 == .manualRevision(revisionID: revID, text: "Manual correction text", isBlank: false))
        #expect(res1.displayText == "Manual correction text")
        #expect(!res1.isBlank)

        // Case 2: Intentionally blank manual revision
        let blankRevID = UUID()
        let blankRev = TranscriptRevisionSummary(
            id: blankRevID,
            text: "",
            createdAt: Date(),
            baseRevisionID: nil,
            imageVersion: nil,
            isSelected: true
        )
        let res2 = TranscriptSelectionLogic.resolveCanonicalText(
            selectedRevisionID: blankRevID,
            rawOCRText: "OCR recognized text",
            ocrResultID: UUID(),
            revisions: [blankRev]
        )
        #expect(res2 == .manualRevision(revisionID: blankRevID, text: "", isBlank: true))
        #expect(res2.displayText == "")
        #expect(res2.isBlank)

        // Case 3: Selected revision pointer preserved when missing from store (sync delay). Never silently fall back to OCR!
        let missingID = UUID()
        let res3 = TranscriptSelectionLogic.resolveCanonicalText(
            selectedRevisionID: missingID,
            rawOCRText: "OCR raw text",
            ocrResultID: UUID(),
            revisions: [rev1]
        )
        #expect(res3 == .missingSelectedRevision(pointerID: missingID))
        #expect(res3.displayText == nil)

        // Case 4: No manual revision selected, raw OCR exists
        let ocrID = UUID()
        let res4 = TranscriptSelectionLogic.resolveCanonicalText(
            selectedRevisionID: nil,
            rawOCRText: "Direct OCR output",
            ocrResultID: ocrID,
            revisions: []
        )
        #expect(res4 == .rawOCR(resultID: ocrID, text: "Direct OCR output", isBlank: false))
        #expect(res4.displayText == "Direct OCR output")

        // Case 5: No manual revision and no OCR
        let res5 = TranscriptSelectionLogic.resolveCanonicalText(
            selectedRevisionID: nil,
            rawOCRText: nil,
            ocrResultID: nil,
            revisions: []
        )
        #expect(res5 == .emptyNoTranscription)
        #expect(res5.displayText == nil)
    }

    // MARK: - 2. Draft Conflict Detection

    @Test func draftConflictDetectionBehavior() {
        let rev1 = UUID()
        let rev2 = UUID()

        // Clean draft: user didn't modify text -> no conflict even if the source changed
        let noConflictClean = TranscriptSelectionLogic.detectConflict(
            editingBaseSourceID: rev1,
            currentSourceID: rev2,
            currentText: "Updated server text",
            draftText: "Original text",
            initialDraftText: "Original text"
        )
        #expect(noConflictClean == .noConflict)

        // Dirty draft: user modified text and the source changed -> conflict
        let conflictDirty = TranscriptSelectionLogic.detectConflict(
            editingBaseSourceID: rev1,
            currentSourceID: rev2,
            currentText: "Updated server text",
            draftText: "User has typed modifications",
            initialDraftText: "Original text"
        )
        #expect(conflictDirty == .conflict(baseSourceID: rev1, currentSourceID: rev2, currentText: "Updated server text"))

        // Dirty draft, unchanged source -> no conflict
        let noConflictSameRev = TranscriptSelectionLogic.detectConflict(
            editingBaseSourceID: rev1,
            currentSourceID: rev1,
            currentText: "Original text",
            draftText: "User has typed modifications",
            initialDraftText: "Original text"
        )
        #expect(noConflictSameRev == .noConflict)

        // Source changed to exactly what the user typed -> nothing to resolve
        let sameText = TranscriptSelectionLogic.detectConflict(
            editingBaseSourceID: rev1,
            currentSourceID: rev2,
            currentText: "Psalm 23:1 — Grandma Ruthie",
            draftText: "Psalm 23:1 — Grandma Ruthie",
            initialDraftText: "Original text"
        )
        #expect(sameText == .noConflict)

        // A draft started before any transcription existed conflicts with a first OCR result
        let firstOCR = UUID()
        let fromNothing = TranscriptSelectionLogic.detectConflict(
            editingBaseSourceID: nil,
            currentSourceID: firstOCR,
            currentText: "Recognized",
            draftText: "Typed by hand",
            initialDraftText: ""
        )
        #expect(fromNothing == .conflict(baseSourceID: nil, currentSourceID: firstOCR, currentText: "Recognized"))
    }

    @Test func newOCRResultWhileEditingOCRTextPreservesDraftAndRaisesConflict() {
        let drafts = EntryDraftCoordinator()
        let pageID = UUID()
        let before = page(pageID, ocrResult: UUID(), raw: "Jhon 3:16")
        drafts.setDraft("John 3:16", for: before)

        // OCR finishes again while the editor is open. No manual revision exists on either side.
        let after = page(pageID, ocrResult: UUID(), raw: "Jon 3:16")
        drafts.reconcile(with: after)

        #expect(drafts.draft(for: after) == "John 3:16")
        #expect(drafts.isDirty(for: pageID))
        #expect(drafts.conflict(for: after) != .noConflict)
    }

    @Test func reconcileFollowsCleanDraftsAndKeepsChangedOnes() {
        let drafts = EntryDraftCoordinator()
        let pageID = UUID()
        let before = page(pageID, raw: "Original")
        drafts.setDraft("Edited", for: before)
        drafts.setDraft("Original", for: before) // Typed back to the starting text: clean.
        let after = page(pageID, raw: "Fresh OCR")
        drafts.reconcile(with: after)
        #expect(drafts.draft(for: after) == "Fresh OCR")
        #expect(!drafts.isDirty(for: pageID))

        drafts.setDraft("Mine", for: after)
        drafts.reconcile(with: page(pageID, raw: "Even newer OCR"))
        #expect(drafts.draft(for: after) == "Mine")
        #expect(drafts.dirtyPageIDs == [pageID])
    }

    @Test func saveRequiresDeliberateChangeAndBlankIsSavable() {
        let drafts = EntryDraftCoordinator()

        // Untouched page with no transcription: nothing to save (no accidental blank revisions).
        let untranscribed = page(ocrResult: nil)
        #expect(!drafts.canSave(untranscribed))
        drafts.setDraft("", for: untranscribed)
        #expect(!drafts.canSave(untranscribed))

        // Clearing OCR text is a deliberate change and saves a valid blank revision.
        let recognized = page(raw: "Noise")
        drafts.setDraft("", for: recognized)
        #expect(drafts.canSave(recognized))
        #expect(drafts.draft(for: recognized) == "")

        // A selected revision that has not been delivered cannot be edited or replaced.
        let pending = page(selected: UUID(), raw: "OCR")
        #expect(pending.canonicalResolution == .missingSelectedRevision(pointerID: pending.selectedRevisionID!))
        #expect(!pending.canonicalResolution.allowsEditing)
        #expect(!pending.canonicalResolution.allowsReview)
        drafts.setDraft("Typed anyway", for: pending)
        #expect(!drafts.canSave(pending))
    }

    @Test func conflictChoicesKeepMergeOrDiscardOnlyOnRequest() {
        let pageID = UUID()
        let base = page(pageID, raw: "Dear Mom,")
        let latestRevision = revision("Dear Mom, the lake was calm.")
        let latest = page(pageID, selected: latestRevision.id, raw: "Dear Mom,", revisions: [latestRevision])

        let keep = EntryDraftCoordinator()
        keep.setDraft("Dear Mama,", for: base)
        keep.keepDraftAsLatest(for: latest)
        #expect(keep.draft(for: latest) == "Dear Mama,")
        #expect(keep.conflict(for: latest) == .noConflict)
        #expect(keep.baseRevisionID(for: pageID) == latestRevision.id)

        let merge = EntryDraftCoordinator()
        merge.setDraft("Dear Mama,", for: base)
        merge.mergeWithLatest(for: latest)
        #expect(merge.draft(for: latest) == "Dear Mama,\n\nDear Mom, the lake was calm.")
        #expect(merge.conflict(for: latest) == .noConflict)

        let discard = EntryDraftCoordinator()
        discard.setDraft("Dear Mama,", for: base)
        discard.adoptCurrentText(for: latest)
        #expect(discard.draft(for: latest) == "Dear Mom, the lake was calm.")
        #expect(!discard.isDirty(for: pageID))
    }

    @Test func revisionOrderIsDeterministicForTiedTimestamps() {
        let moment = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let a = revision("a", id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, at: moment)
        let b = revision("b", id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, at: moment)
        let newer = revision("newer", at: moment.addingTimeInterval(1))
        #expect(TranscriptSelectionLogic.orderedRevisions([b, newer, a]).map(\.text) == ["newer", "a", "b"])
        #expect(TranscriptSelectionLogic.orderedRevisions([a, b, newer]).map(\.text) == ["newer", "a", "b"])
    }

    // MARK: - 3. Corrections Survive Relaunch and OCR Retries

    @Test func correctionsSurviveRelaunchAndOCRRetries() async throws {
        try await withStore { store, url in
            let repository = try store.repository()
            let notebookID = try await repository.createNotebook(name: "Journal")
            let (_, pageID) = try await createTestEntry(repository, notebook: notebookID)

            // 1. Initial OCR save
            let initialSnapshot = try #require(try await repository.ocrPage(id: pageID))
            let ocr1ID = UUID()
            let job1 = OCRJob(key: initialSnapshot.key, resultID: ocr1ID, language: "en-US", state: .running)
            let ocrResult1 = OCRResult(text: "Initial OCR text from camera", revision: 3, language: "en-US", lowConfidenceLineCount: 0)
            let saved1 = try await repository.saveOCR(ocrResult1, job: job1)
            #expect(saved1)

            // Verify initial canonical text is OCR
            let detail1 = try #require(try await repository.pageDetail(pageID: pageID))
            #expect(detail1.canonicalResolution.displayText == "Initial OCR text from camera")

            // 2. User saves a manual correction
            let revID = try await repository.appendCorrection(pageID: pageID, text: "User's deliberate manual edit")
            let detail2 = try #require(try await repository.pageDetail(pageID: pageID))
            #expect(detail2.selectedRevisionID == revID)
            #expect(detail2.canonicalResolution.displayText == "User's deliberate manual edit")

            // 3. Relaunch app: close store and reopen SQLite
            try store.close()
            let reopened = PersistenceController(location: .sqlite(url))
            try await reopened.load()
            defer { try? reopened.close() }
            let reopenedRepo = try reopened.repository()

            let detail3 = try #require(try await reopenedRepo.pageDetail(pageID: pageID))
            #expect(detail3.canonicalResolution.displayText == "User's deliberate manual edit")

            // 4. OCR Retry runs in background
            let snapshotAfterReopen = try #require(try await reopenedRepo.ocrPage(id: pageID))
            let ocr2ID = UUID()
            let job2 = OCRJob(key: snapshotAfterReopen.key, resultID: ocr2ID, language: "en-US", state: .running)
            let ocrResult2 = OCRResult(text: "Retried OCR text from new recognition run", revision: 3, language: "en-US", lowConfidenceLineCount: 0)
            let saved2 = try await reopenedRepo.saveOCR(ocrResult2, job: job2)
            #expect(saved2)

            // Verify: Manual correction is RETAINED, raw OCR updated independently
            let detail4 = try #require(try await reopenedRepo.pageDetail(pageID: pageID))
            #expect(detail4.canonicalResolution.displayText == "User's deliberate manual edit")
            #expect(detail4.rawOCRText == "Retried OCR text from new recognition run")
            #expect(detail4.ocrResultID == ocr2ID)

            // 5. An explicit Retry OCR makes the new result current but keeps the correction in history.
            var job3 = OCRJob(key: snapshotAfterReopen.key, resultID: UUID(), language: "en-US", state: .running)
            job3.selectsResult = true
            _ = try await reopenedRepo.saveOCR(OCRResult(text: "Explicit retry text", revision: 3, language: "en-US", lowConfidenceLineCount: 0), job: job3)
            let detail5 = try #require(try await reopenedRepo.pageDetail(pageID: pageID))
            #expect(detail5.canonicalResolution.displayText == "Explicit retry text")
            #expect(detail5.revisions.map(\.id) == [revID])

            // 6. The correction can be brought back by restoring it, exactly as typed.
            _ = try await reopenedRepo.restoreRevision(pageID: pageID, revisionID: revID)
            let detail6 = try #require(try await reopenedRepo.pageDetail(pageID: pageID))
            #expect(detail6.canonicalResolution.displayText == "User's deliberate manual edit")
            #expect(detail6.revisions.count == 2)
        }
    }

    // MARK: - 4. Blank Edits Stay Blank

    @Test func blankEditsStayBlankAcrossRelaunchAndOCR() async throws {
        try await withStore { store, url in
            let repository = try store.repository()
            let notebookID = try await repository.createNotebook(name: "Journal")
            let (_, pageID) = try await createTestEntry(repository, notebook: notebookID)

            // Save initial OCR
            let snapshot = try #require(try await repository.ocrPage(id: pageID))
            let job = OCRJob(key: snapshot.key, resultID: UUID(), language: "en-US", state: .running)
            let ocrResult = OCRResult(text: "Some recognized noise", revision: 3, language: "en-US", lowConfidenceLineCount: 0)
            _ = try await repository.saveOCR(ocrResult, job: job)

            // User saves an intentionally empty transcription
            _ = try await repository.appendCorrection(pageID: pageID, text: "")

            let detail1 = try #require(try await repository.pageDetail(pageID: pageID))
            #expect(detail1.canonicalResolution == .manualRevision(revisionID: detail1.selectedRevisionID!, text: "", isBlank: true))
            #expect(detail1.canonicalResolution.displayText == "")
            #expect(detail1.canonicalResolution.isBlank)

            // Reopen store
            try store.close()
            let reopened = PersistenceController(location: .sqlite(url))
            try await reopened.load()
            defer { try? reopened.close() }
            let reopenedRepo = try reopened.repository()

            let detail2 = try #require(try await reopenedRepo.pageDetail(pageID: pageID))
            #expect(detail2.canonicalResolution.displayText == "")
            #expect(detail2.canonicalResolution.isBlank)

            // Rerun OCR
            let snapshot2 = try #require(try await reopenedRepo.ocrPage(id: pageID))
            let job2 = OCRJob(key: snapshot2.key, resultID: UUID(), language: "en-US", state: .running)
            let ocrResult2 = OCRResult(text: "Different noise", revision: 3, language: "en-US", lowConfidenceLineCount: 0)
            _ = try await reopenedRepo.saveOCR(ocrResult2, job: job2)

            // Blank edit still stays blank!
            let detail3 = try #require(try await reopenedRepo.pageDetail(pageID: pageID))
            #expect(detail3.canonicalResolution.displayText == "")
            #expect(detail3.canonicalResolution.isBlank)
            #expect(detail3.rawOCRText == "Different noise")
        }
    }

    // MARK: - 5. Changing Pages Does Not Lose a Draft

    @Test func changingPagesDoesNotLoseDraft() {
        let coordinator = EntryDraftCoordinator()
        let page1ID = UUID()
        let page2ID = UUID()

        let page1 = PageDetail(
            id: page1ID,
            position: 0,
            imageID: UUID(),
            imageVersion: UUID(),
            rawOCRText: "Page 1 Saved Text",
            ocrResultID: UUID(),
            selectedRevisionID: nil,
            reviewedRevisionID: nil,
            isReviewed: false,
            revisions: [],
            canonicalResolution: .rawOCR(resultID: UUID(), text: "Page 1 Saved Text", isBlank: false),
            lowConfidenceLineCount: 0
        )

        let page2 = PageDetail(
            id: page2ID,
            position: 1,
            imageID: UUID(),
            imageVersion: UUID(),
            rawOCRText: "Page 2 Saved Text",
            ocrResultID: UUID(),
            selectedRevisionID: nil,
            reviewedRevisionID: nil,
            isReviewed: false,
            revisions: [],
            canonicalResolution: .rawOCR(resultID: UUID(), text: "Page 2 Saved Text", isBlank: false),
            lowConfidenceLineCount: 0
        )

        // User starts editing Page 1
        coordinator.setDraft("Page 1 User In-Progress Typing", for: page1)
        #expect(coordinator.isDirty(for: page1ID))
        #expect(coordinator.draft(for: page1) == "Page 1 User In-Progress Typing")

        // User flips to Page 2
        #expect(coordinator.draft(for: page2) == "Page 2 Saved Text")
        #expect(!coordinator.isDirty(for: page2ID))

        // User flips BACK to Page 1: draft was preserved!
        #expect(coordinator.draft(for: page1) == "Page 1 User In-Progress Typing")
        #expect(coordinator.isDirty(for: page1ID))
    }

    // MARK: - 6. Restoring a Revision Preserves History

    @Test func restoringRevisionPreservesHistory() async throws {
        try await withStore { store, _ in
            let repository = try store.repository()
            let notebookID = try await repository.createNotebook(name: "Journal")
            let (_, pageID) = try await createTestEntry(repository, notebook: notebookID)

            // Rev 1
            let rev1ID = try await repository.appendCorrection(pageID: pageID, text: "Revision 1 text")
            // Rev 2
            let rev2ID = try await repository.appendCorrection(pageID: pageID, text: "Revision 2 text")

            let detailBefore = try #require(try await repository.pageDetail(pageID: pageID))
            #expect(detailBefore.revisions.count == 2)
            #expect(detailBefore.selectedRevisionID == rev2ID)

            // Restore Rev 1
            let restoredID = try await repository.restoreRevision(pageID: pageID, revisionID: rev1ID)
            #expect(restoredID != rev1ID) // Creates a NEW revision

            let detailAfter = try #require(try await repository.pageDetail(pageID: pageID))
            #expect(detailAfter.revisions.count == 3) // History was NOT deleted!
            #expect(detailAfter.selectedRevisionID == restoredID)
            #expect(detailAfter.canonicalResolution.displayText == "Revision 1 text")

            let restoredSummary = try #require(detailAfter.revisions.first { $0.id == restoredID })
            #expect(restoredSummary.baseRevisionID == rev2ID)
        }
    }

    // MARK: - 7. Review State Invalidation on Changes & OCR

    @Test func reviewStateUpdatesOnCorrectionAndOCR() async throws {
        try await withStore { store, _ in
            let repository = try store.repository()
            let notebookID = try await repository.createNotebook(name: "Journal")
            let (_, pageID) = try await createTestEntry(repository, notebook: notebookID)

            // Save OCR
            let snapshot = try #require(try await repository.ocrPage(id: pageID))
            let job = OCRJob(key: snapshot.key, resultID: UUID(), language: "en-US", state: .running)
            _ = try await repository.saveOCR(OCRResult(text: "OCR Text", revision: 3, language: "en-US", lowConfidenceLineCount: 0), job: job)

            // Initially not reviewed
            let d1 = try #require(try await repository.pageDetail(pageID: pageID))
            #expect(!d1.isReviewed)

            // Mark reviewed
            try await repository.markPageReviewed(pageID: pageID, reviewed: true)
            let d2 = try #require(try await repository.pageDetail(pageID: pageID))
            #expect(d2.isReviewed)

            // New OCR result resets review state
            let job2 = OCRJob(key: snapshot.key, resultID: UUID(), language: "en-US", state: .running)
            _ = try await repository.saveOCR(OCRResult(text: "New OCR Text", revision: 3, language: "en-US", lowConfidenceLineCount: 0), job: job2)
            let d3 = try #require(try await repository.pageDetail(pageID: pageID))
            #expect(!d3.isReviewed)

            // Mark reviewed again
            try await repository.markPageReviewed(pageID: pageID, reviewed: true)
            let d4 = try #require(try await repository.pageDetail(pageID: pageID))
            #expect(d4.isReviewed)

            // Saving manual revision resets review state
            let manualID = try await repository.appendCorrection(pageID: pageID, text: "Manual revision text")
            let d5 = try #require(try await repository.pageDetail(pageID: pageID))
            #expect(!d5.isReviewed)

            // Reviewing records the specific revision.
            try await repository.markPageReviewed(pageID: pageID, reviewed: true)
            let d6 = try #require(try await repository.pageDetail(pageID: pageID))
            #expect(d6.isReviewed)
            #expect(d6.reviewedRevisionID == manualID)

            // Automatic OCR does not change the reviewed manual text, so review state stays.
            let job3 = OCRJob(key: snapshot.key, resultID: UUID(), language: "en-US", state: .running)
            _ = try await repository.saveOCR(OCRResult(text: "Background OCR", revision: 3, language: "en-US", lowConfidenceLineCount: 0), job: job3)
            #expect(try #require(try await repository.pageDetail(pageID: pageID)).isReviewed)

            // Restoring a different revision is a text change: needs review again.
            _ = try await repository.appendCorrection(pageID: pageID, text: "Second wording")
            _ = try await repository.restoreRevision(pageID: pageID, revisionID: manualID)
            #expect(!(try #require(try await repository.pageDetail(pageID: pageID))).isReviewed)
        }
    }

    // MARK: - Revision Lineage

    @Test func savedRevisionRecordsStableIDImageVersionAndExactBase() async throws {
        try await withStore { store, url in
            let repository = try store.repository()
            let notebookID = try await repository.createNotebook(name: "Journal")
            let (_, pageID) = try await createTestEntry(repository, notebook: notebookID)
            let imageVersion = try #require(try await repository.pageDetail(pageID: pageID)).imageVersion

            // Omitted base: follows the current selection.
            let first = try await repository.appendCorrection(pageID: pageID, text: "First")
            let second = try await repository.appendCorrection(pageID: pageID, text: "Second")
            // A draft started from OCR (no revision) saved after a conflict keeps a nil base.
            let fromOCR = try await repository.appendCorrection(pageID: pageID, text: "From OCR draft", baseRevisionID: .some(nil))
            // A draft started from `first` keeps that base even though `fromOCR` is now selected.
            let fromFirst = try await repository.appendCorrection(pageID: pageID, text: "From first", baseRevisionID: first)

            try store.close()
            let reopened = PersistenceController(location: .sqlite(url))
            try await reopened.load()
            defer { try? reopened.close() }
            let detail = try #require(try await reopened.repository().pageDetail(pageID: pageID))
            let byID = Dictionary(uniqueKeysWithValues: detail.revisions.map { ($0.id, $0) })
            #expect(Set(byID.keys) == [first, second, fromOCR, fromFirst])
            #expect(byID[first]?.baseRevisionID == nil)
            #expect(byID[second]?.baseRevisionID == first)
            #expect(byID[fromOCR]?.baseRevisionID == nil)
            #expect(byID[fromFirst]?.baseRevisionID == first)
            #expect(detail.revisions.allSatisfy { $0.imageVersion == imageVersion })
            #expect(detail.selectedRevisionID == fromFirst)
        }
    }

    @Test func restoreRejectsRevisionFromAnotherPage() async throws {
        try await withStore { store, _ in
            let repository = try store.repository()
            let notebookID = try await repository.createNotebook(name: "Journal")
            let (_, pageA) = try await createTestEntry(repository, notebook: notebookID)
            let (_, pageB) = try await createTestEntry(repository, notebook: notebookID)
            let foreign = try await repository.appendCorrection(pageID: pageB, text: "Page B text")
            await #expect(throws: PersistenceError.self) {
                try await repository.restoreRevision(pageID: pageA, revisionID: foreign)
            }
            #expect(try #require(try await repository.pageDetail(pageID: pageA)).revisions.isEmpty)
        }
    }

    // MARK: - 8. Page Management (Add, Reorder, Remove, Restore)

    @Test func pageManagementAddReorderRemoveRestore() async throws {
        try await withStore { store, _ in
            let repository = try store.repository()
            let notebookID = try await repository.createNotebook(name: "Journal")

            let draft1 = PageDraft(sourceData: Data([1, 2, 3]), contentType: "image/jpeg", pixelWidth: 10, pixelHeight: 10, sourceKind: "import", sourceHash: nil)
            let draft2 = PageDraft(sourceData: Data([4, 5, 6]), contentType: "image/jpeg", pixelWidth: 10, pixelHeight: 10, sourceKind: "import", sourceHash: nil)
            let entryID = try await repository.createEntry(notebookID: notebookID, title: "Pages Test", journalDate: Date(), pages: [draft1, draft2])

            let pagesBefore = try await repository.pages(entryID: entryID)
            #expect(pagesBefore.count == 2)
            let page0ID = pagesBefore[0].id
            let page1ID = pagesBefore[1].id

            // Add 3rd page
            let draft3 = PageDraft(sourceData: Data([7, 8, 9]), contentType: "image/jpeg", pixelWidth: 10, pixelHeight: 10, sourceKind: "import", sourceHash: nil)
            let addedIDs = try await repository.addPages(to: entryID, drafts: [draft3])
            #expect(addedIDs.count == 1)
            let page2ID = addedIDs[0]

            let pagesAfterAdd = try await repository.pages(entryID: entryID)
            #expect(pagesAfterAdd.count == 3)
            #expect(pagesAfterAdd.map(\.position) == [0, 1, 2])

            // Reorder pages to: page2, page0, page1
            try await repository.reorderPages(entryID: entryID, pageIDs: [page2ID, page0ID, page1ID])
            let pagesReordered = try await repository.pages(entryID: entryID)
            #expect(pagesReordered.map(\.id) == [page2ID, page0ID, page1ID])
            #expect(pagesReordered.map(\.position) == [0, 1, 2])

            // Remove page0 (soft delete)
            try await repository.removePage(id: page0ID)
            let pagesAfterRemove = try await repository.pages(entryID: entryID)
            #expect(pagesAfterRemove.count == 2)
            #expect(pagesAfterRemove.map(\.id) == [page2ID, page1ID])
            #expect(pagesAfterRemove.map(\.position) == [0, 1])

            // Verify removed page is in deletedPages
            let deleted = try await repository.deletedPages(entryID: entryID)
            #expect(deleted.map(\.id).contains(page0ID))

            // Restore page0
            try await repository.restorePage(id: page0ID)
            let pagesAfterRestore = try await repository.pages(entryID: entryID)
            #expect(pagesAfterRestore.count == 3)
            #expect(pagesAfterRestore.map(\.position) == [0, 1, 2])
            #expect(pagesAfterRestore.last?.id == page0ID)
        }
    }
}
