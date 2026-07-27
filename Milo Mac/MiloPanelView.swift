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

    /// Ce que l'écran peut afficher sous la barre des menus. Vient de `MenuBarShell`, qui seul
    /// connaît l'écran où le panneau s'ouvre (voir `PanelMetrics.maxContentHeight`).
    var maxContentHeight: CGFloat

    /// Hauteur de la couche PRIMAIRE : la route affichée au repos, la route SORTANTE pendant une
    /// transition. Mesurée en continu — c'est elle qui donne la hauteur de départ du morphing.
    @State private var activeHeight: CGFloat = 0

    /// Hauteur NATURELLE de la couche entrante (celle en overlay) : la CIBLE du morphing. Nulle
    /// tant qu'elle n'a pas été mesurée — le morphing tient alors sa hauteur de départ, le temps
    /// d'une passe de disposition (invisible : la courbe démarre à plat).
    @State private var incomingHeight: CGFloat = 0

    /// Hauteur affichée à l'instant du clic, figée pour toute la durée du morphing.
    ///
    /// Un instantané, et non `activeHeight` lue en direct : dès que la transition s'arme, le
    /// `fixedSize` de la couche primaire fait sauter sa mesure à sa hauteur NATURELLE (la liste des
    /// stations, plafonnée à l'écran, mesure d'un coup tout son contenu).
    @State private var morphFromHeight: CGFloat = 0

    var body: some View {
        // Pendant la transition, la couche primaire est celle qu'on QUITTE et la couche entrante
        // est posée en overlay. Ce sens-là, et non l'inverse, préserve l'identité SwiftUI de la vue
        // qu'on quitte : la liste des stations garde son défilement et ses logos déjà chargés
        // pendant qu'elle s'efface. (Un overlay ne participe pas à la taille de son hôte — ce qui
        // tombe bien, la hauteur étant ici pilotée à la main.)
        let outgoing = store.outgoingPanelRoute

        return layer(outgoing ?? store.panelRoute)
            .measuringHeight { activeHeight = $0 }
            .opacity(outgoingOpacity)
            .overlay(alignment: .top) {
                if outgoing != nil {
                    layer(store.panelRoute)
                        .measuringHeight { incomingHeight = $0 }
                        .opacity(incomingOpacity)
                }
            }
            // Hauteur pilotée à la main PENDANT la transition seulement (nulle au repos, où la
            // fenêtre suit comme avant la taille naturelle du contenu).
            .frame(height: morphHeight, alignment: .top)
            // Rien n'est cliquable pendant la transition : les deux couches sont à l'écran, et un
            // clic sur une ligne fantôme n'aurait aucun sens.
            .allowsHitTesting(!store.isRouteMorphing)
        // Le panneau ne peut pas être plus haut que l'écran. La fenêtre suivant la taille
        // intrinsèque du contenu, c'est ici — et non dans `positionPanel` — que la croissance
        // doit être bornée : sinon elle sort par le bas.
        //
        // Le plafond porte sur le contenu ENTIER plutôt que sur la seule liste des stations,
        // car c'est le total qui doit tenir. Il se répercute tout seul sur la ScrollView de
        // `radioContent`, seul élément élastique du panneau : mesuré à 40 stations (880 pt de
        // contenu, plafond 400), la ScrollView est bien RÉTRÉCIE à 357 pt — elle défile, elle
        // ne déborde pas. Quand tout tient, le plafond ne prend pas la main et la hauteur reste
        // celle du contenu, au point près (vérifié : 153 pt à 5 stations, avec ou sans plafond).
        .frame(maxHeight: maxContentHeight, alignment: .top)
        // Le contenu épouse la forme du panneau. Sans ça, une station à demi défilée serait
        // coupée par le bord RECTANGLE de la ScrollView : au ras du bord bas c'est pareil, mais
        // dans les coins arrondis son texte déborderait du verre. On ne s'en remet pas au verre
        // pour masquer — sa couche est explicitement en `masksToBounds = false` pour laisser
        // passer l'ombre (voir `MenuBarShell.setupPanel`).
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        // Aucun fond ici : c'est le NSGlassEffectView de MenuBarShell qui peint le verre et
        // découpe les coins. En ajouter un ici le doublerait et masquerait le verre.
        // La fenêtre est simplement masquée (orderOut), pas détruite : `onDisappear` ne se
        // déclenche pas. On remet la vue à sa racine en observant la fermeture, sinon le
        // panneau se rouvrirait sur la liste des stations.
        .onChange(of: store.isPanelOpen) { _, isOpen in
            if !isOpen {
                // Retour à la racine SANS transition : le panneau n'est plus visible, et on ne veut
                // pas rouvrir sur une animation à moitié jouée. Même raison pour l'accordéon.
                store.resetPanelRoute()
                morphFromHeight = 0
                incomingHeight = 0
                store.multiroomExpanded = false
                store.multiroomRevealFraction = 0
            }
        }
        .onChange(of: store.canShowRadioStations) { _, canShow in
            if !canShow, store.panelRoute == .radioStations { navigate(to: .root) }
        }
        // Le multiroom a été coupé (ou la liste s'est vidée) pendant que la sous-section
        // était ouverte : on la referme, sinon elle resterait dépliée sur du vide.
        .onChange(of: store.canShowMultiroom) { _, canShow in
            if !canShow { store.multiroomExpanded = false }
        }
    }

    // MARK: - Couches et transition

    /// Le contenu d'une route, à sa géométrie propre.
    ///
    /// Pendant une transition, la couche est FIGÉE à sa hauteur naturelle (`fixedSize`) et c'est le
    /// cadre extérieur qui la découpe. Sans ça, la ScrollView des stations — seul élément élastique
    /// du panneau — se laisserait comprimer à la hauteur interpolée, et la mesure de sa hauteur
    /// naturelle (la CIBLE du morphing) vaudrait toujours la hauteur de départ : le panneau ne
    /// bougerait jamais. Une liste plus haute que l'écran s'affiche donc pendant la transition
    /// rognée à son sommet — exactement ce qu'on voit d'une liste défilante au repos.
    @ViewBuilder
    private func layer(_ route: PanelRoute) -> some View {
        Group {
            switch route {
            case .root:
                // FIXÉ à sa hauteur naturelle : sans quoi, si la fenêtre est un instant plus
                // haute que le contenu (léger retard de l'auto-dimensionnement pendant le repli
                // de l'accordéon multiroom), le VStack distribue le surplus aux lignes rendues
                // verticalement élastiques par leur bouton-chevron (`.frame(maxHeight: .infinity)`)
                // — et la ligne Multiroom « gonflait » à la fermeture. Le contenu racine n'a aucun
                // élément qui doive s'étirer ; on le borne donc à son idéal.
                VStack(alignment: .leading, spacing: 0) {
                    rootContent
                }
                .fixedSize(horizontal: false, vertical: true)
            case .radioStations:
                // PAS de `fixedSize` propre ici : la ScrollView des stations est l'unique élément
                // élastique du panneau, elle doit pouvoir rétrécir pour défiler (voir le plafond
                // `maxHeight` du body).
                VStack(alignment: .leading, spacing: 0) {
                    radioContent
                }
            }
        }
        .frame(width: MenuRowMetrics.width)
        .padding(.bottom, bottomInset(for: route))
        .fixedSize(horizontal: false, vertical: store.isRouteMorphing)
    }

    /// Change de route en armant le morphing (le timer, lui, vit dans `MenuBarShell`).
    private func navigate(to route: PanelRoute) {
        // Instantané pris AVANT la bascule, pendant que la mesure de la couche primaire vaut encore
        // la hauteur AFFICHÉE (voir `morphFromHeight`). `morphHeight` d'abord : si une transition
        // est déjà en vol, on repart de la hauteur atteinte, sans à-coup.
        morphFromHeight = morphHeight ?? activeHeight
        incomingHeight = 0
        store.navigate(to: route)
    }

    /// Hauteur imposée au contenu pendant la transition ; `nil` au repos, où la fenêtre suit la
    /// hauteur naturelle du contenu comme avant.
    private var morphHeight: CGFloat? {
        guard store.isRouteMorphing, morphFromHeight > 0 else { return nil }
        // La cible est la hauteur naturelle de la couche entrante, plafonnée par l'écran —
        // exactement ce que la disposition élastique lui donnera au repos, si bien que la dernière
        // image du morphing et l'état final coïncident.
        let target = incomingHeight > 0 ? min(incomingHeight, maxContentHeight) : morphFromHeight
        return morphFromHeight + (target - morphFromHeight) * store.routeMorphFraction
    }

    /// Les deux fondus se croisent à peine : la vue qu'on quitte s'efface d'abord, la nouvelle
    /// arrive ensuite. Superposées à mi-course, les deux listes rendraient le panneau illisible.
    ///
    /// Les seuils portent sur une fraction DÉJÀ lissée (le timer applique la courbe) : ils se
    /// lisent donc en avancement visuel du morphing, non en temps.
    private var outgoingOpacity: Double {
        guard store.isRouteMorphing else { return 1 }
        return Double(max(0, 1 - store.routeMorphFraction / PanelMetrics.routeFadeOutEnd))
    }

    private var incomingOpacity: Double {
        guard store.isRouteMorphing else { return 1 }
        let start = PanelMetrics.routeFadeInStart
        return Double(min(1, max(0, (store.routeMorphFraction - start) / (1 - start))))
    }

    /// Bascule la sous-section multiroom. À l'ouverture, on force un re-fetch de la structure
    /// pour partir de données fraîches (un client a pu passer en ligne depuis la connexion).
    ///
    /// On ne fait QUE basculer l'état : l'animation est pilotée par `MenuBarShell`, qui observe
    /// `multiroomExpanded` et fait varier `multiroomRevealFraction` via un timer (voir le store).
    /// Surtout PAS de `withAnimation` ici — cela rapporterait la taille finale d'un coup à
    /// `NSHostingController`, qui ferait sauter la fenêtre.
    private func toggleMultiroom() {
        if !store.multiroomExpanded {
            store.loadMultiroomState()
        }
        store.multiroomExpanded.toggle()
    }

    /// Retrait sous la dernière ligne, au-dessus du bord bas du panneau.
    ///
    /// Le pied (option-clic) finit sur du texte, comme « Son » ; sans lui, la dernière ligne
    /// est Égaliseur — une ligne à pastille, qui demande un peu plus d'air.
    ///
    /// NUL dans la liste des stations : c'est la ScrollView qui porte ce retrait, à l'intérieur
    /// de son contenu défilant (voir `radioContent`). Posé ici, il aurait arrêté la ScrollView
    /// avant le bord du panneau — et la station coupée par le défilement l'aurait été en
    /// laissant du vide sous elle, au lieu de disparaître sous le bord.
    private func bottomInset(for route: PanelRoute) -> CGFloat {
        switch route {
        case .root:
            store.showsPreferences ? PanelMetrics.bottomInset : PanelMetrics.bottomInsetIconRow
        case .radioStations:
            stations.isEmpty ? PanelMetrics.bottomInset : 0
        }
    }

    /// Les favoris radio, par ordre alphabétique.
    private var stations: [RadioStation] {
        (store.radioFavorites ?? []).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Racine

    @ViewBuilder
    private var rootContent: some View {
        MenuTitle(text: L("menu.title"))

        if store.isConnected {
            if let info = store.displayedNowPlaying {
                NowPlayingAccordion(store: store, info: info)
            }
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
                        onChevron: { navigate(to: .radioStations) }
                    )
                }
            }

            let features = FeatureCatalog.enabled(enabledApps: store.enabledApps)
            if !features.isEmpty {
                PanelDivider()
                MenuSectionHeader(text: L("menu.features.title"))

                ForEach(features) { feature in
                    let isMultiroom = feature.id == "multiroom"
                    FeatureRow(
                        store: store,
                        feature: feature,
                        showsChevron: isMultiroom && store.canShowMultiroom,
                        isExpanded: isMultiroom && store.multiroomExpanded,
                        onChevron: isMultiroom ? { toggleMultiroom() } : nil
                    )

                    // La sous-section se glisse JUSTE sous la ligne Multiroom (et non en fin
                    // de liste) — l'accordéon s'ouvre là où on a cliqué, comme sous AirPods.
                    //
                    // La ligne Multiroom (au-dessus) est une vraie ligne du VStack : elle ne
                    // bouge pas. Seul l'accordéon en dessous s'ouvre/se ferme (voir
                    // `MultiroomAccordion`). Le pied (Égaliseur, réglages) est poussé/rappelé
                    // par la hauteur de l'accordéon.
                    if isMultiroom, store.canShowMultiroom {
                        MultiroomAccordion(store: store)
                    }
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
        RadioBackRow { navigate(to: .root) }

        PanelDivider()

        if stations.isEmpty {
            RadioEmptyRow()
        } else {
            // La seule liste non bornée du panneau — elle vaut ce que Milō a de favoris. Elle
            // défile donc dès qu'elle ne tient plus sous l'écran, et absorbe ainsi le plafond
            // posé sur le body. En deçà, la ScrollView vaut exactement son contenu : le panneau
            // garde sa hauteur naturelle, et la barre de défilement ne se montre pas.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(stations) { station in
                        RadioStationRow(store: store, station: station)
                    }
                }
            }
            // La ScrollView descend jusqu'au BORD du panneau (`bottomInset` est nul sur cette
            // route) : le retrait bas est porté ici, DANS le contenu défilant. Une station à
            // demi défilée est donc coupée par le bord du panneau, et non par une limite
            // intérieure qui aurait laissé du vide sous le texte tronqué. Au repos, la dernière
            // station retrouve exactement l'air qu'elle avait : mesuré, la marge compte dans la
            // hauteur idéale de la ScrollView (153 → 163 pt pour 10 pt de marge).
            .contentMargins(.bottom, PanelMetrics.bottomInset, for: .scrollContent)
            // Pas d'élasticité quand tout tient : sans ça la liste rebondit sous la molette
            // alors qu'il n'y a rien à faire défiler.
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Accordéon multiroom : la sous-section zones/clients dont la hauteur s'ouvre/se ferme.
///
/// La sous-section est TOUJOURS montée (tant que le multiroom est dispo) et gardée à sa taille
/// naturelle par `fixedSize` ; un GeometryReader en mesure la hauteur (elle ne dépend que du
/// nombre de zones/clients, jamais de la fenêtre — aucune boucle). Le conteneur affiche cette
/// hauteur MULTIPLIÉE par `multiroomRevealFraction` (0 replié → 1 déplié), animée par un timer
/// dans `MenuBarShell`. `clipped()` révèle le contenu du haut vers le bas.
///
/// Sous-vue isolée exprès : elle seule lit `multiroomRevealFraction`, donc elle seule se
/// re-rend à chaque pas du timer — pas tout le panneau.
private struct MultiroomAccordion: View {
    @Bindable var store: MiloStore
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        MultiroomSection(store: store)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { naturalHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in naturalHeight = h }
                }
            )
            .frame(height: naturalHeight * store.multiroomRevealFraction, alignment: .top)
            .clipped()
            // Fondu synchronisé avec le dévoilement : les cartes apparaissent/disparaissent en
            // opacité en même temps que la hauteur s'ouvre/se ferme. La fraction va déjà de 0 à 1
            // (et retour) selon la courbe du timer.
            .opacity(store.multiroomRevealFraction)
            // Cible cliquable seulement une fois franchement ouvert, pour ne pas capter un clic
            // sur des cartes encore quasi refermées.
            .allowsHitTesting(store.multiroomRevealFraction > 0.99)
    }
}

