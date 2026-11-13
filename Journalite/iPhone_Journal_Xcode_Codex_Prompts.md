# iPhone journal digitizer: research, architecture, and Xcode Codex prompts

Prepared for Justin Chick • Research checked November 12, 2026

Build a native iPhone app that preserves photographs of handwritten journal pages, transcribes them on the device, organizes entries into notebooks, and searches the transcriptions. Keep the original writing and the user's corrections available for future AI features.

This is a development brief and a sequence of implementation prompts. It does not modify your uploaded Swift files or claim that an app has already been built.

## 1. The recommendation and the actual cost

Use **Swift + SwiftUI + Core Data**, **VisionKit** for scanning, **Vision** for on-device OCR, and later **CloudKit's private database** for iCloud sync. Use the current stable Xcode installed on your Mac, with an **iOS 17 deployment target** as a deliberate compatibility baseline. Newer APIs must have availability checks and useful fallbacks.

There are two development modes:

| Capability | Free local development | With Apple Developer Program access |
| --- | --- | --- |
| Build in Xcode and test in Simulator | Yes | Yes |
| Install on your personal iPhone through Xcode | Yes; free provisioning expires after 7 days | Yes |
| Scan journal pages and import photos | Yes | Yes |
| On-device transcription, notebooks, and search | Yes | Yes |
| Optional Face ID/device-passcode app lock | Yes | Yes |
| Export and restore your archive through Files | Yes | Yes |
| Real Sign in with Apple capability | Defer | Enable after provisioning |
| Automatic CloudKit sync | Defer | Enable after provisioning |
| TestFlight/App Store distribution | No | Available through the program |

The Apple Developer Program currently costs **US$99 per year**. A student using a personal account does not automatically receive free membership. Xcode and Apple's local frameworks do not require a paid OCR service. Existing coding-agent subscriptions or usage limits are separate from this app's operating costs. [1–4]

**You cannot satisfy “strictly $0” and “real Apple sign-in plus automatic CloudKit sync” simultaneously with a free Personal Team.** Start with the complete local app. Keep cloud-related capabilities out of its signing configuration until you have eligible program access.

CloudKit private data counts against **each user's own iCloud storage**, rather than pooling every customer's journal into one public database. Apple provides 5 GB free across iCloud services; that space is also used by the person's other iCloud data. More storage can cost the user money. This architecture avoids a separately hosted journal database for the initial iPhone product; it does not mean unlimited free storage. [5–6]

A free interim option is exporting an archive through the Files picker to a location the user chooses, including iCloud Drive if available. That is a user-driven backup/export, not automatic database synchronization.

### Apple sign-in and iCloud are distinct features

Sign in with Apple authenticates the person to your app. CloudKit separately checks the device's iCloud account and service availability. Successful sign-in does not prove that sync is available or that storage has space. CloudKit can work without a separate app login screen. For your requested explicit login experience, add the real Apple button in the optional account phase; never implement an Apple-password form. [5, 7]

## 2. Research translated into a usable interface

These are proposed design decisions informed by the products' documented workflows. They are not claims from a usability study of your app.

| Reference | Relevant documented behavior | Recommendation for your app |
| --- | --- | --- |
| Apple Notes | Scans pages with the camera and lets users adjust the scan. | Use the familiar system document scanner. Ask for camera permission when Scan is tapped. |
| Day One | Supports multiple journals, journal-scoped search, document scanning, and conversion of handwriting into editable text. Its Scan Text and Scan to PDF workflows preserve different outputs. | Save the page image and transcription together in one capture flow. Avoid making users choose between preserving the page and searching its words. |
| Goodnotes | Uses named folders with colors/icons and provides search across a library or within a document, opening the matching location. | Make notebooks visually distinct and let search results open the exact page that matched. |

Sources: Apple Notes [8], Day One scanning and search [9–10], Goodnotes organization and search [11–12].

### Navigation and main screens

Use three native tabs: **Notebooks**, **Search**, and **Settings**.

- **Notebooks:** a compact grid or list of named notebooks, a recent-entries section, and a labeled Scan action. Offer Bible Notes, Personal Motivation, and Letters to My Family as optional starter names. Do not populate the real library with fabricated entries.
- **Notebook:** entries sorted by journal date, each showing its title, date, small page thumbnail, page count, and a short text preview when available.
- **Entry:** clear Photo and Text modes, page navigation, and a Compare option. On an iPhone, Compare should put the image above editable text; two narrow columns would make handwriting difficult to read.
- **Search:** search all notebooks by default, with an obvious notebook filter. Include date, favorite, and review-state filters. Show a matching excerpt, notebook name, date, and page number.
- **Settings:** local storage/sync state, app lock, export/import, Recently Deleted, and later Apple account controls.

Use a restrained paper-and-ink visual style, native text fields and navigation, SF Symbols, Dark Mode, Dynamic Type, and VoiceOver. Color should reinforce labels, not replace them. Scanning should be reachable from both the notebook library and an open notebook.

### The capture flow

1. Tap Scan or Import Photos.
2. Scan several pages or select images.
3. Confirm the destination notebook, entry title, journal date, and page order.
4. Save the images durably.
5. Begin OCR without blocking access to the saved entry.
6. Offer Review Text with the image available for comparison.

Default multiple pages to **one entry**. Offer an explicit “Separate entry for each photo” import option for a stack of unrelated pages. Remember the last destination notebook. Keep journal date separate from capture date so you can digitize older notebooks correctly.

