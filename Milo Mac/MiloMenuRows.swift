import SwiftUI

/// Les lignes du panneau, en SwiftUI.
///
/// Le panneau n'est pas un NSMenu mais une NSPanel qu'on dessine soi-même (`MenuBarShell`
/// dit pourquoi) : RIEN ne vient du système ici — ni les séparateurs, ni les titres, ni le
/// chrome, ni la surbrillance au survol. Tout ce qui suit est donc dessiné à la main, y
/// compris ce qu'un menu natif aurait donné gratuitement.
///
/// Corollaire : chaque ligne gère son propre survol (`MenuRowContainer`). C'est le prix de
/// la fenêtre — et sa raison d'être : un clic n'y referme rien, on peut donc afficher le
/// spinner de transition sur place.
///
/// Ces vues observent `MiloStore` : tant que le panneau est ouvert, elles se re-rendent
/// toutes seules quand le backend pousse un nouvel état.

/// Géométrie des lignes, relevée au pixel sur le panneau **Bluetooth** natif (capture 2x,
/// décalages comptés depuis le bord gauche du menu) :
///
///   titre             16 pt
///   pastille d'icône  19 pt
///   libellé           49 pt   ( = 19 + pastille de 26 + 4 d'écart )
enum MenuRowMetrics {
    /// Largeur du panneau. Fixée, et non déduite du contenu : un NSMenu se dimensionnait sur
    /// son item le plus large, une fenêtre qu'on dessine soi-même n'a pas cette règle — sans
    /// cette valeur, le panneau se rétrécirait sur ses libellés, qui changent avec la langue.
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
    ///
    /// Réglé par comparaison d'ENCRE à ENCRE avec « Son », seule comparaison valable : entre
    /// le haut d'une vue `Text` et le haut des capitales il y a l'interligne interne de la
    /// police, qu'aucun padding déclaré ne dit.
    ///
    /// Mesuré : le haut des capitales de « Son » est à 16,5 pt du bord du panneau ; le nôtre
    /// tombait à 20,0 — d'où 16,5 − 3,5 = 13. (Ne pas comparer le haut de l'encre des deux
    /// chaînes : « Milō » a une hampe (`l`) et un macron qui montent plus haut qu'une
    /// capitale. On compare la capitale, ou la ligne de base — les deux donnent 3,5.)
    static let titleTopInset: CGFloat = 13

    /// Retrait vertical d'une ligne. Le pas entre deux lignes vaut `iconSize + 2 ×` cette
    /// valeur : 26 + 6 = 32 pt.
    ///
    /// Valait 3,25 (soit un pas de 32,5), sur la foi d'un commentaire qui disait l'avoir
    /// relevé sur Bluetooth. Re-mesuré depuis, par l'écart entre centres de pastilles — une
    /// mesure qui ne dépend ni du survol ni d'un seuil, et qui retrouve bien les 32,0 déjà
    /// connus de Son quand on la lui applique :
    ///
    ///   Son        32,0 · 32,0
    ///   Bluetooth  32,0 × 8 d'affilée
    ///
    /// Les lignes sont jointives (les boîtes de survol se touchent) : pas = hauteur de boîte.
    static let rowVerticalPadding: CGFloat = 3

    /// Retrait de la surbrillance au survol par rapport au bord de la ligne.
    static let highlightInset: CGFloat = 5

    /// Retrait vertical d'une ligne de TEXTE — le pied (Paramètres, Quitter) et le retour
    /// depuis la liste radio. Ces lignes n'ont pas de pastille : leur boîte de survol se cale
    /// sur le texte seul, et non sur `iconSize` comme celle d'une ligne à pastille.
    static let textRowVerticalPadding: CGFloat = 5

    /// Rayon des coins de la surbrillance au survol.
    ///
    /// Relevé sur « Son » en profilant le coin haut-gauche du masque de survol (obtenu par
    /// différence entre deux captures, pointeur garé / pointeur sur la ligne) : son bord
    /// gauche n'est atteint qu'à 9,0 pt du haut de la boîte, contre 3,5 pour notre rayon de 5.
    ///
    /// Attention, ces 9,0 ne SONT pas le rayon : en `.continuous` (squircle), la courbe
    /// s'étire au-delà du rayon nominal, et le rapport entre les deux n'est PAS constant
    /// (mesuré sur notre propre rendu : 5 → 3,5, mais 13 → 12,0). On calibre donc sur ces
    /// deux points — L(0) ≈ 1,0625·r − 1,81 — d'où 10 pour viser 9,0.
    ///
    /// Vérifié ensuite profil contre profil, ligne par ligne, et non sur un seul chiffre.
    static let rowHoverCornerRadius: CGFloat = 10

    /// Écart entre la pastille et le libellé.
    ///
    /// Mesuré sur « Son » : l'encre du libellé commence à 49,0 pt du bord du panneau. La
    /// pastille finissant à 40 (14 + 26), il reste 9,0 pt — dont ~0,5 de chasse à gauche du
    /// glyphe, d'où 8,5.
    ///
    /// Valait 4, ce qui collait le texte à la pastille (encre à 44,5). L'ancien commentaire
    /// de ce fichier faisait son calcul avec une pastille à 19 pt (49 = 19 + 26 + 4), alors
    /// que `contentInset` vaut 14 : c'est de là que venait l'erreur.
    static let iconTextGap: CGFloat = 8.5

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

    /// Fond d'une ligne survolée.
    ///
    /// Et non `.selection`, qui est teinté d'accent (bleu) : ce n'est pas ce que font Son ni
    /// Bluetooth. Relevé en différenciant deux captures du MÊME panneau, l'une pointeur garé
    /// au loin, l'autre pointeur sur la ligne. La surbrillance étant une couche translucide,
    /// `sortie = (1−a)·fond + a·C`, on retrouve `a` et `C` en régressant l'une sur l'autre :
    /// pente 0,9195 et ordonnée 20,43, identiques sur les trois canaux (R² = 0,994 sur des
    /// fonds allant de 8 à 231) — soit du BLANC à 8 %.
    ///
    /// C'est exactement `secondarySystemFill` (blanc à 7,84 % en sombre). On prend la couleur
    /// sémantique plutôt que le littéral : en apparence claire elle bascule toute seule sur du
    /// NOIR à 7,84 %, là où un blanc codé en dur serait invisible.
    static let rowHoverFill = Color(nsColor: .secondarySystemFill)

    /// Taille des deux icônes de haut-parleur qui encadrent le slider.
    ///
    /// Cette fois-ci mesurée, et non réglée à l'œil (l'ancienne mesure était cassée). « Son »
    /// utilise les mêmes symboles que nous (`speaker.fill`, `speaker.wave.3.fill`) : l'encre
    /// est donc proportionnelle au corps, et le rapport se lit directement.
    ///
    ///                        Son          nous à 13      rapport
    ///   speaker.fill        9,0 × 13,5    7,5 × 11,0     1,20 / 1,23
    ///   speaker.wave.3.fill 20,5 × 15,0   17,0 × 12,5    1,21 / 1,20
    ///
    /// Quatre mesures concordantes → 13 × 1,21 ≈ 15,7.
    static let sliderIconSize: CGFloat = 15.5

    /// Écart entre une icône et le rail.
    ///
    /// Ce n'est pas l'écart qu'on VOIT : le `Slider` ajoute ~4,5 pt de marge interne avant
    /// le début du rail. Mesuré, l'écart encre → rail vaut donc `sliderIconGap + 4,5`.
    /// À 4, on lit 8,5 pt à l'écran.
    static let sliderIconGap: CGFloat = 4
}

