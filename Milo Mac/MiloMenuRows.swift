import SwiftUI

/// Les lignes du menu, en SwiftUI.
///
/// Chacune est hébergée dans son propre `NSMenuItem.view` (voir `MenuBarShell`). Le menu
/// lui-même est un `NSMenu` natif : les séparateurs, le chrome, l'ombre et l'animation
/// viennent du système. On ne dessine ici que ce que le natif ne sait pas faire dans un
/// menu — un slider, des pastilles d'icône, des spinners, des interrupteurs, et les titres
/// (voir `MenuTitle`, l'en-tête natif ne convenant pas).
///
/// Corollaire : une vue personnalisée n'hérite pas de la surbrillance du menu, elle doit
/// donc gérer son survol elle-même (`MenuRowContainer`).
///
/// Ces vues observent `MiloStore` : tant que le menu est ouvert, elles se re-rendent
/// toutes seules quand le backend pousse un nouvel état.

/// Géométrie des lignes, relevée au pixel sur le panneau **Bluetooth** natif (capture 2x,
/// décalages comptés depuis le bord gauche du menu) :
///
///   titre             16 pt
///   pastille d'icône  19 pt
///   libellé           49 pt   ( = 19 + pastille de 26 + 4 d'écart )
///
/// NSMenu dimensionne le menu sur son item le plus large.
enum MenuRowMetrics {
    static let width: CGFloat = 264

    // Ces valeurs sont désormais les valeurs RÉELLES : le contenu vit dans une NSPanel
    // qu'on dessine soi-même, pas dans un NSMenu. (Un NSMenu ajoutait son propre retrait
    // autour des vues d'items, ce qui obligeait à pré-compenser — piège désormais éteint.)

    /// Décalage du texte des titres et en-têtes.
    static let textInset: CGFloat = 15

    /// Décalage du contenu des lignes (la pastille d'icône). Mesuré sur « Son » : 14 pt —
    /// soit un point à GAUCHE du texte des titres (15 pt). Ce débord est volontaire : il
    /// aligne optiquement le cercle, dont les bords fuient, sur les lettres à fût droit.
    static let contentInset: CGFloat = 14

    /// Retrait au-dessus du titre, sous le bord du panneau.
    static let titleTopInset: CGFloat = 16.5

    /// Retrait vertical d'une ligne. Le pas entre deux lignes vaut `iconSize + 2 ×` cette
    /// valeur : 26 + 6,5 = 32,5 pt, le pas mesuré sur Bluetooth.
    static let rowVerticalPadding: CGFloat = 3.25

    /// Retrait de la surbrillance au survol par rapport au bord de la ligne.
    static let highlightInset: CGFloat = 5

    /// Écart entre la pastille et le libellé.
    static let iconTextGap: CGFloat = 4

    static let iconSize: CGFloat = 26

    /// Couleur de la pastille active.
    ///
    /// `Color.accentColor` seul rend trop foncé : mesuré à travers le verre sur fond blanc,
    /// il donne RGB(52, 120, 246) là où « Son » affiche RGB(63, 143, 247).
    ///
    /// On l'éclaircit vers un **cyan clair**, et non vers le blanc : le blanc fait monter le
    /// rouge bien plus vite que le vert (mesuré à 12 % : RGB(79, 138, 249) — rouge trop haut
    /// de 16). Il faut surtout du vert, donc du cyan. L'accent système reste la base : la
    /// couleur suit toujours le réglage de l'utilisateur.
    static let activeCircleColor = Color.accentColor
        .mix(with: Color(red: 0.2, green: 1, blue: 1), by: 0.18)

    /// Taille des deux icônes de haut-parleur qui encadrent le slider.
    static let sliderIconSize: CGFloat = 13

    /// Écart entre une icône et le rail.
    static let sliderIconGap: CGFloat = 6
}

/// Géométrie du panneau lui-même, relevée sur « Son » (captures 2x, sur fonds unis).
enum PanelMetrics {
    /// Rayon des coins : 36 px en 2x sur le panneau Son, contre 29 px pour un NSMenu —
    /// c'est l'écart que l'œil repère immédiatement.
    static let cornerRadius: CGFloat = 18

    /// Écart entre le bas de la barre des menus et le haut du panneau. Mesuré sur « Son » :
    /// 0,5 pt — le panneau est quasiment collé sous la barre.
    static let topGap: CGFloat = 0.5

