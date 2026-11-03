import AppKit
import FaugusCore
import SwiftUI

/// `show_steamgriddb_picker`: thumbnails for one category, a search field, and a click to
/// download the full image.
struct SteamGridDBPicker: View {
    let translate: Translator
    let slot: ArtworkSlot
    let initialTitle: String
    let steamGridDBID: Int?
    let steamAppID: Int?
    let client: SteamGridDBClient
    let onPick: (Data) -> Void
    let onCancel: () -> Void

    @State private var term = ""
    @State private var items: [PickerItem] = []
    @State private var isLoading = true
    @State private var searchGeneration = 0
    @State private var isDownloading = false

    private var isBanner: Bool {
        slot == .banner
    }

    private var thumbnailSize: CGSize {
        isBanner ? CGSize(width: 660, height: 213) : CGSize(width: 160, height: slot == .cover ? 240 : 160)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(translate(slot.pickerTitle)).font(.title3.weight(.semibold)).padding(.top, 16)
            TextField(translate("Search..."), text: $term)
                .textFieldStyle(.roundedBorder)
                .padding(12)
                .onSubmit { startSearch(term.trimmingCharacters(in: .whitespacesAndNewlines)) }
            Group {
                if isLoading || isDownloading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    Text(translate("No results found")).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        if isBanner {
                            LazyVStack(spacing: 8) {
                                ForEach(items) { item in thumbButton(item) }
                            }
                            .padding(10)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: thumbnailSize.width), spacing: 8)],
                                spacing: 8
                            ) {
                                ForEach(items) { item in thumbButton(item) }
                            }
                            .padding(10)
                        }
                    }
                }
            }
            .frame(minHeight: 360)
            HStack {
                Spacer()
                Button(translate("Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: isBanner ? 720 : 720, height: 520)
        .onAppear {
            term = initialTitle
            startSearch(initialTitle, gameID: steamGridDBID, steamAppID: steamAppID)
        }
    }

    private func thumbButton(_ item: PickerItem) -> some View {
        Button {
            pick(item.candidate.url)
        } label: {
            if let image = NSImage(data: item.thumbnail) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                    .clipped()
            }
        }
        .buttonStyle(.plain)
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        .clipped()
        .disabled(isDownloading)
    }

    private func startSearch(_ searchTerm: String, gameID: Int? = nil, steamAppID: Int? = nil) {
        guard !searchTerm.isEmpty else { return }
        searchGeneration += 1
        let generation = searchGeneration
        isLoading = true
        items = []
        Task {
            let found = await client.candidates(
                gameName: searchTerm, limit: 24, gameID: gameID, steamAppID: steamAppID
            )
            let candidates: [SteamGridDBCandidate] =
                switch slot {
                case .cover: found.grids
                case .icon: found.icons
                case .banner: found.heroes
                }
            var downloaded: [PickerItem] = []
            await withTaskGroup(of: PickerItem?.self) { group in
                for candidate in candidates {
                    group.addTask {
                        guard let data = try? await client.downloadImage(from: candidate.thumb) else { return nil }
                        return PickerItem(candidate: candidate, thumbnail: data)
                    }
                }
                for await item in group {
                    if let item {
                        downloaded.append(item)
                    }
                }
            }
            guard generation == searchGeneration else { return }
            items = downloaded
            isLoading = false
        }
    }

    private func pick(_ url: String) {
        isDownloading = true
        Task {
            let data = try? await client.downloadImage(from: url)
            isDownloading = false
            if let data {
                onPick(data)
            }
        }
    }
}

private struct PickerItem: Identifiable {
    let id = UUID()
    let candidate: SteamGridDBCandidate
    let thumbnail: Data
}
