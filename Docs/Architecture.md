# Architecture agreement

## Persistence foundation (retained in phase 2)
MyApp.swift remains the sole @main and owns one observable JournalAppModel. ContentView presents loading/retry states or Notebooks, Search and Settings, each with NavigationStack. A separate in-memory controller backs #Preview. No sample records enter the live store.

PersistenceController loads the bundled versioned JournalModel.xcdatamodeld (current JournalModelV3, explicitly loaded and schema-checked before opening the store). The five entities contain the requested metadata, optional inverse relationships, unordered collections and no unique constraints. All attributes are optional or defaulted for future CloudKit compatibility; the repository assigns fresh UUIDs and timestamps.

The single authoritative SQLite store lives at Application Support/Journalite/Journalite.sqlite within the app container. Preserve this location in the later supported cloud upgrade. NSPersistentContainer is used (not a CloudKit container), cloudKitContainerOptions stays nil, persistent history is enabled for SQLite, and automatic/inferred migration is enabled. Temporary SQLite migrations from V1 and V2 to V3 have passed, retaining page IDs and intentionally empty manual corrections.

JournalRepository creates notebooks and entry/page/image graphs, appends corrections, and reads immutable Sendable notebook/page summaries. Each operation uses a fresh private context and context.perform. No managed object is returned across executors. Page ordering uses position then UUID as a stable tie-break. Source bytes have no replacement API; revisions have no update API. These invariants are enforced at the repository boundary, not as Core Data model-level immutability constraints.

JournalAppModel reports load/fetch failure without printing underlying payloads. Retry retains the same store; the recovery screen explains backup preservation and that archive export is not yet available. It never claims an export succeeded and never deletes a failed store.

JournaliteTests uses Swift Testing. SQLite close/reopen checks exercise real persistence, image data, inverse relationships, history, ordering, and selected empty corrections; in-memory checks validate model configuration and isolation. Capture/import and OCR execution are implemented below. Search index, account, sync and AI remain unimplemented.

## Phase 2 library implementation
- ContentView presents onboarding until the device-local hasStartedLocalJournal preference is saved. Starter choices default off; Start on this iPhone saves only selected names in one transaction. Retrying after interruption does not duplicate an existing live starter name. No permission APIs are invoked.
- LibraryViews supplies a notebook list, recent entries, notebook editing, and notebook removal choices. Colors and symbols have visible names; adaptive system colors and text styles support Dark Mode and Dynamic Type. Native labeled controls and combined row accessibility expose meaning beyond color.
- LibraryRepository returns EntrySummary values and EntryBatch pages, with SQLite fetch limits (default 25, maximum 100) and journalDate descending / UUID ascending order. Recent entries use the same ordering, limited to 10. Offset pagination resets on local mutations or refresh.
- Row summaries never fetch PageImage or sourceData. A bounded dictionary fetch of JournalPage.id/imageVersion provides a stable ThumbnailIdentifier for the next phase’s thumbnail cache. Capture now provides a local derivative cache and paged zoomable viewer; row requests still do not decode source blobs.
- EntryRoute contains entryID and optional targetPageID. EntryViews refetches by stable ID, honors a target page, and offers retry for missing records instead of selecting another page silently. Missing notebook relationships remain visible in recent entries and can be repaired by choosing a live notebook in Edit Entry.
- Metadata updates trim titles, preserve stable entry/page IDs, and validate that the destination notebook is live. Notebook names are trimmed and must contain non-whitespace characters on both creation and rename.
- JournalAppModel serializes UI mutations, refreshes summaries after commits, and increments a revision to invalidate paged/detail views. Underlying errors are never logged or shown with sensitive payloads.

### Recently Deleted policy
Soft deletion sets deletedAt; ordinary library queries hide deleted entries and entries in deleted notebooks. Pages, source images and corrections remain intact. No automatic expiry exists.

Removing a notebook offers either moving all entries into another live notebook (including previously trashed entries, whose deleted state stays intact) or trashing the notebook and its currently live entries. A shared deletion timestamp identifies the group for this local implementation. Restoring the notebook restores only entries deleted with that group; earlier independently deleted entries remain trashed. Before a future multi-device sync phase, revisit group identity/conflict semantics; timestamps are not a general distributed conflict-resolution strategy.