    /// Fondus d'apparition et de disparition, comme « Son » : vif à l'ouverture, plus lent
    /// à la fermeture.
    static let fadeInDuration: TimeInterval = 0.10
    static let fadeOutDuration: TimeInterval = 0.22

    /// Marge minimale avec le bord de l'écran.
    static let screenEdgeMargin: CGFloat = 8

    // MARK: Ombre portée
    //
    // Mesurée sur fond blanc : celle de « Son » porte à 48,5 pt en n'assombrissant le blanc
    // que de 48 au bord. L'ombre par défaut de NSWindow porte à 15,5 pt et assombrit de 72 —
    // trois fois trop courte et bien trop dure. D'où une ombre dessinée à la main.

    static let shadowRadius: CGFloat = 23
    static let shadowOpacity: Float = 0.32
    static let shadowOffsetY: CGFloat = 3

    /// Marge transparente autour du panneau, pour que l'ombre ait la place de s'étaler.
    /// Doit dépasser `shadowRadius + shadowOffsetY`.
    static let shadowMargin: CGFloat = 60
}

// MARK: - Titres

/// Titre du menu et en-têtes de section.
///
/// Dessinés à la main, et non avec `NSMenuItem.sectionHeader(title:)` : l'en-tête natif
/// d'un NSMenu rend **tout** en gris et petit, alors que les modules système (Son,
/// Bluetooth, Wi-Fi) distinguent leur titre de leurs sections. Valeurs relevées au pixel
/// sur le panneau « Son » (captures en 2x) :
///
///                        capitale   pic d'encre   densité du trait
///   titre « Son »          21 px       232          0,47   → blanc, gras
///   en-tête « Sortie »     18 px       173          0,49   → gris, gras
///   libellé de ligne       19 px       232          0,41   → blanc, normal
///
/// Autrement dit : le titre est à la taille des libellés mais en gras ; l'en-tête est plus
/// petit, gris, et gras lui aussi.
struct MenuTitle: View {
    let text: String

    var body: some View {
        Text(text)
            // `.semibold`, pas `.bold` : en gras, le contrepoinçon du « o » se referme et
            // le titre ne ressemble plus à « Bluetooth » ou « Son ».
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, MenuRowMetrics.textInset)
            .padding(.top, MenuRowMetrics.titleTopInset)
            .padding(.bottom, 2)
            .frame(width: MenuRowMetrics.width, alignment: .leading)
    }
}

struct MenuSectionHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, MenuRowMetrics.textInset)
            .padding(.top, 2)
            .padding(.bottom, 2)
            .frame(width: MenuRowMetrics.width, alignment: .leading)
    }
}

// MARK: - Volume

struct VolumeRow: View {
    @Bindable var store: MiloStore

    var body: some View {
        VolumeSlider(
            valueDb: $store.sliderVolumeDb,
            range: store.volumeLimits,
            onChange: { store.setVolume($0) }
        )
        .padding(.horizontal, MenuRowMetrics.contentInset)
        .padding(.vertical, 4)
        .frame(width: MenuRowMetrics.width)
    }
}

// MARK: - Source audio

struct SourceRow: View {
    @Bindable var store: MiloStore
    let source: AudioSourceDescriptor
    var showsChevron: Bool = false
    var onChevron: (() -> Void)? = nil

    @State private var isHovering = false

    /// La source « Mac » a besoin du driver roc-vad. Sans lui, la ligne reste visible mais
    /// renvoie vers les Réglages plutôt que d'échouer en silence.
    private var needsSetup: Bool {
        source.id == "mac" && !store.isRocVADReady
    }

    private var isActive: Bool {
        store.state?.activeSource == source.id
    }

    /// Spinner si le backend signale une transition vers cette source, OU si un clic local
    /// vient de partir (loadingStates, posé avant la requête HTTP).
    private var isLoading: Bool {
        let transitioning = (store.state?.sourceState.lowercased() == "starting")
            || (store.state?.transitioning ?? false)
        return (transitioning && isActive) || store.loadingStates[source.id] == true
    }