/// Repli/déploiement de la ligne « en cours », même mécanique que `MultiroomAccordion` : la
/// ligne reste montée à sa hauteur naturelle, et un `frame(height:)` multiplié par
/// `nowPlayingRevealFraction` la montre/masque en douceur — piloté par un timer dans
/// `MenuBarShell`, jamais par `withAnimation` (voir *Panel height animations* dans CLAUDE.md).
///
/// Reçoit `store.displayedNowPlaying`, PAS `store.nowPlaying` : ce dernier retombe à nil dès
/// que la lecture s'arrête, avant même que le repli n'ait commencé à s'animer — la ligne
/// perdrait son contenu en même temps qu'elle est censée se refermer dessus.
private struct NowPlayingAccordion: View {
    @Bindable var store: MiloStore
    let info: NowPlayingInfo
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        NowPlayingRow(store: store, info: info)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { naturalHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in naturalHeight = h }
                }
            )
            .frame(height: naturalHeight * store.nowPlayingRevealFraction, alignment: .top)
            .clipped()
            .opacity(store.nowPlayingRevealFraction)
            // Boutons cliquables seulement une fois franchement déployée — même garde que
            // l'accordéon multiroom, pour ne pas capter un clic pendant le repli.
            .allowsHitTesting(store.nowPlayingRevealFraction > 0.99)
    }
}

extension View {
    /// Rapporte la hauteur de la vue sans influer sur sa disposition — un `background` transparent
    /// ne propose rien, il se contente d'épouser son hôte. Même motif que `MultiroomAccordion`.
    func measuringHeight(_ report: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { report(geo.size.height) }
                    .onChange(of: geo.size.height) { _, height in report(height) }
            }
        )
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

