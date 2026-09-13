//  Hauteur de l'en-tête des sous-niveaux.
//
//  L'en-tête d'un sous-niveau se cale sur son TEXTE, et le bouton de lecture des pages artiste/
//  album ne doit rien y changer : ni en apparaissant, ni en laissant la place au spinner, qui
//  n'a pas la même taille que le symbole play. C'est pour ça qu'il est posé en overlay — une
//  construction dont rien, à la lecture, ne dit qu'elle tient encore après une retouche de la
//  ligne. D'où cette mesure, la seule façon de le vérifier sans ouvrir le panneau à la main.

import AppKit
import SwiftUI
import Testing
@testable import Milo

@MainActor
private func headerHeight(play: PanelBackPlayAction?) -> CGFloat {
    let view = NSHostingView(rootView: PanelBackRow(title: "Random Access Memories", play: play) {})
    return view.fittingSize.height
}

@MainActor
@Suite("Hauteur de PanelBackRow")
struct PanelBackRowLayoutTests {

    @Test("Le bouton de lecture ne change pas la hauteur de l'en-tête")
    func playButtonDoesNotChangeHeight() {
        let bare = headerHeight(play: nil)
        let withPlay = headerHeight(play: .init(isLoading: false, isPlaying: false, action: {}))

        #expect(bare > 0)
        #expect(withPlay == bare)
    }

    @Test("Le spinner ne change pas la hauteur de l'en-tête")
    func loadingSpinnerDoesNotChangeHeight() {
        let bare = headerHeight(play: nil)
        let loading = headerHeight(play: .init(isLoading: true, isPlaying: false, action: {}))
        let paused = headerHeight(play: .init(isLoading: false, isPlaying: true, action: {}))

        #expect(loading == bare)
        #expect(paused == bare)
    }
}