    var body: some View {
        MenuRowContainer(isHovering: $isHovering, action: activate) {
            RowIcon(icon: source.icon, isActive: isActive)

            VStack(alignment: .leading, spacing: 1) {
                Text(source.title)
                    .font(.system(size: 13))
                    .lineLimit(1)

                if needsSetup {
                    Text(L("source.mac.needs_setup"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else if showsChevron {
                Button { onChevron?() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .opacity(needsSetup ? 0.55 : 1)
    }

    private func activate() {
        if needsSetup {
            SettingsWindowPresenter.show(store: store)
        } else {
            store.selectSource(source.id)
        }
    }
}

// MARK: - Fonctionnalité (interrupteur)

struct FeatureRow: View {
    @Bindable var store: MiloStore
    let feature: FeatureDescriptor

    private var isLoading: Bool { store.loadingStates[feature.id] == true }
    private var isOn: Bool { store.displayedToggleState(feature.id) }

    var body: some View {
        HStack(spacing: MenuRowMetrics.iconTextGap) {
            RowIcon(icon: feature.icon, isActive: isOn)

            Text(feature.title)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer(minLength: 4)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .padding(.trailing, 4)
            }

            Toggle("", isOn: Binding(
                get: { isOn },
                set: { _ in store.toggleFeature(feature.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(isLoading)
        }
        .padding(.horizontal, MenuRowMetrics.contentInset)
        .padding(.vertical, MenuRowMetrics.rowVerticalPadding)
        .frame(width: MenuRowMetrics.width)
    }
}

// MARK: - Station radio (sous-menu)

struct RadioStationRow: View {
    @Bindable var store: MiloStore
    let station: RadioStation

    @State private var isHovering = false

    private var isPlaying: Bool { store.playingRadioStationId == station.id }
    private var isLoading: Bool { store.radioStationLoadingId == station.id }

    var body: some View {
        MenuRowContainer(isHovering: $isHovering, action: toggle) {
            Text(station.name)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer(minLength: 8)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else if isPlaying {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toggle() {
        if isPlaying {
            store.stopRadioPlayback(station.id)
        } else {
            store.playRadioStation(station.id)
        }
    }
}

/// Ligne affichée quand Radio n'a aucun favori.
struct RadioEmptyRow: View {
    var body: some View {
        Text(L("radio.noFavorites"))
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, MenuRowMetrics.contentInset)
            .padding(.vertical, 5)
            .frame(width: MenuRowMetrics.width, alignment: .leading)
    }
}

// MARK: - État déconnecté

struct DisconnectedRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(L("status.disconnected"))
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.horizontal, MenuRowMetrics.contentInset)
        .padding(.vertical, 5)
        .frame(width: MenuRowMetrics.width, alignment: .leading)
    }
}

// MARK: - Briques communes

/// Ligne cliquable avec sa surbrillance au survol.
///
/// NSMenu ne met en surbrillance que ses propres items — une vue personnalisée doit gérer
/// son survol elle-même. C'est le prix à payer pour qu'un clic ne referme PAS le menu, ce
/// qui est indispensable ici : on veut afficher le spinner de transition sur place.
private struct MenuRowContainer<Content: View>: View {
    @Binding var isHovering: Bool
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: MenuRowMetrics.iconTextGap) {
                content
            }
            // La surbrillance est en retrait de `highlightInset` ; le contenu doit malgré
            // tout commencer à `contentInset` du bord du menu, d'où la différence.
            .padding(.leading, MenuRowMetrics.contentInset - MenuRowMetrics.highlightInset)
            .padding(.trailing, 8)
            .padding(.vertical, MenuRowMetrics.rowVerticalPadding)
            .frame(width: MenuRowMetrics.width - 2 * MenuRowMetrics.highlightInset,
                   alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MenuRowMetrics.highlightInset)
        .onHover { isHovering = $0 }
    }
}

/// Pastille d'icône : accent quand actif, gris sinon — le même langage visuel que la
/// section « Sortie » du panneau Son.
private struct RowIcon: View {
    let icon: SourceIcon
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? AnyShapeStyle(MenuRowMetrics.activeCircleColor)
                               : AnyShapeStyle(.tertiary))

            icon.image
                .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        }
        .frame(width: MenuRowMetrics.iconSize, height: MenuRowMetrics.iconSize)
    }
}


// MARK: - Retour depuis la liste radio

struct RadioBackRow: View {
    let onBack: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onBack) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text(L("source.radio"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MenuRowMetrics.textInset)
        .padding(.top, MenuRowMetrics.titleTopInset)
        .frame(width: MenuRowMetrics.width, alignment: .leading)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Pied (option-clic)

struct FooterRow: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, MenuRowMetrics.contentInset - MenuRowMetrics.highlightInset)
            .padding(.vertical, 5)
            .frame(width: MenuRowMetrics.width - 2 * MenuRowMetrics.highlightInset,
                   alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MenuRowMetrics.highlightInset)
        .onHover { isHovering = $0 }
    }
}