Use plain statuses: **Waiting to transcribe**, **Transcribing**, **Needs review**, **Reviewed**, and **Couldn't transcribe**. OCR failure must never mean the photo disappears. Let users save a page with no recognized text and type a transcription themselves.

For your Bible notes, preserve verse numbers, references, names, and paragraph breaks. A search for “1 Corinthians” should find the user's saved text; the app should not silently rewrite “1 Cor.” into a different quotation.

### What the first version should omit

Defer AI interpretation, chat, family sharing, public profiles, subscriptions, streaks, and elaborate nested folders. A notebook called Letters to My Family remains private; its name is not permission to share it.

## 3. The architecture to give Codex

### Native stack

| Responsibility | Choice |
| --- | --- |
| App interface | SwiftUI; UIKit bridges only for system features |
| Local authoritative records | Core Data with a SQLite persistent store |
| Future sync integration | NSPersistentCloudKitContainer, disabled in the free configuration |
| Document scanning | VNDocumentCameraViewController |
| Importing selected photos | PhotosPicker |
| OCR | VNRecognizeTextRequest using accurate recognition |
| Image decoding/thumbnails | ImageIO and a bounded cache |
| Internal text search | A separate, rebuildable SQLite FTS5 index |
| Optional local app lock | LocalAuthentication |
| Optional explicit Apple login | AuthenticationServices and Keychain |
| Exports | Codable manifest plus image files through Files; PDFKit/UIKit for a readable PDF |
| Future AI | A provider interface, without a live provider in version one |

Core Data is a deliberate choice here because the app has large photo attachments, a local database, and a later cloud-sync phase. Keep persistence access behind small services so a future change does not require rewriting the interface. This is not a requirement that every SwiftUI app use Core Data.

Apple's document scanner returns page images, PhotosPicker limits access to the images the person selects, and Vision processes text recognition on the device. Handwriting accuracy remains something to measure on your own pages, especially cursive and low-light photos. [13–15]

### Records and ownership

Use these five main entity types. The implementation agent should choose suitable Core Data field types, optional values/defaults, and lightweight migrations.

| Entity | Main fields and role |
| --- | --- |
| Notebook | Stable UUID, name, color token, symbol name, createdAt, updatedAt, deletedAt; owns entries |
| JournalEntry | Stable UUID, title, journalDate, createdAt, updatedAt, favorite, deletedAt; belongs to a notebook and owns pages |
| JournalPage | Stable UUID, order position, createdAt, updatedAt, source kind, source-image hash, image version, deletedAt, raw OCR text and result UUID, OCR engine/revision/language/date, selected manual revision UUID, reviewed revision identity; belongs to an entry |
| PageImage | Stable UUID, page relationship, immutable source bytes, content type, pixel dimensions, byte count; separate from page metadata |
| TranscriptRevision | Stable UUID, page relationship, full user-saved text, createdAt, base-revision UUID, source-image version; append-only correction history |

A page with no selected manual revision displays its OCR text. Assign a new OCR-result UUID to each completed recognition so review state can refer to that exact result. Once the user saves a correction, the chosen manual revision becomes the canonical text. An intentionally empty correction is a real value, not a signal to revert to OCR. Revision history prevents a retry or later device edit from silently destroying the user's wording. Do not treat wall-clock timestamps as a complete multi-device conflict-resolution system.

Keep thumbnails, the search index, OCR task execution state, and account/session state **local**. Persist the OCR work queue separately with page UUIDs and image-version identifiers so interrupted work can resume. A “running” job is not shared notebook content.

Create the local model with future CloudKit restrictions in mind: optional relationships with inverses, no ordered relationships, application-assigned UUIDs, and no Core Data unique constraints. Use application validation and duplicate reconciliation. Relationships may arrive at different times during sync; missing related objects must not crash the interface. [16]

### Photos and storage

- Preserve the imported image bytes supplied to the app. A scanner's output is already a processed scan; label it honestly.
- Store image bytes in a dedicated PageImage entity with Binary Data/Allows External Storage. Core Data owns any external backing files; do not manipulate their private paths.
- Generate separate downsampled display/OCR images and small thumbnails. Never replace the preserved source with the OCR derivative.
- Avoid base64 images in database strings or one JSON array containing an entire notebook.
- Fetch entry/page metadata for lists. Load source-image data only when it is needed.
- Process images sequentially or with tightly bounded concurrency.

Apple's Core Data/CloudKit bridge can represent large binary values as CloudKit assets. External binary storage in the local database and a CloudKit asset are separate implementation mechanisms; they are not a free “cloud only” photo cache. [17]

### Search that can grow

Core Data remains the source of truth. Use a separate app-owned SQLite FTS5 index for canonical saved text, entry title, and notebook name. Associate each indexed result with stable page, entry, and notebook IDs.

Never open or modify Core Data's SQLite tables with raw SQL. The search database is a different file. Use bound SQL parameters and a safe query builder; SQL binding alone does not neutralize FTS query syntax.

Update the index when content changes and reconcile it from persistent history, including later remote imports. A broken index must be rebuildable from the authoritative records. Keep journal contents out of system Spotlight by default. FTS provides keyword search; semantic search and arbitrary substring matching are separate features. [18–19]

### What “scalable” means here

This is a reasonable design for growing personal archives and many independent iCloud users, subject to testing and service limits. It does not establish a measured capacity.