Restoring an individual entry uses its original live notebook when available. Otherwise it reuses or creates a live Restored Entries notebook. An explicit destination UUID is also supported by the repository. Moving/restoring changes relationships, not stable IDs.

Permanent deletion is accepted only for trashed records and follows the model’s cascade rules through pages, images and revisions. The UI always confirms; notebook confirmation explicitly covers ALL remaining contents, including previously deleted entries. Restored or moved-out entries are no longer owned by that notebook and survive its permanent deletion.

Phase 2 required no schema change. Capture added V2 pendingIngestionID; OCR adds V3 optional ocrImageVersion and ocrLowConfidenceLineCount. Earlier versions remain bundled for inferred lightweight migration. The store location remains unchanged.

## Capture and local OCR implementation
CaptureCoordinator bridges VisionKit scanning and selected PhotosPicker file transfer. Scan alone requests camera permission; denied/unsupported scanning leaves Import Photos available. The review sheet supports destination/inline notebook creation, independent title/journal date, remove/reorder, duplicate warnings and optional separate imported-photo entries. Source bytes supplied by PhotosPicker are copied unchanged. Scans preserve a JPEG at quality 0.95 of the scanner's processed result, not an unavailable pre-scan original.

IngestionFiles stages each image sequentially with durable assigned-ID receipts. IngestionRepository saves each page separately, verifies committed hashes/bytes, and clears pendingIngestionID only after the full entry is durable. Pending entries stay hidden. ImageIO generates orientation-corrected derivatives from decoded pixels without copying GPS metadata. Source originals can contain location or other metadata. Ordinary Share Copy Without Location exports a derived JPEG. Display/cache limits: 20 pages/import, 25 MiB/source, 150 MiB/import, 48 megapixels/source; 320-pixel thumbnails, 2048-pixel display/share, and 3072-pixel OCR longest side. These are conservative limits, not a measured guarantee of total process memory. The scanner owns its own result memory. JournalImageCache caps derived JPEG disk storage at 256 MiB.

OCRRecognizer uses VNRecognizeTextRequest accurate mode and queries supportedRecognitionLanguages on the actual request. Each job captures its selected language; Settings changes affect new jobs/retries. Language auto-detection and language correction are disabled. No custom-word list is currently added. Vision runs in a detached utility task with request cancellation; OCRService's actor does ImageIO/file orchestration off the main actor. It regenerates the OCR input from saved source bytes instead of trusting a potentially stale cache, using ImageIO's transform and passing upright orientation to Vision. ImportLimits.ocrSide = 3072 is the documented tuning constant: increase only after testing fine handwriting and memory on the oldest supported iPhone. A 3072-square RGBA raster alone is about 36 MiB, excluding decoder/Vision buffers; real tests check derivative bounds, not total peak RSS.

OCRResult groups observations with nearby vertical centers (within 0.45 of the smaller line height), orders rows top-to-bottom and fragments left-to-right, joining rows with line breaks. It is intended for ordinary horizontal single-column journal pages. Strings are not expanded, summarized or rewritten. A count of observations below internal confidence 0.5 provides a review hint, not an accuracy score.

OCRRepository uses fresh private contexts. Before saving it checks the live page/entry/notebook and exact imageVersion again. Raw text (including empty string), attempt/result UUID, engine, revision, language, date, source-image version and review-hint count are saved atomically. Manual revisions and selected/reviewed revision IDs are untouched. Stale raw results are not presented as current OCR. The basic editor appends full manual revisions; a saved empty correction remains canonical.

### Durable execution and provenance
The authoritative content store remains Core Data SQLite. Application Support/Journalite/LocalOCR/queue.json is separate atomic, synchronized, protected device-local execution state; it contains ordered page/image-version keys, language, result UUID and waiting/running/completed/failed/cancelled states, never image bytes or recognized text. It is not a shared content entity. Invalid/unreadable queue files are preserved and surfaced for recovery, never silently reset.

