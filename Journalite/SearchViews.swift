import SwiftUI

/// Converts `SearchMarkup` emphasis into bold, underlined runs, so matches are never shown by
/// color alone.
enum SearchEmphasis {
    static func attributed(_ marked: String) -> AttributedString {
        var result = AttributedString()
        var buffer = ""
        var emphasized = false
        func flush() {
            guard !buffer.isEmpty else { return }
            var run = AttributedString(buffer)
            if emphasized {
                run.inlinePresentationIntent = .stronglyEmphasized
                run.underlineStyle = .single
            }
            result += run
            buffer = ""
        }
        for character in marked {
            if String(character) == SearchMarkup.open {
                flush()
                emphasized = true
            } else if String(character) == SearchMarkup.close {
                flush()
                emphasized = false
            } else {
                buffer.append(character)
            }
        }
        flush()
        return result
    }

    /// Emphasizes the query's words inside plain page text (used when a result opens a page).
    static func attributed(_ text: String, query: String) -> AttributedString {
        let ranges = SearchQuery.emphasisRanges(in: text, terms: SearchQuery.terms(from: query))
        guard !ranges.isEmpty else { return AttributedString(text) }
        var marked = ""
        var cursor = text.startIndex
        for range in ranges {
            marked += text[cursor..<range.lowerBound] + SearchMarkup.open + text[range] + SearchMarkup.close
            cursor = range.upperBound
        }
        marked += text[cursor...]
        return attributed(marked)
    }
}

private struct SearchRequest: Hashable {
    let text: String
    let filters: SearchFilters
    let indexRevision: Int
}

struct SearchView: View {
    let model: JournalAppModel

    private enum Phase: Equatable { case idle, searching, done, failed }

    @State private var text = ""
    @State private var filters = SearchFilters()
    @State private var results: [SearchHit] = []
    @State private var resultsQuery = ""
    @State private var phase: Phase = .idle
    @State private var showingFilters = false

    private var search: SearchCoordinator { model.search }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        content
            .navigationTitle("Search")
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text("Pages, titles and notebooks"))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingFilters = true } label: {
                        Label(filters.isDefault ? "Filters" : "Filters On",
                              systemImage: filters.isDefault ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showingFilters) {
                SearchFiltersSheet(filters: $filters, notebooks: model.notebooks)
            }
            // Changing text, filters or the index cancels the previous request automatically.
            .task(id: SearchRequest(text: trimmed, filters: filters, indexRevision: search.revision)) {
                await run(text: trimmed, filters: filters)
            }
    }

    @ViewBuilder
    private var content: some View {
        if trimmed.isEmpty {
            List {
                if let banner = statusBanner { Section { banner } }
                Section {
                    ContentUnavailableView {
                        Label("Search your journal", systemImage: "magnifyingglass")
                    } description: {
                        Text("Find words in transcribed pages, entry titles and notebook names. Words match from their beginning, so “pray” finds “prayer”. Put words in quotes to find an exact phrase. Searching looks at the text shown for each page, including your corrections.")
                    }
                }
                if !filters.isDefault {
                    Section { activeFiltersRow }
                }
            }
        } else if phase == .failed && results.isEmpty {
            ContentUnavailableView {
                Label("Search isn’t available right now", systemImage: "exclamationmark.magnifyingglass")
            } description: {
                Text("Your journal is safe. Try again, or rebuild the search index in Settings.")
            } actions: {
                Button("Try Again") { Task { await run(text: trimmed, filters: filters) } }
            }
        } else if results.isEmpty && (search.status == .building || search.status == .notConfigured) {
            ContentUnavailableView {
                Label("Building search index…", systemImage: "hourglass")
            } description: {
                Text("Journalite is preparing search on this iPhone. Results will appear when it finishes.")
            }
        } else if phase == .done && results.isEmpty && resultsQuery == trimmed {
            List {
                if let banner = statusBanner { Section { banner } }
                Section {
                    ContentUnavailableView.search(text: trimmed)
                }
                if !filters.isDefault {
                    Section {
                        activeFiltersRow
                        Button("Clear Filters") { filters = SearchFilters() }
                    }
                }
            }
        } else {
            List {
                if let banner = statusBanner { Section { banner } }
                if !filters.isDefault { Section { activeFiltersRow } }
                Section {
                    ForEach(results) { hit in
                        NavigationLink(value: EntryRoute(entryID: hit.entryID, targetPageID: hit.pageID, highlight: resultsQuery)) {
                            SearchResultRow(model: model, hit: hit)
                        }
                    }
                } footer: {
                    if results.count >= SearchCoordinator.resultLimit {
                        Text("Showing the first \(SearchCoordinator.resultLimit) matches. Add words or filters to narrow the results.")
                    }
                }
            }
            .overlay(alignment: .top) {
                if phase == .searching { ProgressView().padding(.top, 8) }
            }
        }
    }

    private var statusBanner: Label<Text, Image>? {
        switch search.status {
        case .building:
            return Label("Updating the search index. Results may be incomplete.", systemImage: "hourglass")
        case .failed:
            return Label("The search index couldn’t be updated. Results may be out of date. Rebuild it in Settings.",
                         systemImage: "exclamationmark.triangle")
        case .fallback:
            return Label("Limited search: full-text indexing isn’t available on this device, so only the \(FallbackSearcher.entryLimit) most recent entries are searched.",
                         systemImage: "info.circle")
        case .ready, .notConfigured:
            return nil
        }
    }

    private var activeFiltersRow: some View {
        Label(filterSummary, systemImage: "line.3.horizontal.decrease.circle.fill")
            .font(.subheadline)
    }

    private var filterSummary: String {
        var parts: [String] = []
        if let id = filters.notebookID {
            parts.append(model.notebooks.first { $0.id == id }?.name ?? String(localized: "One notebook"))
        }
        if filters.dateFrom != nil || filters.dateThrough != nil { parts.append(String(localized: "Date range")) }
        if filters.favoritesOnly { parts.append(String(localized: "Favorites")) }
        switch filters.review {
        case .any: break
        case .needsReview: parts.append(String(localized: "Needs review"))
        case .reviewed: parts.append(String(localized: "Reviewed"))
        }
        return String(localized: "Filters: ") + parts.joined(separator: ", ")
    }

    private func run(text: String, filters: SearchFilters) async {
        guard !text.isEmpty else {
            results = []
            resultsQuery = ""
            phase = .idle
            return
        }
        // Debounce: a newer keystroke cancels this task before the query runs.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        phase = .searching
        do {
            let hits = try await search.search(text, filters: filters)
            guard !Task.isCancelled else { return }
            results = hits
            resultsQuery = text
            phase = .done
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed
        }
    }
}