- Use paged metadata fetches, image faults, bounded caches, and incremental indexing.
- Set an initial test target of 10,000 text entries plus a smaller realistic full-image archive. This is a benchmark target, not a supported-capacity promise.
- Measure OCR on 20–30 of your real journal pages before deciding whether Apple Vision is sufficient.
- CloudKit sync is eventually delivered, not immediate. Local saving must remain useful when offline. [20]
- The initial mirrored store retains a local replica, including attachments. Huge libraries can consume substantial iPhone storage. Download-on-demand media would require a later media/sync design.
- Illustrative storage math: 1,000 pages averaging 2 MB each is about 2 GB before other overhead. This is an assumption, not a measured scan size.
- Use independent exports for recovery. A synchronized deletion can propagate to other devices; sync is not a historical backup.
- iPhone-first CloudKit does not automatically give you a web or Android app. Reassess the backend if those become firm requirements.

### Later AI, without prematurely building it

Preserve page IDs, original OCR, user corrections, revision lineage, notebook scope, and source-image versions. That gives a future insight feature evidence to cite.

Possible later features: find recurring topics, summarize a selected notebook/date range, suggest titles/tags, and link related entries. All insights should cite the source entries and stay separate from the actual journal text.

Apple's on-device Foundation Models framework is a candidate for a later phase, with runtime availability checks for eligible devices, languages, and settings. It is not needed for OCR or ordinary search. Do not make the base app depend on Apple Intelligence, and do not assume future AI will be free on every iPhone. [21]

## 4. How to run the prompts

1. Open your existing iOS app project in Xcode.
2. Keep a Git checkpoint before each phase.
3. Paste **Prompt 0 once**, then paste **Prompts 1–8 one at a time**, in order.
4. Build after each phase and follow its short device check. If it fails, use the repair prompt below before moving on.
5. Use **Prompts 9–10 only when the required Apple capabilities are available**.
6. Run **Prompt 11** at the end in either mode.

You do not have to enable iCloud or Apple sign-in to complete the free phases. If you already have a paid membership, the same ordering gives you a working local foundation before account and sync changes.

Your supplied starter is minimal: MyApp.swift contains the SwiftUI app entry point; ContentView.swift contains Hello World plus a Playgrounds import/block. The two Contents JSON files look like asset-catalog metadata, but their parent asset paths are absent. The Xcode agent must inspect the actual project structure and must not guess their destinations or replace the asset catalog.

All prompts below are intended for the coding agent **inside your real Xcode project**, where it can inspect target settings, SDK availability, project membership, and build errors. No project file was supplied here, so exact signing settings and your installed toolchain still need to be checked there.

## Prompt 0 — Establish project context and working rules

~~~text
You are working in my existing Xcode project. We are building a native iPhone app that digitizes private handwritten journals.

First read existing repository instructions and inspect the project, targets, app entry point, Swift files, asset catalog, installed stable toolchain, deployment target, and signing configuration where visible. Do not replace the project or create a second @main app.

My initial files may be MyApp.swift and ContentView.swift. ContentView may contain import Playgrounds and a #Playground block. Remove app-irrelevant playground scaffolding if appropriate. Preserve the SwiftUI preview. Preserve the existing bundle ID and signing team unless a later phase requires a documented capability change. Never invent my team or container ID.

Create or update Docs/ProductBrief.md, Docs/Architecture.md, Docs/XcodeSetup.md, and Docs/BuildProgress.md. Carry this agreement forward in those files so later prompts remain grounded in the actual code:

PRODUCT:
- Photograph/scan or import private handwritten journal pages.
- Preserve the source image and produce on-device OCR.
- Multiple named notebooks, including optional starter names Bible Notes, Personal Motivation, and Letters to My Family.
- Search saved transcriptions; open the exact matching page.
- Let me edit OCR while comparing it with the photo.
- Later explicit Sign in with Apple and private iCloud sync.
- Later AI insights; do not implement AI in these phases.

TECHNOLOGY:
- Native Swift/SwiftUI, iPhone-first, iOS 17 minimum unless the existing project requires a justified adjustment.
- Use supported APIs in the installed stable SDK. Guard newer APIs.
- Core Data SQLite as the authoritative local store; NSPersistentCloudKitContainer may be used with cloud options disabled.
- VisionKit document scanner, PhotosPicker, Vision OCR.
- Separate PageImage binary data with Allows External Storage.
- Separate rebuildable app-owned SQLite FTS5 search index.
- No paid OCR API, third-party analytics, server, or external package for the base app.
- Use async work with safe Core Data context boundaries; never send managed objects between executors.
- Free local configuration must not include iCloud, push, or Sign in with Apple entitlements.
- Do not fake sign-in, cloud upload, OCR, successful saves, or test results.

DATA RULES:
- Stable UUIDs for Notebook, JournalEntry, JournalPage, PageImage, and TranscriptRevision.
- Page metadata is separate from large photo bytes.
- Preserve raw OCR independently from append-only user corrections.
- A saved empty correction must remain empty.
- Do not upload journal content anywhere in the free configuration.
- Do not log journal text, photographs, tokens, or other sensitive payloads.
- Never fix a migration or store-load failure by silently deleting data.

FOR EACH LATER PHASE:
Read these docs and the current code; implement that phase; build with the available Xcode tools; run relevant checks; update BuildProgress with what actually passed and what needs a real iPhone.
Report changed files, actual build/test results, exact manual Xcode steps if needed, and at most five practical verification steps.
Do not stop after a plan when implementation is requested. Stop at the current phase boundary, not halfway through its work.

For this setup phase, write the docs, clean app-irrelevant starter scaffolding, and verify the starter still builds. Do not implement later feature phases yet.
~~~

## Prompt 1 — Create durable local storage and the native app shell