Before deleting staged input, IngestionFiles.finish archives a compact local provenance receipt under Ingestion/OCRReceipts containing receipt ID, capture date and ordered page/image-version IDs. On launch, OCRService reconciles both saved/saving staging receipts and these retained receipts against fully committed live pages. Pending ingestion is ineligible. This closes the termination gap between image persistence and queue insertion. Missing OCR alone is never used to infer local ownership; future remotely received pages must not be automatically queued. Pre-OCR captures whose receipts were already removed can be transcribed via explicit user action.

OCRService processes at most one page at a time. Queue transitions are durable before work. Interrupted running jobs return to waiting on queue reload. Result UUIDs are assigned before recognition so a crash after the Core Data save but before queue acknowledgement can complete without rerunning. Failures stay failed until explicit retry; no polling timer or busy loop exists. Cancellation stays cancelled until user retry; deleted/stale jobs cannot write results. Scratch image copies are disposable, cleaned between runs, and never replace authoritative source bytes.

OCRCoordinator connects scenePhase to cancellation/resume. Returning active resumes waiting work; suspension can interrupt execution at any point, and no background-continuity claim is made. Page controls expose status, cancel/retry, honest empty results and manual typing. All recognized results remain Needs review; a full reviewed-state workflow is deferred.

## Entry Reading & Editing Architecture

Pure rules live in `TranscriptSelection.swift` (`TranscriptSelectionLogic`, `CanonicalTextStatus`, `EntryDraftCoordinator`) with no view, store or clock access. `JournalRepository` persists; `EntryViews.swift` only renders and routes user choices.

### Deterministic Canonical Text Resolution
```
selectedTranscriptRevisionID != nil?
  ├── Revision found in store ──> .manualRevision(text, isBlank)
  └── Revision missing from store ──> .missingSelectedRevision(pointerID) [pointer kept, no fallback]
selectedTranscriptRevisionID == nil?
  ├── ocrResultID != nil ──> .rawOCR(text, isBlank)
  └── ocrResultID == nil ──> .emptyNoTranscription
```
- **Blank edits are valid**: a selected `""` revision is canonical content and is never replaced by automatic OCR.
- **Pending pointer**: `.missingSelectedRevision` shows a waiting/recovery panel in Text and Compare. Editing and review are disabled (`allowsEditing`/`allowsReview`), so a save can never silently replace the chosen revision.
- **Source identity**: `CanonicalTextStatus.sourceID` is the revision ID, pending pointer or OCR result ID behind the current text. Drafts and review compare against it.
- Revisions are ordered newest first with a UUID tie-break (`orderedRevisions`) so merged equal timestamps are stable.

### Append-Only Revision History
- A deliberate Save appends a `TranscriptRevision` with a new stable UUID, the exact typed text, `createdAt`, the page's current `imageVersion`, and `baseRevisionID`, then selects it.
- `appendCorrection(baseRevisionID:)` takes a double optional: omitted means "based on the current selection"; passed (including `.some(nil)` for a draft begun from OCR) is recorded exactly, so drafts saved after a conflict keep true lineage.
- Restore verifies the revision belongs to the page, then appends a copy based on the previous selection. History is never edited or deleted.
- Raw OCR is stored on the page (`rawOCRText`, `ocrResultID`, engine metadata) independently of revisions. Automatic OCR never deselects a manual revision. An explicit Retry OCR (`OCRJob.selectsResult`) clears the selection so the new result becomes current; revisions remain and can be restored. The retry alert explains this before running.

### Review State Tracking
- Reviewed iff `reviewedRevisionID == (selectedTranscriptRevisionID ?? ocrResultID)` — the specific text identity, not a page flag.
- A new manual revision or restore clears review. A new OCR result clears review only when OCR is the current text; reviewed manual text stays reviewed.

### Drafts, Dirty State & Conflicts
- `EntryDraftCoordinator` stores, per page: draft text, initial text, base revision ID and base source ID. A draft is created only when the text actually changes; dirty means `draftText != initialText`. Save requires a dirty draft (`canSave`), preventing accidental blank revisions from an untouched page.
- Changing pages keeps drafts; the page menu marks pages with unsaved drafts. While drafts exist the system back button (and swipe-back) is replaced by a Back button that confirms discarding them.
- After each reload, `reconcile(with:)` lets clean drafts follow new saved text and always keeps changed drafts.
- `detectConflict` reports a conflict when the draft changed, the source ID changed (new revision, restore, other device, or a new OCR result over OCR text), and the new text differs from the draft. The editor shows a banner; `DraftConflictSheet` offers Save My Draft as a New Revision, Merge (latest text appended below the draft, unaltered), Keep My Draft (rebase), or Discard My Draft. Nothing replaces typing without one of these choices.
- Reloads refresh in place; the editor is never swapped for a loading view after the first load, and a page's editor is only shown once its detail matches the selected page.