/// Géométrie du panneau lui-même, relevée sur « Son » (captures 2x, sur fonds unis).
enum PanelMetrics {
    /// Rayon des coins : 36 px en 2x sur le panneau Son, contre 29 px pour un NSMenu —
    /// c'est l'écart que l'œil repère immédiatement.
    static let cornerRadius: CGFloat = 18

    /// Écart entre le bas de la barre des menus et le haut du panneau. Mesuré sur « Son » :
    /// 0,5 pt — le panneau est quasiment collé sous la barre. (Barre des menus : 34 pt ;
    /// haut du panneau « Son » : 34,5 pt.)
    static let topGap: CGFloat = 0.5

    /// Décalage du bord gauche du panneau par rapport à l'ENCRE de l'icône de la barre des
    /// menus.
    ///
    /// Mesuré sur « Son » : encre du glyphe à 1407,5 pt, bord gauche de son panneau à
    /// 1396,0 — soit 11,5 pt à gauche.
    ///
    /// Le système, lui, s'ancre sur le CADRE du bouton (bord du panneau = bord du cadre
    /// − 10 pt ; vérifié sur Son ET sur Bluetooth, dont les cadres n'ont pourtant pas la
    /// même largeur). On ne peut pas reprendre cette règle telle quelle : les boutons
    /// système sont ajustés à leur glyphe, le nôtre non (40 pt de cadre pour 14 pt d'encre).
    /// S'ancrer sur l'encre donne le même résultat À L'ŒIL, qui est ce qu'on cherche.
    static let panelLeftFromIconInk: CGFloat = 11.5

    /// Retrait sous la dernière ligne, au-dessus du bord bas du panneau.
    ///
    /// Mesuré sur « Son » : 5 pt entre le bas de la BOÎTE de la dernière ligne (celle que
    /// dessine la surbrillance) et le bord du panneau.
    ///
    /// Ne vaut que pour une dernière ligne de TEXTE — c'est le seul cas qu'on puisse relever,
    /// Son et Bluetooth finissant tous deux sur un « Réglages… ». Chez nous, c'est le cas
    /// à l'option-clic, quand le pied (Paramètres / Quitter) est affiché.
    static let bottomInset: CGFloat = 5

    /// Retrait sous la dernière ligne quand celle-ci porte une PASTILLE (Égaliseur, sans le
    /// pied) plutôt que du texte.
    ///
    /// Une ligne à pastille est plus haute (32 pt contre ~22) et son disque s'arrête à
    /// `rowVerticalPadding` (3 pt) du bas de sa boîte : à retrait égal, le panneau paraît se
    /// refermer sur le disque. Aucun module système ne finit sur une telle ligne — il n'y a
    /// donc rien à mesurer, et cette valeur est un réglage à l'œil assumé.
    /// (Réglée avec Léo : 8 → 10, soit 13 pt sous le disque d'Égaliseur.)
    static let bottomInsetIconRow: CGFloat = 10

    /// Fondus d'apparition et de disparition, comme « Son » : vif à l'ouverture, plus lent
    /// à la fermeture.
    static let fadeInDuration: TimeInterval = 0.10
    static let fadeOutDuration: TimeInterval = 0.22

    /// Marge minimale avec le bord de l'écran.
    static let screenEdgeMargin: CGFloat = 8

    // MARK: Transition entre routes (racine ↔ stations radio)
    //
    // Le panneau n'a pas de sous-menus natifs : la liste des stations REMPLACE le contenu racine.
    // La bascule est donc un morphing — la hauteur du panneau va de l'une à l'autre pendant que
    // les deux contenus se croisent en fondu. Durée et courbe vivent dans `MenuBarShell`, qui
    // pilote le timer ; ne restent ici que les seuils du fondu, affaire de vue.

    /// Avancement auquel la vue sortante a fini de s'effacer.
    static let routeFadeOutEnd: CGFloat = 0.42

    /// Avancement auquel la vue entrante commence à apparaître. Sous `routeFadeOutEnd`, donc :
    /// les deux se chevauchent d'un cheveu, juste assez pour qu'il n'y ait pas d'instant vide.
    static let routeFadeInStart: CGFloat = 0.34

    /// Hauteur maximale du CONTENU du panneau : tout ce que l'écran peut afficher entre le bas
    /// de la barre des menus et le bord bas de la zone utile (Dock compris, `visibleFrame` le
    /// déduisant déjà), en gardant la même marge qu'ailleurs.
    ///
    /// Sans ce plafond, rien ne bornait la croissance du panneau : la fenêtre suit la taille
    /// intrinsèque du contenu SwiftUI, et au-delà d'une vingtaine de favoris radio elle sortait
    /// par le bas de l'écran. C'est le contenu lui-même qui s'y plie (`MiloPanelView`), la liste
    /// des stations étant son seul élément élastique — comme le fait Bluetooth quand les
    /// appareils sont nombreux.
    ///
    /// ENTIÈRE, et arrondie vers le BAS : la hauteur du contenu doit rester entière pour que le
    /// calage sous-pixel tombe juste (voir `shadowMargin`), et arrondir vers le haut ferait
    /// dépasser le plafond de la fraction de point qu'on vient d'ajouter.
    ///
    /// La marge transparente de l'ombre, elle, n'entre pas dans le calcul : elle ne peint rien
    /// et peut déborder de l'écran sans dommage (`constrainFrameRect` est neutralisé).
    static func maxContentHeight(on screen: NSScreen?) -> CGFloat {
        guard let screen else { return .greatestFiniteMagnitude }
        let available = screen.visibleFrame.height - topGap - screenEdgeMargin
        return max(0, available.rounded(.down))
    }

    // MARK: Ombre portée
    //
    // Mesurée sur fond blanc : celle de « Son » porte à 48,5 pt en n'assombrissant le blanc
    // que de 48 au bord. L'ombre par défaut de NSWindow porte à 15,5 pt et assombrit de 72 —
    // trois fois trop courte et bien trop dure. D'où une ombre dessinée à la main.

    static let shadowRadius: CGFloat = 23
    static let shadowOpacity: Float = 0.32
    static let shadowOffsetY: CGFloat = 3

    /// Marge transparente autour du panneau, pour que l'ombre ait la place de s'étaler.
    /// Doit dépasser `shadowRadius + shadowOffsetY` (26).
    ///
    /// Le demi-point n'est pas décoratif : c'est lui qui rend le calage sous-pixel possible.
    /// AppKit arrondit au point entier l'origine ET la taille des fenêtres ; les bords du
    /// panneau valant `origine + marge`, une marge entière les condamne à tomber sur des
    /// entiers — or les deux cibles mesurées sur « Son » sont des demi-entiers (haut 34,5 ;
    /// bord gauche à 11,5 de l'encre de l'icône, soit 1360,5 chez nous). Avec 60,5 et une
    /// hauteur de contenu entière (voir `positionPanel`), les deux tombent juste.
    static let shadowMargin: CGFloat = 60.5
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
            // Réglé avec Léo : 2 → 4, soit 13 pt entre la ligne de base du titre et le haut
            // de l'encre du haut-parleur (contre 11).
            .padding(.bottom, 4)
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

// MARK: - Morceau en cours

/// Géométrie de la ligne « en cours ». Sans référence système à mesurer (aucun module natif
/// n'a d'équivalent) : des valeurs choisies, comme les contrôles de la sous-section multiroom.
private enum NowPlayingMetrics {
    static let artworkSize: CGFloat = 48
    static let artworkCornerRadius: CGFloat = 8
    /// Écart pochette → texte.
    static let artworkTextGap: CGFloat = 10