~~~text
Read Docs/ProductBrief.md, Architecture.md, XcodeSetup.md, BuildProgress.md, and current project instructions. Implement the local persistence foundation and native navigation shell.

Use a versioned .xcdatamodeld and a single authoritative SQLite store. Define:
- Notebook: UUID, name, colorToken, symbolName, createdAt, updatedAt, deletedAt; entries relationship.
- JournalEntry: UUID, title, journalDate, createdAt, updatedAt, isFavorite, deletedAt; notebook and pages.
- JournalPage: UUID, position, timestamps, sourceKind, imageVersion UUID, sourceHash, deletedAt, optional rawOCRText and ocrResultID UUID, optional OCR engine/revision/language/date, optional selectedTranscriptRevisionID, optional reviewedRevisionID; entry, image, transcriptRevisions.
- PageImage: UUID, immutable sourceData binary with Allows External Storage, contentType, pixelWidth, pixelHeight, byteCount; page.
- TranscriptRevision: UUID, text, createdAt, optional baseRevisionID, imageVersion; page.

Configure for future CloudKit compatibility now: optional relationships with inverses, unordered to-many relationships plus explicit page position, no unique constraints, and compatible optional attributes or defaults. Generate UUIDs in application code, not as one static model default.

Use a PersistenceController and small repository/services. Return immutable summaries or identifiers across concurrency boundaries. Keep persistence code out of SwiftUI bodies. Enable persistent history for later derived-index reconciliation.

Keep cloudKitContainerOptions nil and use no cloud entitlements. Do not initialize CloudKit services in this configuration. Use the same intended store location for the later supported cloud upgrade.

Implement Notebooks, Search, and Settings tabs using NavigationStack. Notebooks should have a real empty state. Settings must accurately say the journal is stored on this iPhone. Use a basic restrained native visual style. Do not fill the live store with fake data.

Provide a separate in-memory preview/test store. Expose a recoverable store-load error screen with retry/export guidance rather than fatalError or automatic data deletion.

Validate saving and reopening records in a temporary on-disk SQLite store, correct relationship setup, deterministic page ordering, and an intentionally empty transcript revision. Use a SQLite test store where in-memory behavior would conceal persistence problems. Build the actual app target and update the docs.
~~~

## Prompt 2 — Build notebooks and entry browsing

~~~text
Read the project docs and implement the real notebook/library experience on the persistence foundation.

Build:
1. First-run screen explaining that the app preserves journal photos and makes their words searchable. Free mode offers Start on this iPhone. No camera or photo-library permission request on launch.
2. Optional starter-notebook suggestions: Bible Notes, Personal Motivation, Letters to My Family. Create them only when chosen.
3. Create, rename, recolor, and change the symbol of a notebook, with trimmed-name validation.
4. Notebook list/grid, recent entries, and notebook detail with paged entry summaries sorted by journalDate with a stable tie-break.
5. Entry detail navigation supporting a stable entry ID and optional target page ID.
6. Entry metadata editing: title, journal date, favorite, and moving an entry to another notebook.
7. Recently Deleted semantics. Soft-delete entries; hide them from ordinary lists. For a notebook containing entries, offer a clear move-to-another-notebook path or move the notebook and its contents to Recently Deleted. Never silently discard entries.
8. Restore and explicitly confirmed permanent deletion. Automatic expiry is deferred; show that items remain until permanently deleted.

Show distinct empty states for no notebooks and a notebook with no entries. Use Dynamic Type, VoiceOver names, Dark Mode, and native navigation. Notebook colors must have accompanying names/icons.

Do not decode source-image blobs when fetching rows. Use summary values and cached thumbnail identifiers; photos will be integrated in the next phase. If a future relationship is temporarily missing, show a recoverable state.

Verify notebook operations survive relaunch; moves preserve stable entry/page IDs; trashed contents are hidden; restore returns them to an appropriate live notebook. Add focused tests for these data-affecting behaviors. Build and document the outcome.
~~~

## Prompt 3 — Scan pages and import photos without losing the originals

~~~text
Read the project docs. Implement working capture and photo import.

Use VNDocumentCameraViewController via UIViewControllerRepresentable, including success, cancel, and failure delegates and isSupported checks. Use PhotosPicker for selected images, not unrestricted photo-library access. Check actual selected-item loading APIs against this SDK.

Add labeled Scan and Import Photos actions to the library and notebook screens. On unsupported hardware or Simulator, make photo import available. Add a clear NSCameraUsageDescription and ask for camera access only when required. Permission denial should explain how to use import or change Settings.

Implement a capture review sheet:
- Choose notebook; default to the notebook I am viewing or the last used live notebook.
- Create a notebook inline.
- Set title and journal date separately from capture time.
- Review image thumbnails; remove or reorder pages.
- Default to one multipage entry.
- For photo imports, optionally create one entry per selected photo; explain this choice.

Preserve the supplied imported source bytes. The document scanner returns processed page images; store a high-quality rendering of those results and label their source accordingly. Do not claim to preserve an unavailable pre-scan camera original.

Use a bounded, sequential ingestion pipeline. Stage files with a durable local ingestion receipt containing the assigned record IDs; write entry/page/image records; confirm durable saves before deleting staged input. Do not keep an entire large import as decoded full-size UIImages or base64 strings. Set documented per-image/import limits based on actual memory behavior, with helpful errors and no silent rejection.

Create downsampled display/OCR derivatives and local thumbnail caches with ImageIO. Keep sourceData immutable and separate. Hash source bytes using CryptoKit for exact-duplicate detection; warn rather than discarding a deliberate duplicate. Strip location metadata from derived thumbnails and ordinary share exports. Preserved source bytes remain unmodified; document that originals can contain metadata.