### Compare Layout
- Fixed photo-above-editor `VStack` inside a `GeometryReader`. The photo takes 40% of available height, 28% at accessibility Dynamic Type sizes and 25% while the editor is focused; the keyboard shrinks the available height so the editor stays usable. The `TextEditor` fills the remainder and scrolls internally.
- While typing, secondary rows hide; a keyboard toolbar provides Done and Save. Mode picker, page navigation and the "Editing page N of M" header stay visible. Rows use `AdaptiveStack` to stack vertically at accessibility sizes.

### Page Management Architecture
- `EntryPageAdder` is the single path for adding scans or photos to an existing entry: same per-image, pixel and per-import byte limits as captures, every failed item reported, OCR provenance recorded and new pages queued through `ingestionSaved()`.
- `addPages(to:drafts:)` appends at `maxPosition + 1 + i`; `reorderPages` normalizes `0..<count`; `removePage` soft-deletes and compacts positions; `restorePage` clears `deletedAt` and appends at the end. Removed pages are listed in the entry's Manage Pages sheet (not the app-wide Recently Deleted list) with photos and revisions intact, and have no automatic expiry.

## Planned native stack
- Swift/SwiftUI; iOS 17 minimum. Use supported installed stable SDK APIs, with availability guards and useful fallbacks for newer APIs.
- Core Data SQLite is the authoritative local store. NSPersistentCloudKitContainer is permitted with cloudKitContainerOptions nil; do not initialize cloud services in the free configuration.
- VisionKit document scanner, PhotosPicker import, and Vision on-device OCR.
- Separate app-owned SQLite FTS5 database for rebuildable search. Never query or modify Core Data's SQLite tables with raw SQL.
- No external packages, paid OCR API, analytics, or server.

## Data invariants for implementation
| Entity | Responsibility |
| --- | --- |
| Notebook | Stable application-generated UUID and notebook identity/name |
| JournalEntry | Stable UUID, notebook relationship, entry metadata |
| JournalPage | Stable UUID, entry relationship, explicit page order and image identity/version, raw OCR and OCR-result identity |
| PageImage | Stable UUID, page relationship, preserved source Binary Data with Allows External Storage |
| TranscriptRevision | Stable UUID, page relationship, full saved correction, revision lineage; append-only |

Keep page metadata separate from large photo bytes. Preserve imported source bytes and scanner-produced images; derivatives must not replace the source. Let Core Data manage external binary files.

Preserve raw OCR independently from append-only corrections. Canonical text uses the selected saved revision when one exists, including an intentionally empty string; only absence of a correction falls back to OCR. OCR retries must not overwrite user corrections.

Design the later model for future CloudKit compatibility: optional inverse relationships, unordered to-many relationships with explicit position, suitable optional attributes/defaults, and no unique constraints. Assign UUIDs per record, never a shared static UUID default.

## Concurrency and recovery
Use async work, bounded image/OCR processing, and context.perform boundaries. Never send managed objects across executors; pass stable identifiers or immutable Sendable values and refetch in the destination context. Keep persistence out of SwiftUI bodies.

Save images durably before reporting success or scheduling OCR. Preserve photos on OCR failure. Never resolve a store-load or migration failure by silently deleting data; present recoverable errors and preserve the store.

Index canonical saved text with stable notebook, entry, and page UUIDs so results open the exact matching page. Use bound SQL and safe FTS query construction. Rebuild/reconcile the derived index from authoritative records after interruption or corruption; index failure must not destroy journals.

## Deferred capabilities
Explicit Sign in with Apple and private iCloud sync require a later documented capability phase and actual provisioning. Authentication and iCloud availability are separate states. Never invent team/container IDs. AI remains unimplemented. The free app must not upload content or log sensitive payloads.
