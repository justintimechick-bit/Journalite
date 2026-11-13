# Xcode setup

## Inspected environment — 2026-11-12
- Existing project: /Users/justinchick/Journalite/Journalite.xcodeproj.
- Application target Journalite and Swift Testing target JournaliteTests. Active app scheme remains Journalite. Tests are in the separate JournaliteTests scheme.
- Installed selected toolchain reports Xcode 27.2 (27B52), Apple Swift 6.4.2 (swiftlang-6.4.2.1.9). Version output has no beta label. iOS/device and Simulator SDKs are 27.2; macOS, tvOS, watchOS, visionOS and DriverKit SDKs are also installed.
- Swift language mode remains 5.0, default actor isolation MainActor, approachable concurrency enabled.
- iOS deployment target changed from template default 27.2 to agreed 17.0; the starter has no requirement for a higher minimum. Build against the installed SDK; guard newer APIs. iOS 17 runtime behavior has not been tested.
- Existing supported platforms remain iOS, iOS Simulator, macOS, visionOS and visionOS Simulator; device families 1,2,7 remain unchanged. Product development is iPhone-first; other platforms have not been validated.
- Sole entry point: Journalite/MyApp.swift. UI: Journalite/ContentView.swift; preview preserved.
- Assets.xcassets contains catalog Contents.json and an unconfigured universal AccentColor.colorset. No AppIcon set is present. Assets were preserved.
- No AGENTS.md was found in the repository or checked ancestor directories. Read the existing iPhone_Journal_Xcode_Codex_Prompts.md as development guidance; future prompts remain deferred.

## Signing preserved
Observed evaluated bundle ID: devplaceholder.PN952AHI.Journalite.
Observed development team: 33TJ3U9B2Q.
Signing: Automatic, Apple Development. CODE_SIGN_ENTITLEMENTS is empty. No cloud container ID has been configured or invented. No iCloud, push, or Sign in with Apple entitlement was added. Do not infer paid membership from a team ID.

Preserve bundle ID and team unless a later phase explicitly authorizes a documented change. The free configuration must remain local without cloud/account capabilities.

## Build and manual Xcode steps
The simulator build succeeds with the existing signing configuration. Active destination was changed from Justin’s 18 Pro to iPhone 18 Pro Simulator (iOS 27.2) to validate without physical-device provisioning.

For local verification, select scheme Journalite and destination iPhone 18 Pro Simulator; choose Product > Build (Command-B), then Product > Run (Command-R). Open ContentView.swift and resume its Canvas preview to check the first-run screen backed by a separate in-memory store. The preview never changes the live onboarding preference or store.

Historical setup blocker (resolved by the successful device builds below): the initial device build failed: the existing bundle ID is unavailable for registration to this team, and Xcode finds no matching iOS App Development profile. To investigate, select the Journalite project > Journalite target > Signing & Capabilities, inspect the existing Team and Bundle Identifier, and ensure the intended account is available in Xcode > Settings > Accounts. Resolve registration/profile access for that existing identifier before selecting Justin’s 18 Pro and building/running. If access cannot be resolved, a separately authorized unique bundle ID change is required; none was made in setup.

Do not enable iCloud, Push Notifications, or Sign in with Apple to resolve this local build issue. No manual steps are required for the successful simulator app build.

## Current device and OCR setup — 2026-11-12
Journalite now builds and runs on Justin’s 18 Pro (iOS 27.2), and all 23 test cases pass on that device. The user separately confirmed notebook creation and scanning work. No app identity, team or capability change was made for OCR. Earlier provisioning failures below are historical.

No new Xcode capability or permission is required for Vision OCR. NSCameraUsageDescription already explains user-initiated journal scanning; no unrestricted photo-library, iCloud, push or Sign in with Apple entitlement was added. Built-in Vision APIs were checked through installed Apple documentation and compiled against this SDK.

Current bundled model is V3. PersistenceController explicitly loads JournalModelV3.mom and checks required attributes; V1/V2 remain bundled for migration. Do not delete the installed app to resolve a model issue.

To run: select Journalite / Justin’s 18 Pro, then Product > Run (Command-R). To test: first build Journalite for the chosen device or simulator, then select JournaliteTests on that same destination and Product > Test (Command-U); return to Journalite afterward. Settings > On-device transcription exposes supported recognition languages. Existing pages with no local provenance receipt require Transcribe on This iPhone.

## Phase 1 test configuration and repeatable steps
JournaliteTests is an iOS test bundle (minimum iOS 17) using Swift Testing. The Journalite app scheme's plan has no tests; select JournaliteTests to run the tests (37 cases as of the entry editing update, including parameterized migration and cancellation cases). For a fresh build:
1. Select Journalite / iPhone 18 Pro Simulator and Product > Build (Command-B).
2. Select JournaliteTests / the same simulator and Product > Test (Command-U).
3. Return to Journalite for running the app or rendering its preview.

Command line equivalent (after step 1 has built the app for that simulator): `xcodebuild test -project Journalite.xcodeproj -scheme JournaliteTests -destination 'platform=iOS Simulator,name=iPhone 18 Pro'`. `xcodebuild -target Journalite` does not refresh the `Journalite.debug.dylib` the tests link against, so build the app through Xcode first; otherwise linking fails with undefined app symbols.

The tools created a separate test scheme without a host-target dependency. TEST_HOST points to the built Journalite.app/Journalite, and BUNDLE_LOADER points to $(TEST_HOST).debug.dylib to link the installed Xcode's preview-compatible Debug app layout. Tests passed with that configuration. The app's ENABLE_DEBUG_DYLIB override was removed, preserving working Canvas previews.

Limitation: the test scheme currently requires building the app first and is configured for Debug, not Release testing. To consolidate this manually in Xcode: select JournaliteTests target > General > Testing > Host Application > Journalite; in Build Phases > Target Dependencies add Journalite if absent; then Edit Scheme > Journalite > Test and add JournaliteTests to its test plan. Let Xcode configure host linkage and verify before removing the explicit BUNDLE_LOADER override. Do not alter app identity or signing capabilities.

The versioned model was compiled by momc in the successful app build. Xcode's directory tool could not create the nested model version package, so its XML and .xccurrentversion were written directly under the model package already registered with Xcode. No project.pbxproj was parsed or directly edited.