Connect entry detail to a real paged image viewer with zoom and page count. OCR can show Waiting to transcribe until the next phase. Do not fabricate text.

Verify multipage import order, cancel without empty records, partial-load errors, a denied-camera path, reopening images after relaunch, and original-byte integrity for photo imports. Use a real iPhone for the document scanner check and report when it has not been run.
~~~

## Prompt 4 — Add resilient on-device handwriting OCR

~~~text
Read the docs and implement OCRService using Apple's Vision text recognition. No remote API, model download requirement, API key, or generative rewriting.

Use VNRecognizeTextRequest with accurate recognition and supported-language checks. Start with English and allow a supported recognition-language setting. Preserve image orientation and page order. Generate a suitably detailed OCR input from the saved image; make its size limit a documented tuning setting.

Recognize normal line-based journal pages in reading order using observation geometry. Preserve line breaks reasonably. Save the raw recognized text, a new OCR-result UUID, engine/revision, recognition language, timestamp, and source-image version separately from manual TranscriptRevision records. Do not claim support for arbitrary multi-column layouts or perfect cursive recognition.

Keep low-confidence observations available for review indicators if useful; never turn Vision confidence into an advertised accuracy percentage. A small optional custom-word list may help names/Bible references, but do not silently expand, summarize, or rewrite Scripture.

Create a durable local OCR queue containing page IDs and image versions. It is local execution state, not shared content. Run at most one page at a time initially, outside the main actor, using correctly isolated Core Data work. Resume unfinished local jobs on relaunch. Handle interruption, cancellation, recoverable error, and retry without busy looping.

Persist images before enqueueing. If the app terminates between those steps, reconcile its durable local ingestion receipts with saved pages and missing jobs on restart; do not infer local ownership just from a missing OCR result. Do not automatically enqueue every remotely received page when sync is added later.

Expose Waiting to transcribe, Transcribing, Needs review, and Couldn't transcribe. Save an empty recognized result honestly; preserve the image and offer manual typing. A retry must never overwrite a user correction. Ignore a completed job whose image version is no longer current.

Do not promise continuous background OCR when iOS suspends the app. Save progress, pause safely, and resume when active.

Validate queue recovery, no-text recognition, cancelled/deleted jobs, stale image versions, retry behavior, and preservation of manual revisions. Use mock recognizer results for deterministic tests and a separate real Vision check on representative pages. Record what is real-device evidence versus a mocked test.
~~~

## Prompt 5 — Make transcription review and correction comfortable on iPhone

~~~text
Read the docs and implement the complete entry reading/editing experience.

Provide Photo and Text views plus a Compare mode. On iPhone, Compare puts a zoomable page above a usable text editor; it must work with the keyboard and larger Dynamic Type. Keep visible page navigation and a clear indication of which page is being edited.

Implement:
- View the preserved page image and canonical text.
- Edit transcription with an explicit Save action and dirty-state protection.
- Append a TranscriptRevision on a deliberate save, with stable ID, image version, and base revision.
- Preserve raw OCR independently.
- Persist the selected manual revision UUID and display that revision when available; otherwise use OCR. If sync has not delivered a selected revision yet, preserve the pointer and show a loading/recovery state rather than silently changing the selection.
- Treat an intentionally blank manual revision as valid content.
- Mark the specific current text revision as reviewed; changes or a new OCR result must update review state appropriately.
- View previous manual revisions and restore one by creating a new revision, not deleting history.
- Retry OCR with an explanation that corrections are retained.
- Copy plain text using a clear user action.
- Add pages to an existing entry, reorder pages, and remove pages through the same recovery rules.

Handle changes while the editor is open: if the underlying revision changes, preserve the draft and offer an explicit review/merge choice instead of replacing what the user is typing. Keep revision selection logic deterministic and separate from view code.

Use ordinary text editing; do not “improve” the user's words with AI. Keep names, verse references, and personal spelling choices.

Verify corrections survive relaunch and OCR retries, blank edits stay blank, changing pages does not lose a draft, and restoring a revision preserves history. Add targeted tests for canonical-text selection and draft-conflict behavior. Build and update the docs.
~~~

## Prompt 6 — Build fast, private, page-specific search

~~~text
Read the docs and implement SearchService using a separate SQLite FTS5 database through the platform SQLite library. It must not be the Core Data store file.

Core Data is authoritative. The FTS database is a derived local index that can be deleted and rebuilt without losing a journal.

Index canonical user-visible text, entry title, and notebook name. Store stable page/entry/notebook IDs as result metadata. Exclude trashed content and superseded manual text from normal search results. For entries without recognized text, titles must still be searchable.

Use parameterized SQL plus a safe FTS query builder. Define normal search as case-insensitive token/word-prefix search with sensible handling of phrases and punctuation. Bound parameters alone do not make MATCH syntax safe. Do not promise arbitrary substring, fuzzy handwriting, or semantic search.

Add:
- Debounced asynchronous search with cancellation of stale requests.
- All Notebooks as the default scope.
- Notebook, journal-date, favorite, and review-state filters.
- A short matching excerpt with accessible emphasis, notebook name, date, page number, and thumbnail.
- Opening a result navigates to its exact page and shows the relevant text.
- Helpful empty/query-no-match/index-building/error states.

Handle edits, entry moves, notebook renames, trash/restore, and permanent deletion. Consume persistent history serially and persist a history token only after the corresponding index transaction commits. Make replay idempotent; detect token/store mismatches and rebuild. Store stable IDs needed to clean up deleted index rows. Reconcile after local background saves and future remote imports.