    /// Médaillon carré arrondi en coin de la pochette — voir `NowPlayingInfo.badgeArtworkURL`.
    static let badgeSize: CGFloat = 16
    static let badgeCornerRadius: CGFloat = 6
    /// Retrait du médaillon par rapport aux bords bas et droit de la pochette.
    static let badgeInset: CGFloat = 2
    /// Écart mini texte → boutons, avant que le fondu ne le masque.
    static let textControlsGap: CGFloat = 8

    /// Longueur du fondu — même valeur que les noms multiroom (`MultiroomMetrics.nameFade`),
    /// pour un rendu identique.
    static let textFade: CGFloat = 14
    /// Taille de police commune au titre et à l'artiste — l'un et l'autre ne se distinguent
    /// plus que par le poids et la couleur.
    static let textSize: CGFloat = 12

    /// Cible tactile d'un bouton de contrôle (play/pause, suivant, stop/relance Radio).
    static let controlSize: CGFloat = 22
    static let controlGap: CGFloat = 7
    /// Taille de police par défaut d'une icône de contrôle (`forward.fill`).
    static let controlIconSize: CGFloat = 13
    /// `play.fill`/`pause.fill`/`stop.fill` remplissent moins leur bounding box que
    /// `forward.fill` (triangle plein contre double-chevron + barre) : à même corps de police,
    /// ils paraissent nettement plus petits. Corrigé en leur donnant un corps plus grand plutôt
    /// qu'en changeant la cible tactile (`controlSize`), qui reste identique pour les deux.
    static let playPauseIconSize: CGFloat = 20

    /// Largeur de la colonne titre/artiste, dimensionnée pour le nombre de boutons RÉELLEMENT
    /// affichés par la source active — pas un espace fixe dimensionné pour le pire cas. Radio
    /// (un seul bouton stop/relance) et les récepteurs passifs (aucun bouton : AirPlay, DLNA,
    /// Qobuz) gagnent donc plus de place pour le titre que Spotify/bibliothèque musicale/CD
    /// (play-pause + suivant).
    static func textWidth(controlCount: Int) -> CGFloat {
        let controlsWidth = controlCount == 0 ? 0
            : CGFloat(controlCount) * controlSize + CGFloat(controlCount - 1) * controlGap
        let rowContentWidth = MenuRowMetrics.width - 2 * MenuRowMetrics.contentInset
        return rowContentWidth - artworkSize - artworkTextGap - textControlsGap - controlsWidth
    }
}

/// Bandeau « now playing » : pochette 48×48 à gauche, titre puis artiste au milieu, contrôles
/// de lecture à droite quand la source active en propose. Affiché entre le titre du panneau et
/// le slider de volume dès qu'un morceau (ou, pour Radio, une station) est chargé — voir
/// `MiloStore.nowPlaying` pour le mapping des champs.
struct NowPlayingRow: View {
    @Bindable var store: MiloStore
    let info: NowPlayingInfo

    /// Radio n'a ni vraie pause ni morceau suivant : un seul bouton stop/relance, distinct du
    /// couple générique play-pause/suivant des autres sources — voir
    /// `MiloStore.toggleRadioNowPlaying`.
    private enum Controls {
        case none
        case radioToggle
        case pauseResume(hasNext: Bool)

        var count: Int {
            switch self {
            case .none: return 0
            case .radioToggle: return 1
            case .pauseResume(let hasNext): return hasNext ? 2 : 1
            }
        }
    }

    private var controls: Controls {
        if store.state?.activeSource == "radio" { return .radioToggle }
        guard store.nowPlayingSupportsPauseResume else { return .none }
        return .pauseResume(hasNext: store.nowPlayingSupportsNext)
    }

    var body: some View {
        let textWidth = NowPlayingMetrics.textWidth(controlCount: controls.count)

        HStack(spacing: 0) {
            NowPlayingArtwork(url: info.artworkURL,
                              badgeURL: info.badgeArtworkURL,
                              size: NowPlayingMetrics.artworkSize,
                              cornerRadius: NowPlayingMetrics.artworkCornerRadius)
                .padding(.trailing, NowPlayingMetrics.artworkTextGap)

            VStack(alignment: .leading, spacing: 2) {
                FadingText(text: info.title, weight: .semibold, size: NowPlayingMetrics.textSize,
                           dimmed: false, width: textWidth, fade: NowPlayingMetrics.textFade)

                if let artist = info.artist {
                    FadingText(text: artist, weight: .regular, size: NowPlayingMetrics.textSize,
                               dimmed: true, width: textWidth, fade: NowPlayingMetrics.textFade)
                }
            }

            Spacer(minLength: NowPlayingMetrics.textControlsGap)

            HStack(spacing: NowPlayingMetrics.controlGap) {
                switch controls {
                case .none:
                    EmptyView()

                case .radioToggle:
                    NowPlayingControlButton(
                        systemName: info.isPlaying ? "stop.fill" : "play.fill",
                        iconSize: NowPlayingMetrics.playPauseIconSize,
                        size: NowPlayingMetrics.controlSize,
                        action: store.toggleRadioNowPlaying
                    )

                case .pauseResume(let hasNext):
                    NowPlayingControlButton(
                        systemName: info.isPlaying ? "pause.fill" : "play.fill",
                        iconSize: NowPlayingMetrics.playPauseIconSize,
                        size: NowPlayingMetrics.controlSize,
                        action: store.toggleNowPlayingPause
                    )
                    if hasNext {
                        NowPlayingControlButton(
                            systemName: "forward.fill",
                            iconSize: NowPlayingMetrics.controlIconSize,
                            size: NowPlayingMetrics.controlSize,
                            action: store.advanceToNextTrack
                        )
                    }
                }
            }
        }
        .padding(.horizontal, MenuRowMetrics.contentInset)
        .padding(.vertical, 6)
        .frame(width: MenuRowMetrics.width, alignment: .leading)
    }
}

/// Bouton de contrôle (play/pause, suivant, stop/relance) — même idiome que `MuteButton` de la
/// sous-section multiroom.
private struct NowPlayingControlButton: View {
    let systemName: String
    let iconSize: CGFloat
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Pochette de la ligne « now playing ». Même idiome que `StationFavicon` (chargement direct,
/// sans cache partagé) : cette vue ne bouge jamais dans l'arbre — elle n'est ni recréée par un
/// `ForEach` ni échangée entre deux couches de morphing — donc `AsyncImage` ne recharge que
/// lorsque l'URL change réellement (nouveau morceau), jamais à chaque rendu.
private struct NowPlayingArtwork: View {
    let url: URL?
    /// Logo de la station en médaillon — voir `NowPlayingInfo.badgeArtworkURL`. `nil` partout
    /// sauf Radio sur un morceau reconnu avec sa propre pochette.
    let badgeURL: URL?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        artwork
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let badgeURL {
                    NowPlayingBadge(url: badgeURL)
                        .padding(.trailing, NowPlayingMetrics.badgeInset)
                        .padding(.bottom, NowPlayingMetrics.badgeInset)
                }
            }
    }

