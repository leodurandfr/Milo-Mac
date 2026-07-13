import SwiftUI

/// `RadioStation` porte déjà un `id` — la conformité permet de l'utiliser directement
/// dans un `ForEach`.
extension RadioStation: Identifiable {}

/// Icône d'une ligne du panneau : soit un SF Symbol, soit une image du catalogue.
///
/// Les deux ne se dimensionnent pas de la même façon et il ne faut surtout pas leur
/// imposer la même taille : les images du catalogue portent leur propre marge interne et
/// doivent donc remplir **tout** le cercle, tandis qu'un SF Symbol se dimensionne par sa
/// police. Les contraindre au même cadre rend les assets minuscules à côté des symboles.
enum SourceIcon {
    case symbol(String)
    case asset(String)

    /// Diamètre du cercle qui contient l'icône.
    static let circleSize: CGFloat = 26

    @ViewBuilder
    var image: some View {
        switch self {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: Self.circleSize, height: Self.circleSize)
        }
    }
}

/// Une source audio affichable dans le panneau.
///
/// `id` doit correspondre **exactement** à la valeur de l'enum `AudioSource` du backend
/// (`backend/core/models/audio_state.py`). Le backend est la source de vérité : ce
/// catalogue ne fait que décrire comment chaque identifiant s'affiche.
struct AudioSourceDescriptor: Identifiable {
    let id: String
    let titleKey: String
    let icon: SourceIcon

    var title: String { L(titleKey) }
}

enum AudioSourceCatalog {
    /// Ordre de repli uniquement. L'ordre réel d'affichage vient de `enabled_apps`
    /// (backend) — ne jamais coder l'ordre en dur ailleurs.
    static let all: [AudioSourceDescriptor] = [
        .init(id: "spotify",   titleKey: "source.spotify",   icon: .asset("spotify-icon")),
        .init(id: "bluetooth", titleKey: "source.bluetooth", icon: .asset("bluetooth-icon")),
        .init(id: "radio",     titleKey: "source.radio",     icon: .asset("radio-icon")),
        .init(id: "podcast",   titleKey: "source.podcast",   icon: .asset("podcasts-icon")),
        .init(id: "airplay",   titleKey: "source.airplay",   icon: .symbol("airplay.audio")),
        .init(id: "mac",       titleKey: "source.mac",       icon: .asset("macos-icon")),
        .init(id: "cd",        titleKey: "source.cd",        icon: .asset("cd-icon"))
    ]

    static let allIds: [String] = all.map(\.id)

    private static let byId: [String: AudioSourceDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// Sources à afficher, dans l'ordre imposé par le backend (`enabled_apps`).
    /// `enabled_apps` est à la fois le **filtre** et l'**ordre**.
    static func ordered(enabledApps: [String]?) -> [AudioSourceDescriptor] {
        guard let enabledApps else { return all }
        return enabledApps.compactMap { byId[$0] }
    }
}

/// Une fonctionnalité activable (interrupteur), par opposition à une source (sélection).
struct FeatureDescriptor: Identifiable {
    let id: String
    let titleKey: String
    let icon: SourceIcon

    var title: String { L(titleKey) }
}

enum FeatureCatalog {
    static let all: [FeatureDescriptor] = [
        .init(id: "multiroom", titleKey: "feature.multiroom", icon: .asset("multiroom-icon")),
        .init(id: "equalizer", titleKey: "feature.equalizer", icon: .symbol("slider.horizontal.3"))
    ]

    /// Multiroom est affiché par défaut (comportement historique : `?? true`),
    /// l'égaliseur seulement s'il est explicitement listé (`?? false`).
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