Keep the index and its sidecars protected and excluded from backup where appropriate. Add a Settings Rebuild Search Index action. Do not expose journal text through system Spotlight or app logs.

If FTS5 is unavailable in the actual environment, use a documented bounded Core Data fallback and report the limitation; do not claim the scalable index exists.

Test corrected-versus-raw search, blank corrections, punctuation, title-only entries, rename/move, trash/restore, rebuild, crash-safe history replay, and exact-page navigation. Use an isolated synthetic corpus for performance checks.
~~~

## Prompt 7 — Add app lock, recovery, and portable backups

~~~text
Read the docs and implement local privacy and reliable export/import.

APP LOCK:
Use LocalAuthentication with an optional device-owner authentication lock and passcode fallback where available. Configure NSFaceIDUsageDescription if needed. Lock on the chosen background timeout. Obscure journal content in the app-switcher snapshot. Do not claim screenshots can be universally prevented.

Use appropriate iOS file protection for the authoritative SQLite store, sidecars, external binary data, OCR queue, thumbnails, and search index. Verify the effect on supported background sync rather than choosing incompatible settings blindly. Handle protected-data-unavailable errors as a waiting state. Face ID is an app access control, not the same as database encryption or an Apple Account login.

BACKUP:
Implement Export Archive for all notebooks or a selected notebook. Use a versioned package containing a manifest, preserved source image files, metadata, raw OCR, manual revision history, and checksums. Do not export base64 images in one giant JSON string.
Use native document/file export APIs; if choosing a directory package, define its type so it can be selected again for restore. Do not add a paid dependency.

Implement Import Archive with a preflight summary, schema/version/size validation, checksum validation, safe relative paths, and staged writes. Reject path traversal, missing required files, malformed data, and decompression bombs if compression is used.
Preserve stable UUIDs. Import is merge-only: skip identical records; surface conflicting records without overwriting existing journal content. Import must never erase the current library.

Provide readable entry export as ordered photo pages plus transcription in PDF, and plain text. Label whether the PDF has a searchable text layer or separate transcription pages; do not promise invisible OCR overlays unless implemented.

Explain before exporting that files leave the app's protection and may contain private writing and original-photo metadata. Default ordinary share exports to derived images without location metadata; a full archive preserves originals and is clearly labeled.

RECOVERY:
Complete Recently Deleted/restore/permanent deletion for notebooks, entries, and pages. Explicitly confirmed permanent deletion removes source records, image payloads, revision records, jobs, caches, and search entries. Do not promise forensic erasure from OS/cloud backups.

Test a full export/import round trip in an isolated library, all image checksums, entry/page order, revision history, repeated import, a conflicting UUID, malformed package, and partial failure. Never validate by deleting my real data. Build and report any device checks still needed.
~~~

## Prompt 8 — Verify the free app and make archive growth practical

~~~text
Read the docs. Finish and validate the complete free local version before enabling paid capabilities.

Walk through: first launch -> create notebook -> scan/import -> durable image save -> OCR -> compare/correct -> search -> exact page -> move/favorite -> trash/restore -> export/import. Fix incomplete interactions and misleading labels. Every visible action in this version must work or clearly explain a real device limitation.

Audit:
- No cloud, push, or Sign in with Apple entitlement in the free signing configuration.
- No hidden remote requests for journal content, no paid SDKs, and no fake success states.
- No image decoding, full OCR, unbounded database fetch, or whole-index rebuild in a SwiftUI body or on the main actor.
- Bounded entry fetches and deterministic pagination.
- Thumbnails instead of originals in scrolling lists.
- Bounded image and OCR memory; temporary files are cleaned up safely.
- Index/thumbnail failures cannot delete source material.
- Versioned schema and an actual additive-migration check using a previous test-store version when available.
- Accessible navigation at large text sizes, Dark Mode, and VoiceOver.

Add a debug-only isolated synthetic data generator, never automatically inserted into my real store. Use 10,000 text entries for search/list checks and a smaller image-heavy archive for memory/import checks. Measure on a named Simulator/device and record dataset size, observed timing, and peak memory where tools allow. Treat performance thresholds as goals, not fabricated results.

Create Docs/ManualDeviceChecks.md with a short checklist covering real document scanning, camera denial, app lock, termination during import/OCR, no-text pages, low-storage handling, and representative handwriting.

Create an OCR evaluation worksheet for 20-30 real pages I can supply locally. Compare transcription against manually verified text; include cursive, names, verse references, low light, and rotated photos. Do not invent accuracy measurements.

Run relevant tests and the app build, fix failures, and record remaining limitations in BuildProgress. Finish with a plain description of what the free app can now do.
~~~

## Prompt 9 — Optional: turn on private iCloud sync

Only run this phase with eligible Apple Developer Program access. This adds automatic synchronization, not just a Files export.

~~~text
Read all project docs and the existing local implementation. Implement private CloudKit synchronization without replacing the working local architecture.

Check the actual signing team and capabilities. If the project is using an ineligible Personal Team, keep the free target buildable, finish the configuration documentation, and report the precise capability block. Do not pretend cloud sync works or add unsupported entitlements.

With eligible provisioning, configure the real bundle/container IDs, iCloud/CloudKit, required push support, and Background Modes > Remote notifications. Use a separate documented free configuration/scheme with no restricted entitlements. Do not invent or hardcode a team ID.