    @ViewBuilder
    private var artwork: some View {
        if let url {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(nsColor: .quaternarySystemFill))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
    }
}

/// Le logo de la station lui-même, carré arrondi, posé bien centré dans le trou découpé par
/// `NowPlayingArtwork` — voir `NowPlayingInfo.badgeArtworkURL`.
private struct NowPlayingBadge: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(nsColor: .quaternarySystemFill)
            }
        }
        .frame(width: NowPlayingMetrics.badgeSize, height: NowPlayingMetrics.badgeSize)
        .clipShape(RoundedRectangle(cornerRadius: NowPlayingMetrics.badgeCornerRadius, style: .continuous))
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
            // Spinner de transition DANS la pastille.
            RowIcon(icon: source.icon, isActive: isActive, isLoading: isLoading)

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

            if !isLoading, showsChevron {
                // La ligne Radio porte DEUX commandes : activer la source (le corps de la
                // ligne) et ouvrir les stations (le caret). Contrairement à Multiroom, activer
                // Radio alors qu'elle l'est déjà ne fait rien (voir le garde de
                // `MiloStore.selectSource`) — donc le caret doit rester la SEULE cible pour
                // ouvrir les stations ; lui laisser tout le vide à droite du libellé ferait
                // naviguer accidentellement au moindre clic sur la ligne.
                //
                // Imbriquer un bouton dans un bouton fonctionne — le plus intérieur gagne dans
                // sa propre zone — mais ici sa zone reste celle du chevron (plus un peu de marge
                // de confort), pas tout le reste de la ligne.
                Button { onChevron?() } label: {
                    ChevronCircle()
                        .padding(.horizontal, 6)
                        // Sans ça, le bouton se moule sur le chevron et sa zone ne fait que sa
                        // hauteur d'encre. On l'étire sur la hauteur de la ligne, que fixe la
                        // pastille de la source (26 pt).
                        .frame(maxHeight: .infinity)
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

// MARK: - Fonctionnalité

/// Multiroom, Égaliseur.
///
/// Même ligne qu'une source, et non un interrupteur : c'est la pastille qui porte l'état,
/// bleue quand la fonctionnalité est active, grise sinon — exactement le langage de la
/// section « Sortie » de « Son », où le périphérique en cours est une pastille bleue.
///
/// Un `Toggle` posait en plus deux cibles de clic concurrentes dans une ligne déjà
/// cliquable : cliquer le libellé ne faisait rien, cliquer l'interrupteur agissait.
struct FeatureRow: View {
    @Bindable var store: MiloStore
    let feature: FeatureDescriptor

    /// Multiroom porte, comme la ligne Radio, DEUX commandes : le corps bascule la
    /// fonctionnalité, le chevron à droite déplie la sous-section (zones/clients). Le chevron
    /// n'apparaît que lorsqu'il y a quelque chose à déplier (`store.canShowMultiroom`).
    var showsChevron: Bool = false
    var isExpanded: Bool = false
    var onChevron: (() -> Void)? = nil

    @State private var isHovering = false

    private var isLoading: Bool { store.loadingStates[feature.id] == true }
    private var isOn: Bool { store.displayedToggleState(feature.id) }

    var body: some View {
        MenuRowContainer(isHovering: $isHovering, action: toggle) {
            // Le spinner de bascule vit DANS la pastille (comme les sources), pas à droite.
            RowIcon(icon: feature.icon, isActive: isOn, isLoading: isLoading)

            Text(feature.title)
                .font(.system(size: 13))
                .lineLimit(1)

            if showsChevron {
                // Même construction que le caret Radio (SourceRow) : le bouton d'expansion
                // prend tout le vide à droite du libellé, pas juste l'encre du chevron —
                // une cible large pour une commande utilisée autant que la ligne.
                Button { onChevron?() } label: {
                    HStack(spacing: 0) {
                        Spacer(minLength: 4)
                        ExpandChevron(isExpanded: isExpanded)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Spacer(minLength: 4)
            }
        }
    }

    /// Le clic est ignoré pendant la bascule — c'est ce que faisait le `.disabled(isLoading)`
    /// de l'interrupteur, qu'une ligne cliquable ne donne plus gratuitement.
    private func toggle() {
        guard !isLoading else { return }
        store.toggleFeature(feature.id)
    }
}

// MARK: - Sous-section Multiroom (accordéon inline)

/// Géométrie de la sous-section multiroom, en cartes « inset-grouped » façon macOS.
private enum MultiroomMetrics {
    /// Fond des cartes, RELEVÉ AU PIXEL sur le panneau « Son » déplié sous AirPods (capture 2×) :
    /// verre à 32,32,32, inset à 52,52,52 — soit un voile **blanc à 9 %** (identique sur les
    /// trois canaux), un fond plus CLAIR que le verre. Dynamique pour rester juste en clair
    /// (bascule sur du noir à 9 %), comme `secondarySystemFill` inverse blanc/noir.
    static let cardFill: Color = {
        let ns = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: dark ? 1 : 0, alpha: 0.09)
        }
        return Color(nsColor: ns)
    }()

    /// Écart de verre entre la ligne Multiroom et la première carte. Mesuré sur « Son » : 5 pt.
    static let gapAboveCards: CGFloat = 5
    /// Marge des cartes vis-à-vis des bords du panneau.
    static let cardHInset: CGFloat = 10
    /// Écart de verre entre deux cartes distinctes (zone, client standalone).
    static let cardSpacing: CGFloat = 6
    static let cardCornerRadius: CGFloat = 9

    /// Retraits internes d'une ligne dans une carte.
    static let rowHInset: CGFloat = 10
    static let rowVInset: CGFloat = 6

    /// Retrait de GAUCHE d'une ligne, calé pour que le NOM (après la pastille et l'écart) tombe
    /// à la même abscisse que le libellé « Multiroom » de la ligne parente — soit
    /// `contentInset + iconSize + iconTextGap` du bord du panneau. On le déduit des métriques
    /// plutôt que de le coder en dur : `cardHInset + rowLeadingInset + iconSize + gap` doit
    /// égaler ce libellé, d'où la soustraction. (Le côté droit garde `rowHInset`.)
    static let rowLeadingInset: CGFloat =
        MenuRowMetrics.contentInset + MenuRowMetrics.iconSize + MenuRowMetrics.iconTextGap
        - cardHInset - iconSize - gap

    static let iconSize: CGFloat = 18
    static let muteIconSize: CGFloat = 22
    /// Écart icône → nom, et nom → contrôles.
    static let gap: CGFloat = 7

    /// Largeur FIXE de la colonne de nom, pour que tous les sliders (zone comme client)
    /// s'alignent sur la même largeur. Un nom plus long est fondu (dégradé) plutôt que coupé
    /// par « … ». Volontairement serrée pour laisser le plus de place aux barres de volume :
    /// les noms un peu longs partent en fondu, c'est assumé.
    static let nameWidth: CGFloat = 64
    /// Longueur du fondu en fin de nom.
    static let nameFade: CGFloat = 14

    /// Intervalle mini entre deux envois réseau pendant un glissement de slider. À chaque
    /// pixel on rafraîchit le pouce localement, mais on n'envoie au backend qu'à cette cadence
    /// (la valeur finale part toujours au relâchement). Sans ça, le flot de PATCH fait
    /// rediffuser le backend en continu et toute la section se re-rend → glissement saccadé.
    static let sendThrottle: TimeInterval = 0.06
}

/// La sous-section dépliable sous la ligne Multiroom, en **cartes distinctes** : une carte par
/// zone (en-tête + filet + clients membres) et une carte par client standalone. Tout est sur
/// une ligne (icône + nom + slider + mute) et aligné à gauche, sans indentation.
struct MultiroomSection: View {
    @Bindable var store: MiloStore

    var body: some View {
        VStack(spacing: MultiroomMetrics.cardSpacing) {
            ForEach(store.multiroomDisplayItems) { item in
                switch item {
                case .zone(let zone, let clients):
                    MultiroomCard {
                        MultiroomRow(store: store, kind: .zone(zone, clients))
                        // Un SEUL filet, entre l'en-tête de zone et ses clients — pas entre
                        // chaque client.
                        if !clients.isEmpty {
                            MultiroomRowSeparator()
                        }
                        ForEach(clients) { client in
                            MultiroomRow(store: store, kind: .client(client))
                        }
                    }
                case .standalone(let client):
                    MultiroomCard {
                        MultiroomRow(store: store, kind: .client(client))
                    }
                }
            }
        }
        .padding(.horizontal, MultiroomMetrics.cardHInset)
        .padding(.top, MultiroomMetrics.gapAboveCards)
        .padding(.bottom, MultiroomMetrics.cardSpacing)
        .frame(width: MenuRowMetrics.width, alignment: .leading)
    }
}

/// Une carte grise arrondie qui regroupe ses lignes.
private struct MultiroomCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MultiroomMetrics.cardFill)
            .clipShape(RoundedRectangle(cornerRadius: MultiroomMetrics.cardCornerRadius,
                                        style: .continuous))
    }
}