struct SearchResultRow: View {
    let model: JournalAppModel
    let hit: SearchHit
    @State private var thumbnailURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let thumbnailURL {
                    LocalJPEGView(url: thumbnailURL)
                } else {
                    Image(systemName: hit.pageID == nil ? "doc.text" : "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                if SearchMarkup.plain(hit.title).isEmpty {
                    Text("Untitled entry").font(.headline)
                } else {
                    Text(SearchEmphasis.attributed(hit.title)).font(.headline)
                }
                if !hit.excerpt.isEmpty {
                    Text(SearchEmphasis.attributed(hit.excerpt))
                        .font(.subheadline)
                        .lineLimit(3)
                } else if hit.pageID != nil {
                    Text("No text on this page").font(.subheadline.italic()).foregroundStyle(.secondary)
                }
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .task(id: hit.imageVersion) {
            guard let pageID = hit.pageID, let repository = model.repository else { return }
            thumbnailURL = try? await JournalImageCache.shared.image(pageID: pageID, repository: repository, kind: .thumbnail)
        }
    }

    private var metadata: String {
        var parts: [String] = []
        if !hit.notebookName.isEmpty { parts.append(SearchMarkup.plain(hit.notebookName)) }
        if let date = hit.journalDate { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if hit.pageNumber > 0 { parts.append(String(localized: "Page \(hit.pageNumber)")) }
        if hit.isFavorite { parts.append(String(localized: "Favorite")) }
        return parts.joined(separator: " · ")
    }
}

struct SearchFiltersSheet: View {
    @Binding var filters: SearchFilters
    let notebooks: [NotebookSummary]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Notebook") {
                    Picker("Search in", selection: $filters.notebookID) {
                        Text("All Notebooks").tag(UUID?.none)
                        ForEach(notebooks) { notebook in
                            Text(notebook.name).tag(Optional(notebook.id))
                        }
                    }
                }
                Section {
                    Toggle("From", isOn: Binding(
                        get: { filters.dateFrom != nil },
                        set: { filters.dateFrom = $0 ? Calendar.current.startOfDay(for: filters.dateThrough ?? Date()) : nil }
                    ))
                    if let from = filters.dateFrom {
                        DatePicker("Start date", selection: Binding(
                            get: { from },
                            set: { filters.dateFrom = Calendar.current.startOfDay(for: $0) }
                        ), displayedComponents: .date)
                    }
                    Toggle("Through", isOn: Binding(
                        get: { filters.dateThrough != nil },
                        set: { filters.dateThrough = $0 ? Self.endOfDay(filters.dateFrom ?? Date()) : nil }
                    ))
                    if let through = filters.dateThrough {
                        DatePicker("End date", selection: Binding(
                            get: { through },
                            set: { filters.dateThrough = Self.endOfDay($0) }
                        ), displayedComponents: .date)
                    }
                } header: {
                    Text("Journal date")
                } footer: {
                    Text("Entries without a journal date are left out while a date filter is on.")
                }
                Section {
                    Toggle("Favorites only", isOn: $filters.favoritesOnly)
                    Picker("Review state", selection: $filters.review) {
                        Text("Any").tag(SearchFilters.Review.any)
                        Text("Needs review").tag(SearchFilters.Review.needsReview)
                        Text("Reviewed").tag(SearchFilters.Review.reviewed)
                    }
                }
                if !filters.isDefault {
                    Section {
                        Button("Clear Filters", role: .destructive) { filters = SearchFilters() }
                    }
                }
            }
            .navigationTitle("Search Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private static func endOfDay(_ date: Date) -> Date {
        let start = Calendar.current.startOfDay(for: date)
        return Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }
}

struct SearchSettingsSection: View {
    let search: SearchCoordinator

    var body: some View {
        Section {
            switch search.status {
            case .ready:
                Label("Search index is up to date", systemImage: "checkmark.circle")
            case .building, .notConfigured:
                Label("Building search index…", systemImage: "hourglass")
            case .failed:
                Label("Search index needs rebuilding", systemImage: "exclamationmark.triangle")
            case .fallback:
                Label("Limited search on this device", systemImage: "info.circle")
            }
            Button("Rebuild Search Index") { Task { await search.rebuild() } }
                .disabled(search.status == .building || search.status == .fallback || search.status == .notConfigured)
        } header: {
            Text("Search")
        } footer: {
            Text("The search index is a separate copy kept only on this iPhone and is not backed up; it’s rebuilt from your journal whenever needed. Rebuilding never changes or deletes journal entries. Journal text is not added to Spotlight.")
        }
    }
}