Enable NSPersistentCloudKitContainer options for the intended private database. Keep the authoritative model/store identities and source records. Prepare and test the local-only to mirrored-store transition using a disposable copy and an export before touching valuable data. Never copy only a SQLite main file while ignoring WAL/external files. Never silently reset a journal store.

Handle local-to-cloud enablement explicitly: tell the user that their existing local journal will upload to the active iCloud account. Do not upload valuable local journals to an account just because a device setting changed.

Keep Core Data as the only writer of its mirrored records; do not implement a second direct-CloudKit writer for those same records. Keep the FTS index, thumbnail cache, and OCR execution jobs local. Do not sync file paths or processing flags that belong to a specific device.

Observe actual container sync events/account state. Show truthful states such as Saved on this iPhone, Syncing, Last sync activity, iCloud unavailable, or Needs attention. Local save success is not proof that every page reached the cloud. Do not add an unsupported “force sync completed” button or guarantee immediate delivery.

Handle offline use, quota errors, restricted/not-signed-in accounts, delayed relationships, duplicate logical UUIDs, and retryable errors. Feed remote imports into view updates and search-index reconciliation. Avoid purging persistent history until all consumers that need it are accounted for.

Use append-only transcript revisions to preserve concurrent edits. Detect competing revision branches and offer review; a merge policy alone is not lossless text conflict resolution.

Observe iCloud account changes. Scope local stores, caches, history tokens, and pending jobs to the verified storage account. Prevent the old account's cached journal from appearing in or uploading to a new account. Preserve an isolated archive/recovery path rather than silently destroying unsynced work. Test account removal/switch explicitly.

Document that the mirrored store retains a local replica and sync is not an independent backup. Schema initialization is development-only; document separate production schema deployment before TestFlight. Keep migrations additive after production deployment.

Test with two devices/simulators on the same iCloud account: existing local import, edits on both, offline edits, competing corrections, deletes/restores, relaunch, and search after remote import. Record quota/account-change tests as simulated or real. Do not mark sync verified without observed cross-device evidence.
~~~

## Prompt 10 — Optional: add the explicit Sign in with Apple experience

The app can use private CloudKit without a separate app login. This phase adds the login screen you requested. Account lifecycle and deletion must be treated as real features, not a decorative sign-in button.

~~~text
Read the docs and current cloud/account implementation. Add native Sign in with Apple in the eligible configuration; preserve the working free local configuration.

Use AuthenticationServices and Apple's native SignInWithAppleButton. Request only the identity data the app actually needs. A display name can be optional; do not require email for this journal's storage identity.

Handle successful authorization, cancellation, errors, existing credentials, revoked credentials, and credential-state checks. Store the stable Apple user identifier and necessary minimal session data in Keychain. Names/emails may not be returned on repeat authorization; the interface must still work. Do not log tokens, persist secrets in UserDefaults, or display my Apple password in a custom form. Distinguish revoked/not-found credentials from a transient credential-check network error; do not erase a valid local session just because the check failed to reach Apple.

In the account-enabled onboarding, Continue with Apple is the primary action before the notebook library. If local-only use is offered, label it explicitly and keep it separate from the signed-in experience. Free builds must not display a fake working Apple login.

Keep app authentication and CloudKit authorization as separate state machines. A successful Apple sign-in does not mean iCloud sync is usable. Validate cloud availability and keep account/store isolation from the sync phase. Do not assume the Sign in with Apple subject equals a CloudKit record identifier. Sign-out must return to an appropriate locked/onboarding state; it must not delete cloud data or silently relabel private cloud contents as an anonymous library.

Implement clear Account settings and explain sign-out versus data deletion. Provide an in-app initiated delete-data/account flow with reauthentication where appropriate, export first as an option, a clear explanation of local versus synced deletion, and truthful pending/failure states. Coordinate data deletion with the mirroring system so an offline device cannot simply re-upload a supposedly deleted account.

Consult current Apple account-deletion guidance and TN3194. Clearing a Keychain value is not token revocation. Do not embed an Apple private key/client secret in the app. The documented manual-revocation fallback is a fallback, not a claim that a new fully managed account system has automatic revocation. If proper new-account lifecycle support requires a secure token service, document the minimal service contract and keep this mode explicitly at prototype status until it is implemented and verified. Do not introduce a paid service or silently deploy a backend.

If a server is later authorized, it must verify Apple credentials on the server, protect signing secrets there, and handle revocation; a client-side decoded JWT is not trusted server authentication.

Verify repeat login without name/email, cancellation, sign-out, credential revocation, offline restoration of an authorized local session, cloud-unavailable after login, account changes, and deletion states. Report exactly which lifecycle operations are implemented and which block public release. Update XcodeSetup and BuildProgress with actual capability requirements.
~~~

## Prompt 11 — Final audit and a clean foundation for later AI

~~~text
Read all project docs and review the actual app as a new maintainer.

Complete a final audit in whichever modes are implemented:
- Free local mode compiles without restricted entitlements.
- Every photo/scan is recoverable after relaunch.
- Corrections and deliberate empty edits survive OCR retries.
- Notebooks isolate organization; private content is not shared by notebook name.
- Search uses the current canonical text and opens the exact page.
- Deletes, restore, export, import, and app lock behave as documented.
- Cloud/account mode, if present, reports actual state and has documented release blockers.
- No hidden API charges, remote journal uploads, secrets in the app, private-content logs, or invented validation results.
- Core Data and any search/file caches have consistent access and protection boundaries.

Fix concrete defects discovered during the audit. Run the relevant build/tests and summarize evidence without claiming device checks you could not perform.