/// Filet natif entre l'en-tête de zone et ses clients : pleine largeur de la carte, avec un
/// léger retrait SYMÉTRIQUE de chaque côté.
private struct MultiroomRowSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, MultiroomMetrics.rowHInset)
    }
}

/// Une ligne de carte : icône + nom + slider + mute, sur une seule ligne. Sert aussi bien à
/// une zone (slider maître en DELTA, mute de tous ses clients) qu'à un client (slider absolu).
private struct MultiroomRow: View {
    @Bindable var store: MiloStore
    let kind: Kind

    enum Kind {
        case zone(MultiroomZone, [MultiroomClient])
        case client(MultiroomClient)
    }

    /// Dernière valeur ENVOYÉE pendant un glissement (base du prochain delta pour une zone,
    /// coalescence pour un client). `nil` hors glissement.
    @State private var lastSent: Double?
    /// Dernière valeur scrubée (envoyée ou non) — envoyée au relâchement pour ne pas perdre
    /// le dernier mouvement quand il tombe dans un intervalle throttlé.
    @State private var pending: Double?
    /// Horodatage du dernier envoi réseau, pour le throttle.
    @State private var lastSendAt: Date = .distantPast

    var body: some View {
        HStack(spacing: MultiroomMetrics.gap) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: MultiroomMetrics.iconSize, height: MultiroomMetrics.iconSize)

            FadingText(
                text: name,
                weight: isZone ? .medium : .regular,
                dimmed: !online,
                width: MultiroomMetrics.nameWidth,
                fade: MultiroomMetrics.nameFade
            )

