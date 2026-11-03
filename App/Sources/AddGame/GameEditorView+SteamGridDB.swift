import FaugusCore
import SwiftUI

extension GameEditorView {
    var steamGridDBUsable: Bool {
        model.steamGridDBSettings?.isUsable ?? false
    }

    var showsBanner: Bool {
        showsCover && steamGridDBUsable
    }

    func artworkMenu(
        translate: Translator, slot: ArtworkSlot, hasImage: Bool, @ViewBuilder label: @escaping () -> some View
    ) -> some View {
        ArtworkMenu(
            translate: translate,
            hasImage: hasImage,
            steamGridDBEnabled: steamGridDBUsable,
            loadFile: { loadFile(slot) },
            loadURL: { urlPrompt = slot },
            remove: { state.artwork.clear(slot) },
            refresh: { refreshArtwork(slot) },
            pickSteamGridDB: { pickerSlot = slot },
            label: label
        )
    }

    var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(titleSuggestions, id: \.id) { suggestion in
                Button {
                    applyTitleSuggestion(name: suggestion.name, gameID: suggestion.id)
                } label: {
                    Text(suggestion.name).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    func bannerPanel(_ translate: Translator) -> some View {
        artworkMenu(translate: translate, slot: .banner, hasImage: state.artwork.banner != nil) {
            ZStack {
                TempImage(path: state.artwork.banner, size: CGSize(width: 480, height: 155), fill: true) {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if artworkLoading.contains(.banner) {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .accessibilityIdentifier("editor-banner")
    }

    /// `on_title_changed_for_suggestions`: 350 ms after the last keystroke, list matching games.
    func scheduleTitleSuggestions() {
        suggestionTask?.cancel()
        state.steamGridDBID = nil
        state.steamAppIDForGridDB = nil
        let term = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard steamGridDBUsable, !term.isEmpty, let client = model.steamGridDBClient else {
            titleSuggestions = []
            return
        }
        suggestionTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let suggestions = await client.autocomplete(term: term)
            guard !Task.isCancelled else { return }
            titleSuggestions = suggestions
        }
    }

    func applyTitleSuggestion(name: String, gameID: Int) {
        let stripped = name.replacingOccurrences(
            of: #"\s*\(\d{4}\)\s*$"#, with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        suppressTitleSuggestions = true
        state.title = stripped
        state.steamGridDBID = gameID
        titleSuggestions = []
        suppressTitleSuggestions = false
        fetchArtwork()
    }

    /// `get_artwork` / `refresh_single_artwork`: first SteamGridDB hit per wanted category.
    func fetchArtwork(only slot: ArtworkSlot? = nil) {
        let title = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let client = model.steamGridDBClient else { return }
        let wantIcon = slot == nil || slot == .icon
        let wantCover = (slot == nil || slot == .cover) && showsCover
        let wantBanner = (slot == nil || slot == .banner) && showsBanner
        guard wantIcon || wantCover || wantBanner else { return }

        if wantIcon {
            artworkLoading.insert(.icon)
        }
        if wantCover {
            artworkLoading.insert(.cover)
        }
        if wantBanner {
            artworkLoading.insert(.banner)
        }
        artworkFetchGeneration += 1
        let generation = artworkFetchGeneration
        lastArtworkTitle = title
        let request = SteamGridDBArtworkRequest(
            gameTitle: title,
            gameID: state.original?.gameID ?? suggestedID,
            steamGridDBID: state.steamGridDBID,
            steamAppID: state.steamAppIDForGridDB,
            wantIcon: wantIcon,
            wantCover: wantCover,
            wantBanner: wantBanner
        )
        Task {
            let artwork = await client.fetchArtwork(for: request)
            guard generation == artworkFetchGeneration else { return }
            if let identifier = artwork.steamGridDBID {
                state.steamGridDBID = identifier
            }
            if wantIcon {
                if let data = artwork.iconPNG {
                    _ = state.artwork.setIcon(data: data)
                }
                artworkLoading.remove(.icon)
            }
            if wantCover {
                if let data = artwork.coverData {
                    _ = state.artwork.setCover(data: data)
                } else {
                    state.artwork.clear(.cover)
                }
                artworkLoading.remove(.cover)
            }
            if wantBanner {
                if let data = artwork.bannerData {
                    _ = state.artwork.setBanner(data: data)
                } else {
                    state.artwork.clear(.banner)
                }
                artworkLoading.remove(.banner)
            }
        }
    }

    /// `on_refresh`: one category, or all of them when SteamGridDB is off (nothing to fetch then).
    func refreshArtwork(_ slot: ArtworkSlot) {
        if state.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.artwork.clear(slot)
            return
        }
        if steamGridDBUsable {
            fetchArtwork(only: slot)
        }
    }

    /// `on_entry_focus_out`: fetch once the title has settled and no suggestion was chosen.
    func scheduleArtworkForTitle() {
        let title = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != lastArtworkTitle else { return }
        artworkDebounceTask?.cancel()
        artworkDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            if state.steamGridDBID == nil {
                fetchArtwork()
            }
        }
    }
}