Prepare only the interfaces and documentation for future AI:
- An immutable JournalEvidence type carrying notebook/entry/page IDs, canonical text, source revision, journal date, and review state.
- An InsightProvider protocol that accepts an explicitly selected scope and returns derived insights with source references.
- A disabled/unavailable provider; no generated insights, live network calls, or fake AI screen.
- A design note for possible on-device Foundation Models with runtime capability checks and for a separately consented remote provider.
- Store future insights separately and invalidate them when their source revision changes.
- Do not send journals to my local laptop model, a remote API, or any service automatically.

Write Docs/NextSteps.md describing:
1. Verified current functionality.
2. Real-device checks still pending.
3. Any OCR/search/storage limitations with evidence.
4. Optional cloud and account release prerequisites.
5. The next smallest AI experiment, using only selected reviewed text.

Keep this phase focused. Do not rewrite working modules, add subscriptions, publish the app, purchase services, or build the future AI feature.
~~~

## Repair prompt — Use whenever a phase fails to build

~~~text
Stay within the current phase. Read the exact current Xcode diagnostics and relevant source files, identify the root cause, and make the smallest complete correction. Preserve working features and user data.

Do not mask the error by disabling persistence, deleting the store, removing the failing feature, weakening actor safety, adding broad try? calls, or substituting fabricated results. Check target membership, deployment availability, imports, generated Core Data class duplication, actor isolation, and configuration only where relevant to the actual diagnostics.

Build again using the available Xcode tools. Report the exact result. If a real signing/capability issue requires a manual action, keep independent local code work complete and give the specific Xcode path and setting. Update Docs/BuildProgress.md, then stop so I can rerun the phase's verification.
~~~

## 5. Primary sources and what they support

These links are included so your Xcode agent can revisit the original documentation. Product documentation is used for interface research, not for copying proprietary designs.

1. [Apple developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account) — free device testing and 7-day provisioning.
2. [Apple Developer Program enrollment](https://developer.apple.com/help/account/membership/program-enrollment/) — annual fee, eligibility, and student guidance.
3. [Apple membership details](https://developer.apple.com/programs/whats-included) — program services including Sign in with Apple.
4. [Supported iOS capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios/) — provisioning/capability distinctions.
5. [CloudKit privateCloudDatabase](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase) — device iCloud requirement and user quota.
6. [Manage iCloud storage](https://support.apple.com/en-us/108922) — shared 5 GB free storage.
7. [Implementing Sign in with Apple](https://developer.apple.com/documentation/authenticationservices/implementing-user-authentication-with-sign-in-with-apple) — native authentication flow and setup.
8. [Apple Notes document scanning](https://support.apple.com/guide/iphone/scan-text-and-documents-iph653f28965/ios) — system scan interaction.
9. [Day One scanning and scanned text](https://dayoneapp.com/guides/tips-and-tutorials/attaching-pdfs-and-document-scanning/) — preserving page images versus editable text.
10. [Search in Day One](https://dayoneapp.com/guides/getting-started-with-day-one/search-in-day-one/) — global and journal-specific search.
11. [Goodnotes organization](https://support.goodnotes.com/hc/en-us/articles/15303674514191-Organize-folders-and-documents-in-Goodnotes) — named/color-coded folders, moves, and trash.
12. [Goodnotes search](https://support.goodnotes.com/hc/en-us/articles/7353743594127-How-to-Search-Your-Notes) — library/document search and opening matches.
13. [VisionKit document camera](https://developer.apple.com/documentation/visionkit/vndocumentcameraviewcontroller) — document page capture.
14. [PhotosUI](https://developer.apple.com/documentation/photosui) — selected-photo access.
15. [Recognizing text in images](https://developer.apple.com/documentation/vision/recognizing-text-in-images) — on-device recognition, observations, languages, and confidence.
16. [Creating a Core Data model for CloudKit](https://developer.apple.com/documentation/coredata/creating-a-core-data-model-for-cloudkit) — schema restrictions and production evolution.
17. [Reading CloudKit records for Core Data](https://developer.apple.com/documentation/coredata/reading-cloudkit-records-for-core-data) — binary/asset mapping.
18. [SQLite FTS5](https://www.sqlite.org/fts5.html) — full-text indexing/query primitives.
19. [Consuming relevant store changes](https://developer.apple.com/documentation/coredata/consuming-relevant-store-changes) — incremental history processing.
20. [TN3163: Core Data/CloudKit synchronization](https://developer.apple.com/documentation/technotes/tn3163-understanding-the-synchronization-of-nspersistentcloudkitcontainer) — local store, imports, exports, and scheduling.
21. [Foundation Models: generating content](https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models) — later on-device model access and availability.
22. [Setting up Core Data with CloudKit](https://developer.apple.com/documentation/coredata/setting-up-core-data-with-cloudkit) — entitlements, push support, and background mode.
23. [Mirroring a Core Data store with CloudKit](https://developer.apple.com/documentation/coredata/mirroring-a-core-data-store-with-cloudkit) — development program/account prerequisites.
24. [Offering account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/) — in-app account deletion and token revocation.
25. [TN3194: account deletion and Sign in with Apple revocation](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple) — lifecycle, server-backed token handling, and documented fallback.
26. [Apple HIG onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding) — short, contextual guidance.
27. [Core Data performance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/Performance.html) — bounded fetches, faults, and large-object considerations.

The architecture, record names, screen arrangement, phase boundaries, and performance targets in this guide are design recommendations for this project. They are not guarantees made by the cited vendors.
