//  Sub-level header height.
//
//  A sub-level's header sizes itself on its TEXT, and the play button on the artist/album
//  pages must not change that: neither by appearing, nor by making room for the spinner,
//  which is not the same size as the play symbol. That is why it sits in an overlay — a
//  construction that, on reading, gives no sign of still holding after a tweak to the row.
//  Hence this measurement, the only way to check it without opening the panel by hand.

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
@Suite("PanelBackRow height")
struct PanelBackRowLayoutTests {

    @Test("The play button does not change the header's height")
    func playButtonDoesNotChangeHeight() {
        let bare = headerHeight(play: nil)
        let withPlay = headerHeight(play: .init(isLoading: false, isPlaying: false, action: {}))

        #expect(bare > 0)
        #expect(withPlay == bare)
    }

    @Test("The spinner does not change the header's height")
    func loadingSpinnerDoesNotChangeHeight() {
        let bare = headerHeight(play: nil)
        let loading = headerHeight(play: .init(isLoading: true, isPlaying: false, action: {}))
        let paused = headerHeight(play: .init(isLoading: false, isPlaying: true, action: {}))

        #expect(loading == bare)
        #expect(paused == bare)
    }
}
