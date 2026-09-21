import SwiftUI

/// `RadioStation` already carries an `id` — the conformance lets it be used directly
/// in a `ForEach`.
extension RadioStation: Identifiable {}

/// A panel row's icon: either an SF Symbol or an image from the asset catalog.
///
/// The two do not size the same way, and they must never be forced into the same frame:
/// catalog images carry their own internal padding and therefore have to fill the **whole**
/// circle, whereas an SF Symbol sizes itself by its font. Constraining both to one frame
/// makes the assets tiny next to the symbols.
enum SourceIcon {
    case symbol(String)
    case asset(String)

    @ViewBuilder
    var image: some View {
        switch self {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
        case .asset(let name):
            // Sized on the badge itself (`MenuRowMetrics.iconSize`): the asset carries
            // its own padding and therefore has to fill the whole circle.
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: MenuRowMetrics.iconSize, height: MenuRowMetrics.iconSize)
        }
    }
}

/// An audio source that can be shown in the panel.
///
/// `id` must match the backend's `AudioSource` enum value **exactly**
/// (`backend/core/models/audio_state.py`). The backend is the source of truth: this
/// catalog only describes how each identifier is displayed.
struct AudioSourceDescriptor: Identifiable {
    let id: String
    let titleKey: String
    let icon: SourceIcon

    var title: String { L(titleKey) }
}

enum AudioSourceCatalog {
    /// Fallback order only. The real display order comes from `enabled_apps`
    /// (backend) — never hardcode the order anywhere else.
    static let all: [AudioSourceDescriptor] = [
        .init(id: "spotify",   titleKey: "source.spotify",   icon: .asset("spotify-icon")),
        .init(id: "bluetooth", titleKey: "source.bluetooth", icon: .asset("bluetooth-icon")),
        .init(id: "radio",     titleKey: "source.radio",     icon: .asset("radio-icon")),
        .init(id: "podcast",   titleKey: "source.podcast",   icon: .asset("podcasts-icon")),
        .init(id: "airplay",   titleKey: "source.airplay",   icon: .symbol("airplay.audio")),
        .init(id: "mac",       titleKey: "source.mac",       icon: .asset("macos-icon")),
        .init(id: "cd",        titleKey: "source.cd",        icon: .asset("cd-icon")),
        .init(id: "dlna",      titleKey: "source.dlna",      icon: .asset("dlna-icon")),
        .init(id: "qobuz",     titleKey: "source.qobuz",     icon: .asset("qobuz-icon")),
        .init(id: "tidal",     titleKey: "source.tidal",     icon: .asset("tidal-icon")),
        .init(id: "music_library", titleKey: "source.music_library", icon: .asset("music-library-icon"))
    ]

    static let allIds: [String] = all.map(\.id)

    private static let byId: [String: AudioSourceDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// Sources to display, in the order imposed by the backend (`enabled_apps`).
    /// `enabled_apps` is both the **filter** and the **order**.
    static func ordered(enabledApps: [String]?) -> [AudioSourceDescriptor] {
        guard let enabledApps else { return all }
        return enabledApps.compactMap { byId[$0] }
    }
}

/// A toggleable feature (a switch), as opposed to a source (a selection).
struct FeatureDescriptor: Identifiable {
    let id: String
    let titleKey: String
    let icon: SourceIcon

    var title: String { L(titleKey) }
}

enum FeatureCatalog {
    static let all: [FeatureDescriptor] = [
        .init(id: "multiroom", titleKey: "feature.multiroom", icon: .asset("multiroom-icon")),
        .init(id: "equalizer", titleKey: "feature.equalizer", icon: .asset("equalizer-icon"))
    ]

    /// Multiroom is shown by default (historical behaviour: `?? true`),
    /// the equalizer only if explicitly listed (`?? false`).
    static func enabled(enabledApps: [String]?) -> [FeatureDescriptor] {
        all.filter { feature in
            switch feature.id {
            case "multiroom": return enabledApps?.contains("multiroom") ?? true
            case "equalizer": return enabledApps?.contains("equalizer") ?? false
            default:          return enabledApps?.contains(feature.id) ?? false
            }
        }
    }
}
