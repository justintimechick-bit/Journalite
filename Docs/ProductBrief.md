# Journalite product agreement

## Scope and status
Native Swift/SwiftUI, iPhone-first app for digitizing private handwritten journals.
- **Library & Onboarding**: First-run local onboarding, optional starter notebooks, notebook creation/rename/color/symbol editing, recent entries, paged notebook contents, stable entry/page navigation, entry metadata editing/moves, and Recently Deleted with restore and confirmed permanent deletion.
- **Capture & OCR**: VisionKit document scanning and PhotosPicker import, durable image persistence and local OCR receipts, on-device handwriting transcription (Apple Foundation Models when available, otherwise Apple Vision OCR) with multi-language support, durable sequential execution queue, and retry actions.
- **Reading & Editing Experience**: Photo, Text and Compare views; see the section below.
- **Search**: on-device full-text search of the text each page shows (including corrections), entry titles and notebook names; see Search below.
- **Cloud**: cloud sync and account features remain deferred. No launch-time camera or photo-library permission is requested. No generative rewriting, summarizing or AI "improvement" of journal text is used; see On-device language model policy.

## Current OCR behavior
- New locally captured/imported pages are queued only after durable image saves. Older pages with no retained local receipt require an explicit Transcribe on This iPhone action; a missing result alone never establishes local ownership.
- Recognition first tries Apple's on-device Foundation Models language model (`SystemLanguageModel`, iOS 27+) for strictly verbatim transcription, and otherwise uses built-in Apple Vision accurate mode, initially English, with a supported-language setting. Vision is used when Settings → Use Apple Intelligence for Handwriting is off, when Apple Intelligence is unavailable (unsupported device or OS, turned off, model still downloading), when the model fails (including dense pages that exceed its context), or when it returns no text. No remote service, Private Cloud Compute, API key, generative rewriting, or custom-word expansion is used.
- Each page records which engine produced its text; Text mode and Revisions show it. Only new pages and explicit Retry OCR use the current engine choice; saved pages are never re-transcribed automatically.
- Normal horizontal line-based pages are ordered using observation geometry. Arbitrary multi-column layouts and perfect cursive recognition are not supported claims. Review the original photo.
- Waiting to transcribe, Transcribing, Needs review, and Couldn't transcribe states are shown. Empty recognized text is saved honestly and manual typing remains available. Confidence is only an internal review hint, never an accuracy percentage; the language model provides none, so its pages show no low-confidence hint.
- Photos and manual revisions survive OCR retries and failures. Background suspension pauses processing; the app makes no promise of continuous background recognition.

## On-device language model policy
- Apple Foundation Models are used **only for verbatim optical transcription** of page photos: word for word, with the writer's exact spelling, capitalization, punctuation, names, numbers and verse references, original line breaks, headings and list markers. Unreadable words become `[illegible]`; the model must not guess from context, correct, complete, summarize, translate or add anything. Text in a photo is treated as content, never as instructions.
- Only the on-device `SystemLanguageModel` is used — never Private Cloud Compute or any server — so page photos never leave the iPhone. Model output is not logged.
- The model's text is OCR output like Vision's: stored as raw OCR, never overwrites a manual revision, and is edited only by the user. Generative features (insights, summaries, rewriting, suggestions) remain out of scope.

## Reading & Editing Experience
- **Photo**: the preserved page photo with pinch-to-zoom and a location-free share copy.
- **Text**: the current saved text with selection, Reviewed / Needs review status and toggle, low-confidence hint, an unsaved-draft notice, Copy Text, Revisions and Retry OCR.
- **Compare (iPhone)**: zoomable photo above a text editor that stays usable with the keyboard and at large Dynamic Type sizes. Visible page navigation and an "Editing page N of M" header; explicit Save (also on the keyboard toolbar), Revert, and dirty-state indicators.
- **Saving**: only a deliberate change can be saved. Text is stored exactly as typed — names, verse references and personal spelling are kept; no AI or automatic correction.
- **Current text**: the selected manual revision when available (blank is valid); otherwise OCR. If the selected revision hasn't arrived yet, the app shows a waiting state and keeps that choice.
- **Review**: marks the specific current text as reviewed. New saved text, a restore, or new OCR over OCR text returns the page to Needs review.
- **Revisions**: full history with non-destructive restore (creates a new revision); the latest raw OCR is shown separately.
- **Retry OCR**: explains first that the new result becomes the current text and saved corrections stay in Revisions.
- **Unsaved work**: drafts survive page changes and reloads. Leaving the entry with drafts asks first. If saved text changes while editing, the draft is kept and the user chooses: save draft, merge, keep editing, or discard.
- **Pages**: add by scan or photo import (same limits as capture), reorder, remove and restore from Manage Pages.
- Drafts live only while the entry is open; they are not saved across app termination.

## Search
- Searches the current text of every live page: the selected correction (a blank correction hides OCR), otherwise OCR. Superseded corrections, OCR hidden by a correction, and trashed entries, notebooks or removed pages are not searched. Entry titles and notebook names are searched too, so entries without text can still be found.
- Matching is case- and accent-insensitive and works from the start of words: “pray” finds “prayer”. Punctuated words like “3:16” or “don’t” must match together. Quotes find an exact phrase. It does not find text in the middle of words, misspellings, similar meanings, or handwriting OCR missed.
- Default scope is All Notebooks; filters for notebook, journal date, favorites and review state. Up to 50 results, each with a short excerpt (matches in bold and underlined), notebook, date, page number and thumbnail. Opening a result shows that exact page with the matched words emphasized.
- The index is a separate copy on this iPhone, excluded from backup and rebuilt from the journal when needed; Settings → Rebuild Search Index. Journal text is not added to Spotlight or written to logs.

## Product requirements
- Photograph/scan or import journal pages; preserve source images and produce on-device OCR.
- Support multiple named notebooks. Optional starter names: Bible Notes, Personal Motivation, Letters to My Family. Never insert fabricated journal content.
- Search saved transcriptions and open the exact matching page.
- Edit recognized text while comparing it with its source photo.
- Later add explicit, real Sign in with Apple and private iCloud sync as separate capabilities.
- AI insights, summaries and any generative rewriting are deferred. The only permitted model use is the on-device verbatim transcription described above.

## Privacy and truthfulness
The free local configuration must not upload journal content anywhere or include iCloud, push, or Sign in with Apple entitlements. No paid OCR service, third-party analytics, server, or external package for the base app. Never log journal text, photos, tokens, or other sensitive payloads. Never fake authentication, uploads, OCR, successful saves, or test results.

## Phase workflow
Before each phase, read all four Docs files, repository instructions, and current code. Implement only the requested phase through completion, build using available Xcode tools, run relevant checks, and update BuildProgress with actual outcomes and physical-iPhone checks still needed. Report changed files, actual build/test results, exact manual Xcode steps when needed, and at most five practical verification steps. Stop at the phase boundary.

The existing Journalite/iPhone_Journal_Xcode_Codex_Prompts.md is background and future phase guidance; its later prompts do not authorize implementation now. Current user instructions take precedence.