            if controllable {
                MultiroomVolumeSlider(
                    liveValueDb: valueDb,
                    range: store.volumeLimits,
                    onScrub: scrub,
                    onEnd: endScrub
                )
                MuteButton(muted: muted, action: toggleMute)
            } else {
                Spacer(minLength: 4)
                if !online {
                    Text(L("multiroom.offline"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        // Gauche calée pour aligner le NOM sous le libellé « Multiroom » (voir `rowLeadingInset`) ;
        // droite en `rowHInset` normal.
        .padding(.leading, MultiroomMetrics.rowLeadingInset)
        .padding(.trailing, MultiroomMetrics.rowHInset)
        .padding(.vertical, MultiroomMetrics.rowVInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Dérivés selon le type

    private var isZone: Bool { if case .zone = kind { return true }; return false }

    private var icon: String {
        isZone ? "hifispeaker.2.fill" : "hifispeaker.fill"
    }

    private var name: String {
        switch kind {
        case .zone(let zone, _): return zone.name
        case .client(let client): return client.name
        }
    }

    private var online: Bool {
        switch kind {
        case .zone(_, let clients): return clients.contains { $0.online }
        case .client(let client): return client.online
        }
    }

    /// Le slider n'a de prise que si l'élément est joignable ET pilote son volume.
    private var controllable: Bool {
        switch kind {
        case .zone(_, let clients):
            return clients.contains { $0.online }
        case .client(let client):
            let vol = store.multiroomVolume.clients[client.macId]
            return client.online && client.volumeControl && (vol?.available ?? true)
        }
    }

    private var valueDb: Double {
        switch kind {
        case .zone(let zone, _):
            return store.multiroomVolume.zones[zone.id]?.averageVolumeDb ?? VolumeDefaults.limitMinDb
        case .client(let client):
            return store.multiroomVolume.clients[client.macId]?.volumeDb ?? client.volumeDb
        }
    }

    private var muted: Bool {
        switch kind {
        case .zone(let zone, _):
            return store.multiroomVolume.zones[zone.id]?.allMuted ?? false
        case .client(let client):
            return store.multiroomVolume.clients[client.macId]?.mute ?? client.mute
        }
    }

    // MARK: Actions

    /// Appelé à chaque cran du glissement. Le pouce suit déjà localement (voir
    /// `MultiroomVolumeSlider`) ; ici on THROTTLE seulement les envois réseau.
    private func scrub(_ newValue: Double) {
        pending = newValue
        let now = Date()
        if now.timeIntervalSince(lastSendAt) >= MultiroomMetrics.sendThrottle {
            flushSend(newValue)
            lastSendAt = now
        }
    }

    /// Au relâchement : on envoie la dernière valeur (au cas où elle est tombée dans un
    /// intervalle throttlé), puis on remet à zéro le suivi.
    private func endScrub() {
        if let pending { flushSend(pending) }
        pending = nil
        lastSent = nil
        lastSendAt = .distantPast
    }

    /// Client : volume absolu. Zone : delta depuis la dernière valeur ENVOYÉE (le backend n'a
    /// pas de volume de zone, il répercute le delta sur ses clients). Comme `lastSent` ne bouge
    /// qu'à l'envoi réel, throttler ne perd aucun mouvement — le prochain delta le rattrape.
    private func flushSend(_ value: Double) {
        switch kind {
        case .zone(let zone, _):
            let previous = lastSent ?? valueDb
            let delta = value - previous
            if abs(delta) > 0.05 {
                store.setZoneVolumeDelta(zoneId: zone.id, deltaDb: delta)
                lastSent = value
            }
        case .client(let client):
            store.setClientVolume(mac: client.macId, volumeDb: value)
        }
    }

    private func toggleMute() {
        switch kind {
        case .zone(_, let clients):
            let onlineMacs = clients.filter { $0.online }.map(\.macId)
            store.setZoneMute(clientMacs: onlineMacs, muted: !muted)
        case .client(let client):
            store.setClientMute(mac: client.macId, muted: !muted)
        }
    }
}

/// Nom d'élément à largeur FIXE, pour aligner toutes les colonnes de slider. Un nom trop long
/// n'est pas coupé par « … » mais **fondu** en dégradé sur son bord droit — plus propre, et
/// c'est le langage de macOS (Musique, Réglages). Le fondu ne porte que sur les derniers points
/// de la largeur : un nom court, qui n'atteint pas cette zone, n'est pas affecté.
private struct FadingText: View {
    let text: String
    let weight: Font.Weight
    var size: CGFloat = 13
    let dimmed: Bool
    /// Largeur figée de la colonne de texte — appelant par appelant : les noms multiroom
    /// s'alignent sur `MultiroomMetrics.nameWidth`, la ligne « en cours » réserve la place des
    /// boutons play/pause et suivant (voir `NowPlayingRow`).
    let width: CGFloat
    /// Longueur du fondu en fin de texte.
    let fade: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            // Taille NATURELLE (pas de troncature « … »), puis calée dans une largeur fixe et
            // rognée : le texte qui déborde est masqué, et le dégradé le fait disparaître en
            // fondu au lieu d'un bord net.
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: width, alignment: .leading)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: (width - fade) / width),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }
}

/// Bouton muet : un haut-parleur qui bascule sur `speaker.slash` une fois coupé.
private struct MuteButton: View {
    let muted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(muted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: MultiroomMetrics.muteIconSize, height: MultiroomMetrics.muteIconSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Slider de volume d'un élément multiroom : le `Slider` natif SwiftUI (comme le volume
/// global de cette branche), en `.small` pour le rail fin de « Son ».
///
/// Pendant un glissement, on affiche la valeur LOCALE (`dragValue`) et on appelle `onScrub`
/// à chaque cran ; au relâchement on rend la main à la valeur live du store (échos WebSocket).
/// Cela évite que l'écho serveur, en retard d'un aller-retour, ne fasse sauter le pouce.
private struct MultiroomVolumeSlider: View {
    let liveValueDb: Double
    let range: (minDb: Double, maxDb: Double)
    let onScrub: (Double) -> Void
    let onEnd: () -> Void

    @State private var dragValue: Double?

    private var bounds: ClosedRange<Double> {
        range.maxDb > range.minDb ? range.minDb...range.maxDb
                                  : VolumeDefaults.limitMinDb...VolumeDefaults.limitMaxDb
    }

    var body: some View {
        Slider(
            value: Binding(
                get: {
                    let v = dragValue ?? liveValueDb
                    return Swift.min(Swift.max(v, bounds.lowerBound), bounds.upperBound)
                },
                set: { newValue in
                    dragValue = newValue
                    onScrub(newValue)
                }
            ),
            in: bounds,
            onEditingChanged: { editing in
                if !editing {
                    dragValue = nil
                    onEnd()
                }
            }
        )
        .controlSize(.small)
        .accessibilityLabel(L("accessibility.volume_slider"))
    }
}

// MARK: - Station radio (sous-menu)

struct RadioStationRow: View {
    @Bindable var store: MiloStore
    let station: RadioStation

    @State private var isHovering = false

    private var isPlaying: Bool { store.playingRadioStationId == station.id }
    private var isLoading: Bool { store.radioStationLoadingId == station.id }

    /// Même empreinte pour les trois états (spinner, stop, play) afin qu'ils tombent
    /// exactement à la même position — sinon le spinner (mis à l'échelle) et le
    /// symbole SF (dimensionné par sa police) ne se centrent pas au même endroit.
    private let trailingIconSize: CGFloat = 20

    var body: some View {
        MenuRowContainer(isHovering: $isHovering, action: toggle) {
            MenuThumbnail(url: store.radioFaviconURL(for: station.favicon),
                          fallbackSystemImage: "dot.radiowaves.left.and.right")

            Text(station.name)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer(minLength: 8)

            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                } else if isPlaying {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if isHovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: trailingIconSize, height: trailingIconSize)
        }
    }

    private func toggle() {
        if isPlaying {
            store.stopRadioPlayback()
        } else {
            store.playRadioStation(station.id)
        }
    }
}

/// Vignette 32×32 à coins arrondis pour une ligne de sous-niveau (station radio, artiste/album/
/// morceau de la bibliothèque musicale…), avec un repli SF Symbol pour les entrées sans image
/// (beaucoup de favoris radio n'en ont pas ; tous les résultats de recherche n'ont pas de
/// pochette). L'image se recadre en `.fill` puis est rognée au carré arrondi, comme la grille de
/// favoris du frontend Milō.
private struct MenuThumbnail: View {
    let url: URL?
    let fallbackSystemImage: String

    private let size: CGFloat = 32
    private let cornerRadius: CGFloat = 7

    /// Image déjà chargée par CETTE vue. Le cache partagé sert les vues re-créées, celui-ci évite
    /// de le relire à chaque passe de rendu.
    @State private var loaded: Image?

    var body: some View {
        image
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var image: some View {
        if let ready = loaded ?? url.flatMap({ FaviconCache.shared.image(for: $0) }) {
            ready
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .onAppear {
                            if let url { FaviconCache.shared.store(image, for: url) }
                            loaded = image
                        }
                } else {
                    placeholder
                }
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(nsColor: .quaternarySystemFill))
            .overlay {
                Image(systemName: fallbackSystemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
    }
}

/// Vignettes de `MenuThumbnail` déjà chargées, gardées en mémoire pour la durée de la session —
/// logos de stations radio comme pochettes de résultats de recherche.
///
/// Le cache HTTP d'URLSession ne suffit pas : une `AsyncImage` re-créée repart d'une passe de
/// chargement ASYNCHRONE même quand l'octet est déjà en cache, et affiche donc son placeholder
/// l'espace d'une image ou deux. Or la liste des stations est re-créée à chaque entrée — et une
/// fois de plus quand la transition passe la main de son overlay à la couche principale : les
/// logos clignotaient au moment précis où la bascule doit être lisse. Une image déjà vue est
/// désormais rendue SYNCHRONEMENT.
///
/// Quelques dizaines de vignettes 32 pt : le cache n'a pas besoin d'être borné.
@MainActor
private final class FaviconCache {
    static let shared = FaviconCache()

    private var images: [URL: Image] = [:]

    func image(for url: URL) -> Image? { images[url] }

    func store(_ image: Image, for url: URL) { images[url] = image }
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

// MARK: - Recherche bibliothèque musicale

/// Champ de recherche : icône loupe + `TextField`, sans le chrome par défaut de macOS (bordure,
/// fond) puisque c'est le verre du panneau qui sert de fond ici. Prend le focus dès l'entrée
/// dans la route, comme une recherche Spotlight — le panneau force déjà `canBecomeKey`/
/// `makeKey()` (`MenuBarShell`), donc rien de plus à faire côté fenêtre pour que ça marche.
struct MusicLibrarySearchField: View {
    @Bindable var store: MiloStore
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField(
                "",
                text: Binding(
                    get: { store.musicLibrarySearchTerm },
                    set: { store.updateMusicLibrarySearchTerm($0) }
                ),
                prompt: Text(L("musicLibrary.search.placeholder")).foregroundStyle(.tertiary)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($isFocused)
        }
        .padding(.horizontal, MenuRowMetrics.textInset)
        .padding(.vertical, MenuRowMetrics.textRowVerticalPadding)
        .frame(width: MenuRowMetrics.width, alignment: .leading)
        .onAppear { isFocused = true }
    }
}

/// Ligne d'état statique (invite avant recherche, "aucun résultat") — même habillage que
/// `RadioEmptyRow`.
private struct MusicLibraryStatusRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, MenuRowMetrics.contentInset)
            .padding(.vertical, 5)
            .frame(width: MenuRowMetrics.width, alignment: .leading)
    }
}

private struct MusicLibraryLoadingRow: View {
    var body: some View {
        HStack {
            Spacer(minLength: 0)
            ProgressView()
                .controlSize(.small)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .frame(width: MenuRowMetrics.width)
    }
}

/// Le corps du sous-niveau recherche : le champ vit à part (`MiloPanelView.musicLibraryContent`),
/// cette vue ne porte que ce qui suit — invite / chargement / aucun résultat / les trois
/// sections de résultats. Même arbitrage de précédence que `SearchView.vue` : le chargement
/// masque d'éventuels résultats précédents plutôt que de les laisser en arrière-plan pendant le
/// debounce suivant.
struct MusicLibrarySearchResultsList: View {
    @Bindable var store: MiloStore

    private var results: MusicLibrarySearchResults { store.musicLibrarySearchResults }

    private var hasQuery: Bool {
        !store.musicLibrarySearchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if !hasQuery {
            MusicLibraryStatusRow(text: L("musicLibrary.search.prompt"))
        } else if store.musicLibrarySearchLoading {
            MusicLibraryLoadingRow()
        } else if results.isEmpty {
            MusicLibraryStatusRow(text: L("musicLibrary.search.noResults"))
        } else {
            // Comme `radioContent` : la ScrollView est le seul élément élastique du sous-niveau,
            // elle porte donc elle-même le retrait bas (voir `bottomInset(for:)`).
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if !results.artists.isEmpty {
                        MenuSectionHeader(text: L("musicLibrary.search.artists"))
                        ForEach(results.artists) { artist in
                            MusicLibraryArtistRow(store: store, artist: artist)
                        }
                    }
                    if !results.albums.isEmpty {
                        MenuSectionHeader(text: L("musicLibrary.search.albums"))
                        ForEach(results.albums) { album in
                            MusicLibraryAlbumRow(store: store, album: album)
                        }
                    }
                    if !results.songs.isEmpty {
                        MenuSectionHeader(text: L("musicLibrary.search.songs"))
                        ForEach(results.songs) { song in
                            MusicLibrarySongRow(store: store, song: song, context: results.songs)
                        }
                    }
                }
            }
            .contentMargins(.bottom, PanelMetrics.bottomInset, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Liste des albums de la page artiste (`MiloPanelView.musicLibraryArtistContent`) — même
/// arbitrage chargement/vide/liste que `MusicLibrarySearchResultsList`, mais sans invite (on
/// arrive déjà sur une intention explicite, pas un champ vide à remplir).
struct MusicLibraryArtistAlbumsList: View {
    @Bindable var store: MiloStore

    var body: some View {
        if store.musicLibraryArtistAlbumsLoading {
            MusicLibraryLoadingRow()
        } else if store.musicLibraryArtistAlbums.isEmpty {
            MusicLibraryStatusRow(text: L("musicLibrary.artist.noAlbums"))
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.musicLibraryArtistAlbums) { album in
                        MusicLibraryAlbumRow(store: store, album: album)
                    }
                }
            }
            .contentMargins(.bottom, PanelMetrics.bottomInset, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Liste des morceaux de la page album (`MiloPanelView.musicLibraryAlbumContent`) — même
/// construction que `MusicLibraryArtistAlbumsList`. Ces morceaux (et non ceux d'une éventuelle
/// recherche en cours) forment le CONTEXTE de lecture passé à chaque `MusicLibrarySongRow`.
struct MusicLibraryAlbumSongsList: View {
    @Bindable var store: MiloStore

    var body: some View {
        if store.musicLibraryAlbumSongsLoading {
            MusicLibraryLoadingRow()
        } else if store.musicLibraryAlbumSongs.isEmpty {
            MusicLibraryStatusRow(text: L("musicLibrary.album.noSongs"))
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.musicLibraryAlbumSongs) { song in
                        MusicLibrarySongRow(store: store, song: song, context: store.musicLibraryAlbumSongs)
                    }
                }
            }
            .contentMargins(.bottom, PanelMetrics.bottomInset, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Ligne d'artiste — tappable : mène à la page de l'artiste (ses albums), même caret que la
/// ligne « Bibliothèque musicale » elle-même. Contrairement à `SourceRow`/Radio, le corps de la
/// ligne n'a pas de second rôle à protéger (activer la source, etc.) : toute la ligne navigue,
/// le chevron n'est qu'un repère visuel du sens de la navigation.
struct MusicLibraryArtistRow: View {
    @Bindable var store: MiloStore
    let artist: MusicLibraryArtist

    @State private var isHovering = false

    var body: some View {
        MenuRowContainer(isHovering: $isHovering, action: { store.showMusicLibraryArtist(artist) }) {
            MenuThumbnail(url: store.musicLibraryCoverURL(for: artist.coverArt),
                          fallbackSystemImage: "music.mic")

            VStack(alignment: .leading, spacing: 1) {
                Text(artist.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                if let albumCount = artist.albumCount {
                    Text(L("musicLibrary.search.albumsCount", albumCount))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            ChevronCircle()
        }
    }
}

/// Ligne d'album — tappable, même raison que `MusicLibraryArtistRow` : mène à la page de
/// l'album (ses morceaux), qu'on l'affiche depuis une recherche ou depuis la page d'un artiste.
struct MusicLibraryAlbumRow: View {
    @Bindable var store: MiloStore
    let album: MusicLibraryAlbum

    @State private var isHovering = false

    var body: some View {
        MenuRowContainer(isHovering: $isHovering, action: { store.showMusicLibraryAlbum(album) }) {
            MenuThumbnail(url: store.musicLibraryCoverURL(for: album.coverArt),
                          fallbackSystemImage: "square.stack")

            VStack(alignment: .leading, spacing: 1) {
                Text(album.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                if let artist = album.artist {
                    Text(artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            ChevronCircle()
        }
    }
}

/// Ligne de morceau — la SEULE des trois dont le tap agit directement plutôt que de naviguer :
/// il lance la lecture (`play_context` avec `context`, démarré à l'index du morceau touché),
/// remplaçant ce qui joue déjà, comme un tap sur une station radio. `context` est la liste
/// d'où vient le tap — les résultats de recherche, ou les morceaux de l'album ouvert — pas
/// toujours `store.musicLibrarySearchResults.songs`.
///
/// Quand CE morceau est celui actuellement chargé par la bibliothèque musicale, l'icône de
/// droite bascule sur play/pause (au lieu du simple repère au survol) et le tap bascule play/
/// pause au lieu de relancer `play_context` depuis le début — même bouton, même geste que la
/// ligne « en cours » de la racine (`NowPlayingRow`/`toggleNowPlayingPause`).
struct MusicLibrarySongRow: View {
    @Bindable var store: MiloStore
    let song: MusicLibrarySong
    let context: [MusicLibrarySong]

    @State private var isHovering = false

    private var isLoading: Bool { store.musicLibrarySongLoadingId == song.id }
    private var isCurrent: Bool { store.isCurrentMusicLibrarySong(song) }
    private var isPlayingNow: Bool { isCurrent && (store.nowPlaying?.isPlaying ?? false) }

    /// Même empreinte pour spinner et icône play/pause que `RadioStationRow`, pour la même
    /// raison : qu'ils tombent exactement à la même position.
    private let trailingIconSize: CGFloat = 20

    var body: some View {
        MenuRowContainer(isHovering: $isHovering, action: handleTap) {
            MenuThumbnail(url: store.musicLibraryCoverURL(for: song.coverArt),
                          fallbackSystemImage: "music.note")

            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.system(size: 13))
                    .lineLimit(1)

                if let artist = song.artist {
                    Text(artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                } else if isPlayingNow {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if isCurrent {
                    // Chargé mais en pause : l'icône invite à relancer, comme la ligne
                    // « en cours » de la racine.
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if isHovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: trailingIconSize, height: trailingIconSize)
        }
    }

    private func handleTap() {
        if isCurrent {
            store.toggleNowPlayingPause()
        } else {
            store.playMusicLibrarySong(song, from: context)
        }
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
/// Le panneau étant une fenêtre qu'on dessine soi-même, aucune surbrillance ne vient du
/// système : chaque ligne peint la sienne, sur son propre survol.
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
                RoundedRectangle(cornerRadius: MenuRowMetrics.rowHoverCornerRadius,
                                 style: .continuous)
                    .fill(isHovering ? AnyShapeStyle(MenuRowMetrics.rowHoverFill)
                                     : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MenuRowMetrics.highlightInset)
        .onHover { isHovering = $0 }
    }
}

/// Caret « voir les stations » de la ligne Radio.
///
/// Visuellement IDENTIQUE au caret Multiroom (`ExpandChevron`) au repos : un chevron nu, non
/// pastillé, à la même taille et la même teinte. La seule différence est le comportement — celui-ci
/// est statique et pointe toujours à droite (il MÈNE AILLEURS, vers la liste des stations), là où
/// celui du Multiroom bascule en dépliant sur place.
private struct ChevronCircle: View {
    var body: some View {
        Image(systemName: "chevron.right")
            // RELEVÉ AU PIXEL sur le caret « AirPods Pro » du panneau « Son » (capture 2×) : encre
            // ~10,5 × 6 pt, trait ~1,5 pt — un chevron FIN (`.regular`), pas dense. C'est le poids,
            // pas la taille, qui le distingue ; `.semibold` le rendait lourd et sombre.
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            .padding(.trailing, 2)
    }
}

/// Chevron d'expansion de la ligne Multiroom.
///
/// Même chevron nu que la ligne Radio (`ChevronCircle`), mais animé : Radio MÈNE AILLEURS (une
/// autre vue) et reste figé à droite, là où celui-ci déplie sur PLACE. C'est exactement le langage
/// du panneau « Son » sous AirPods — un chevron qui pointe à droite fermé, vers le bas ouvert.
private struct ExpandChevron: View {
    let isExpanded: Bool

    /// La rotation et la « pulsation » (scale + opacity) sont un état LOCAL, purement graphique :
    /// aucune n'affecte la taille de la ligne, donc pas de risque de faire sauter la fenêtre
    /// (contrairement à un `withAnimation` sur `multiroomExpanded`, cf. `toggleMultiroom`).
    @State private var rotated = false
    @State private var faded = false

    var body: some View {
        Image(systemName: "chevron.right")
            // Identique au caret Radio (`ChevronCircle`) : chevron fin `.regular` relevé sur le
            // caret « AirPods Pro » du panneau « Son ».
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            // +90° horaire : « > » fermé bascule sur « ⌄ » ouvert.
            .rotationEffect(.degrees(rotated ? 90 : 0))
            // Le caret rétrécit + s'efface, change de sens hors-champ, puis regrandit + réapparaît
            // à sa nouvelle position — plutôt qu'une rotation nue en place.
            .scaleEffect(faded ? 0.4 : 1)
            .opacity(faded ? 0 : 1)
            .padding(.trailing, 2)
            .onAppear { rotated = isExpanded }
            .onChange(of: isExpanded) { _, newValue in
                // Deux phases ENCHAÎNÉES, pas superposées : le `completion:` garantit que la phase 2
                // ne part qu'une fois la phase 1 finie. Sans lui, SwiftUI verrait `faded` passer à
                // `true` puis `false` dans la même passe et n'animerait jamais le fade-out.
                //   Phase 1 : rétrécir + s'effacer.
                //   Phase 2 : basculer le sens HORS-CHAMP (le caret est invisible), puis regrandir +
                //   réapparaître — le nouveau caret « arrive » donc déjà tourné.
                withAnimation(.easeIn(duration: 0.18)) {
                    faded = true
                } completion: {
                    rotated = newValue
                    withAnimation(.spring(duration: 0.45)) { faded = false }
                }
            }
    }
}

/// Pastille d'icône : accent quand actif, gris sinon — le même langage visuel que la
/// section « Sortie » du panneau Son.
///
/// Pendant un chargement, le spinner remplace l'icône DANS la pastille (au lieu de s'afficher
/// à droite de la ligne), pour les sources comme pour les fonctionnalités.
private struct RowIcon: View {
    let icon: SourceIcon
    let isActive: Bool
    var isLoading: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? AnyShapeStyle(MenuRowMetrics.activeCircleColor)
                               : AnyShapeStyle(.tertiary))

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.85)
                    // Blanc sur la pastille active (bleue) pour le contraste ; teinte par
                    // défaut sur la pastille grise, déjà lisible.
                    .tint(isActive ? .white : nil)
            } else {
                icon.image
                    .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
        }
        .frame(width: MenuRowMetrics.iconSize, height: MenuRowMetrics.iconSize)
    }
}


// MARK: - Retour depuis un sous-niveau

/// Ligne de TITRE, mais cliquable : elle se cale sur `textInset` / `titleTopInset` et pèse le
/// même semibold qu'un `MenuTitle` — pas de pastille, donc pas de `MenuRowContainer`, dont les
/// retraits partent de `contentInset`.
///
/// Elle s'allume au survol comme toutes les autres lignes cliquables du panneau. Sa boîte est
/// bâtie à la main, exactement comme celle de `FooterRow` : même remplissage, même rayon, mêmes
/// retraits — la seule différence est qu'elle s'aligne sur le texte des titres (15 pt) et non
/// sur les pastilles (14 pt).
///
/// Le texte, lui, ne bouge pas : la boîte s'étend de `textRowVerticalPadding` au-dessus de lui,
/// qu'on retranche donc du retrait haut.
///
/// Partagée par tous les sous-niveaux du panneau (stations radio, recherche bibliothèque
/// musicale…) — seul `title` change au site d'appel.
struct PanelBackRow: View {
    let title: String
    let onBack: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onBack) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, MenuRowMetrics.textInset - MenuRowMetrics.highlightInset)
            .padding(.vertical, MenuRowMetrics.textRowVerticalPadding)
            .frame(width: MenuRowMetrics.width - 2 * MenuRowMetrics.highlightInset,
                   alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MenuRowMetrics.rowHoverCornerRadius,
                                 style: .continuous)
                    .fill(isHovering ? AnyShapeStyle(MenuRowMetrics.rowHoverFill)
                                     : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MenuRowMetrics.highlightInset)
        .padding(.top, MenuRowMetrics.titleTopInset - MenuRowMetrics.textRowVerticalPadding)
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
            .padding(.vertical, MenuRowMetrics.textRowVerticalPadding)
            .frame(width: MenuRowMetrics.width - 2 * MenuRowMetrics.highlightInset,
                   alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MenuRowMetrics.rowHoverCornerRadius,
                                 style: .continuous)
                    .fill(isHovering ? AnyShapeStyle(MenuRowMetrics.rowHoverFill)
                                     : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MenuRowMetrics.highlightInset)
        .onHover { isHovering = $0 }
    }
}
