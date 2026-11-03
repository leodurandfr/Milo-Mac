import Testing
import Foundation
@testable import Milo

/// The now-playing row's title for a CD track nothing names: a burned disc, or a disc read
/// offline, which Milō publishes with no title and only `details.current_track`.
struct NowPlayingTitleTests {

    private func localization(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("An untitled CD track is named by its number, in the Mac's language")
    func anUntitledCdTrackIsNamedByItsNumber() throws {
        let state = try MiloAudioState.decode(Data("""
        {"source":"cd","switching":false,"service":"running","service_error":null,"availability":{},
         "session":{"id":"c3","phase":"playing","title":null,"artist":null,"album":null,"artwork":null,
           "senders":[],"duration_ms":245000,"position":{"ms":12000,"at":1790270000.25,"rate":1.0}},
         "controls":["pause","seek","skip","next","prev"],"resume":null,
         "details":{"kind":"cd","disc":{"id":"d1","album":null,"artist":null,"year":null,"cover_url":null,
           "tracks":[{"number":3,"title":null,"duration_ms":245000}]},
           "current_track":3,"artwork_pending":false,"shuffle":false,"repeat":"off"},
         "multiroom_enabled":false,"equalizer_effects_enabled":true}
        """.utf8))

        let french = try localization("fr")
        let english = try localization("en")
        #expect(state.shown(untitledTrack: { NowPlayingInfo.untitledTrack($0, bundle: french) })?.title
                == "Morceau 3")
        #expect(state.shown(untitledTrack: { NowPlayingInfo.untitledTrack($0, bundle: english) })?.title
                == "Track 3")
    }

    @Test("Every localization names an untitled track")
    func everyLocalizationNamesIt() throws {
        let languages = Bundle.main.localizations.filter { $0 != "Base" }
        #expect(languages.count >= 8)
        for language in languages {
            let title = NowPlayingInfo.untitledTrack(3, bundle: try localization(language))
            #expect(title.contains("3") && !title.contains("cd.untitledTrack"), "\(language): \(title)")
        }
    }
}
