import SwiftUI

/// Le contenu du panneau : titre, slider, sources, fonctionnalités, pied.
///
/// Pourquoi une vue de panneau et non un NSMenu ? Parce qu'un `NSMenu` peint son propre
/// chrome — rayon des coins et liseré — et qu'aucune API publique ne permet de le changer.
/// Mesuré : un NSMenu a des coins de 14,5 pt et un liseré marqué, là où les modules système
/// (Son, Bluetooth) ont des coins de 18 pt et un bord discret. Pour être iso, il faut
/// dessiner sa propre fenêtre. Voir `MenuBarShell`.
struct MiloPanelView: View {
    @Bindable var store: MiloStore

    /// Vue courante : racine, ou liste des stations radio. Un panneau n'a pas de sous-menus
    /// natifs — Radio se déplie donc sur place.
    @State private var route: Route = .root

    private enum Route: Equatable {
        case root
        case radioStations
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch route {
            case .root:
                rootContent
            case .radioStations:
                radioContent
            }
        }
        .frame(width: MenuRowMetrics.width)
        // Le pied (option-clic) finit sur du texte, comme « Son » ; sans lui, la dernière
        // ligne est Égaliseur — une ligne à pastille, qui demande un peu plus d'air.
        .padding(.bottom, store.showsPreferences ? PanelMetrics.bottomInset
                                                 : PanelMetrics.bottomInsetIconRow)
        // Aucun fond ici : c'est le NSGlassEffectView de MenuBarShell qui peint le verre et
        // découpe les coins. En ajouter un ici le doublerait et masquerait le verre.
        // La fenêtre est simplement masquée (orderOut), pas détruite : `onDisappear` ne se
        // déclenche pas. On remet la vue à sa racine en observant la fermeture, sinon le
        // panneau se rouvrirait sur la liste des stations.
        .onChange(of: store.isPanelOpen) { _, isOpen in
            if !isOpen { route = .root }
        }
        .onChange(of: store.canShowRadioStations) { _, canShow in
            if !canShow, route == .radioStations { route = .root }
        }
    }

    // MARK: - Racine

    @ViewBuilder
    private var rootContent: some View {
        MenuTitle(text: L("menu.title"))

        if store.isConnected {
            VolumeRow(store: store)

            let sources = AudioSourceCatalog.ordered(enabledApps: store.enabledApps)
            if !sources.isEmpty {
                PanelDivider()
                MenuSectionHeader(text: L("menu.audio_sources.title"))

                // L'ordre vient d'enabled_apps (backend) — jamais codé en dur ici.
                ForEach(sources) { source in
                    SourceRow(
                        store: store,
                        source: source,
                        showsChevron: source.id == "radio" && store.canShowRadioStations,
                        onChevron: { route = .radioStations }
                    )
                }
            }

            let features = FeatureCatalog.enabled(enabledApps: store.enabledApps)
            if !features.isEmpty {
                PanelDivider()
                MenuSectionHeader(text: L("menu.features.title"))

                ForEach(features) { feature in
                    FeatureRow(store: store, feature: feature)
                }
            }
        } else {
            DisconnectedRow()
        }

        // Le pied n'apparaît qu'à l'option-clic, comme l'ancien menu de préférences.
        if store.showsPreferences {
            PanelDivider()
            FooterRow(title: L("config.settings")) {
                SettingsWindowPresenter.show(store: store)
            }
            FooterRow(title: L("config.quit")) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: - Stations radio

    @ViewBuilder
    private var radioContent: some View {
        RadioBackRow { route = .root }

        PanelDivider()

        let stations = (store.radioFavorites ?? []).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if stations.isEmpty {
            RadioEmptyRow()
        } else {
            ForEach(stations) { station in
                RadioStationRow(store: store, station: station)
            }
        }
    }
}

/// Filet de séparation, calé sur les mêmes retraits que le contenu.
struct PanelDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, MenuRowMetrics.textInset)
            .padding(.vertical, 5)
    }
}

