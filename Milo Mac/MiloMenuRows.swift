import SwiftUI

/// The panel's rows, in SwiftUI.
///
/// The panel is not an NSMenu but an NSPanel we draw ourselves (`MenuBarShell`
/// says why): NOTHING here comes from the system — not the separators, not the titles, not the
/// chrome, not the hover highlight. Everything that follows is therefore drawn by hand, including
/// what a native menu would have given for free.
///
/// Corollary: every row manages its own hover (`MenuRowContainer`). That is the price of
/// the window — and its reason for being: a click closes nothing there, so the
/// transition spinner can be shown in place.
///
/// These views observe `MiloStore`: as long as the panel is open, they re-render
/// themselves whenever the backend pushes a new state.

/// Row geometry, measured to the pixel on the native **Bluetooth** panel (2x capture,
/// offsets counted from the menu's left edge):
///
///   title            16 pt
///   icon badge       19 pt
///   label            49 pt   ( = 19 + a 26 badge + 4 of gap )
enum MenuRowMetrics {
    /// The panel's width. Fixed, and not derived from the content: an NSMenu sized itself on
    /// its widest item, a window we draw ourselves has no such rule — without
    /// this value, the panel would shrink onto its labels, which change with the language.
    static let width: CGFloat = 264

    // These values are now the REAL values: the content lives in an NSPanel
    // we draw ourselves, not in an NSMenu. (An NSMenu added its own inset
    // around item views, which forced us to pre-compensate — a trap now extinguished.)

    /// The offset of the titles' and headers' text.
    static let textInset: CGFloat = 15

    /// The offset of a row's content (the icon badge). Measured on "Sound": 14 pt —
    /// that is one point to the LEFT of the titles' text (15 pt). This overhang is deliberate: it
    /// optically aligns the circle, whose edges fall away, with the letters' straight stems.
    static let contentInset: CGFloat = 14

    /// The inset above the title, under the panel's edge.
    ///
    /// Set by comparing INK to INK with "Sound", the only valid comparison: between
    /// the top of a `Text` view and the top of the capitals there is the font's internal
    /// leading, which no declared padding accounts for.
    ///
    /// Measured: the top of "Sound"'s capitals is 16.5 pt from the panel's edge; ours
    /// landed at 20.0 — hence 16.5 − 3.5 = 13. (Do not compare the top of the two
    /// strings' ink: "Milō" has an ascender (`l`) and a macron that rise higher than a
    /// capital. Compare the capital, or the baseline — both give 3.5.)
    static let titleTopInset: CGFloat = 13

    /// A row's vertical inset. The pitch between two rows is `iconSize + 2 ×` this
    /// value: 26 + 6 = 32 pt.
    ///
    /// Was 3.25 (a pitch of 32.5), on the strength of a comment claiming to have
    /// measured it on Bluetooth. Re-measured since, by the gap between badge centres — a
    /// measurement that depends neither on hover nor on a threshold, and which does recover the 32.0
    /// already known from Sound when applied to it:
    ///
    ///   Sound      32.0 · 32.0
    ///   Bluetooth  32.0 × 8 in a row
    ///
    /// The rows are contiguous (the hover boxes touch): pitch = box height.
    static let rowVerticalPadding: CGFloat = 3

    /// The inset of the hover highlight relative to the row's edge.
    static let highlightInset: CGFloat = 5

    /// A TEXT row's vertical inset — the footer (Settings, Quit) and the back row
    /// from the radio list. These rows have no badge: their hover box is set
    /// on the text alone, and not on `iconSize` like a badged row's.
    static let textRowVerticalPadding: CGFloat = 5

    /// The corner radius of the hover highlight.
    ///
    /// Measured on "Sound" by profiling the top-left corner of the hover mask (obtained by
    /// differencing two captures, pointer parked / pointer on the row): its left
    /// edge is only reached 9.0 pt from the top of the box, against 3.5 for our radius of 5.
    ///
    /// Careful, those 9.0 are NOT the radius: in `.continuous` (squircle), the curve
    /// stretches beyond the nominal radius, and the ratio between the two is NOT constant
    /// (measured on our own rendering: 5 → 3.5, but 13 → 12.0). So we calibrate on those
    /// two points — L(0) ≈ 1.0625·r − 1.81 — hence 10 to aim for 9.0.
    ///
    /// Verified afterwards profile against profile, row by row, and not on a single number.
    static let rowHoverCornerRadius: CGFloat = 10

    /// The gap between the badge and the label.
    ///
    /// Measured on "Sound": the label's ink starts 49.0 pt from the panel's edge. The
    /// badge ending at 40 (14 + 26), 9.0 pt are left — of which ~0.5 is left side bearing on the
    /// glyph, hence 8.5.
    ///
    /// Was 4, which stuck the text to the badge (ink at 44.5). This file's old comment
    /// did its arithmetic with a badge at 19 pt (49 = 19 + 26 + 4), whereas
    /// `contentInset` is 14: that is where the error came from.
    static let iconTextGap: CGFloat = 8.5

    static let iconSize: CGFloat = 26

    /// The active badge's color.
    ///
    /// `Color.accentColor` alone renders too dark: measured through the glass on a white background,
    /// it gives RGB(52, 120, 246) where "Sound" displays RGB(63, 143, 247).
    ///
    /// We lighten it towards a **light cyan**, and not towards white: white raises
    /// red far faster than green (measured at 12%: RGB(79, 138, 249) — red 16 too
    /// high). What is needed above all is green, hence cyan. The system accent stays the base: the
    /// color still follows the user's setting.
    static let activeCircleColor = Color.accentColor
        .mix(with: Color(red: 0.2, green: 1, blue: 1), by: 0.18)

    /// The inactive badge's color (grey).
    ///
    /// `.tertiary` (a FOREGROUND style, meant for text) composites BLACK at ~25%
    /// in light appearance once used as a background — markedly darker than the grey badge
    /// of "Sound", which is a plain system fill, not dimmed text. So we take
    /// `tertiarySystemFill`, of the same register as `rowHoverFill` (`secondarySystemFill`)
    /// just below, and which also switches between light and dark on its own.
    static let inactiveCircleFill = Color(nsColor: .tertiarySystemFill)

    /// A hovered row's background.
    ///
    /// And not `.selection`, which is tinted with the accent (blue): that is not what Sound or
    /// Bluetooth do. Measured by differencing two captures of the SAME panel, one with the pointer parked
    /// far away, the other with the pointer on the row. The highlight being a translucent layer,
    /// `out = (1−a)·background + a·C`, we recover `a` and `C` by regressing one on the other:
    /// slope 0.9195 and intercept 20.43, identical on all three channels (R² = 0.994 over
    /// backgrounds ranging from 8 to 231) — that is WHITE at 8%.
    ///
    /// This is exactly `secondarySystemFill` (white at 7.84% in dark). We take the semantic
    /// color rather than the literal: in light appearance it switches on its own to
    /// BLACK at 7.84%, where a hardcoded white would be invisible.
    static let rowHoverFill = Color(nsColor: .secondarySystemFill)

    /// The size of the two speaker icons that frame the slider.
    ///
    /// This time measured, and not set by eye (the old measurement was broken). "Sound"
    /// uses the same symbols as we do (`speaker.fill`, `speaker.wave.3.fill`): the ink
    /// is therefore proportional to the point size, and the ratio can be read off directly.
    ///
    ///                        Sound        ours at 13     ratio
    ///   speaker.fill        9.0 × 13.5    7.5 × 11.0     1.20 / 1.23
    ///   speaker.wave.3.fill 20.5 × 15.0   17.0 × 12.5    1.21 / 1.20
    ///
    /// Four concordant measurements → 13 × 1.21 ≈ 15.7.
    static let sliderIconSize: CGFloat = 15.5

    /// The gap between an icon and the track.
    ///
    /// This is not the gap you SEE: the `Slider` adds ~4.5 pt of internal padding before
    /// the track starts. Measured, the ink → track gap is therefore `sliderIconGap + 4.5`.
    /// At 4, you read 8.5 pt on screen.
    static let sliderIconGap: CGFloat = 4
}

/// The panel's own geometry, measured on "Sound" (2x captures, on solid backgrounds).
enum PanelMetrics {
    /// Corner radius: 36 px at 2x on the Sound panel, against 29 px for an NSMenu —
    /// that is the difference the eye spots immediately.
    static let cornerRadius: CGFloat = 18

    /// The gap between the bottom of the menu bar and the top of the panel. Measured on "Sound":
    /// 0.5 pt — the panel is all but flush under the bar. (Menu bar: 34 pt;
    /// top of the "Sound" panel: 34.5 pt.)
    static let topGap: CGFloat = 0.5

    /// The offset of the panel's left edge relative to the INK of the menu bar's
    /// icon.
    ///
    /// Measured on "Sound": glyph ink at 1407.5 pt, its panel's left edge at
    /// 1396.0 — that is 11.5 pt to the left.
    ///
    /// The system, for its part, anchors on the button's FRAME (panel edge = frame edge
    /// − 10 pt; verified on Sound AND on Bluetooth, whose frames do not even have
    /// the same width). We cannot take that rule as is: the system buttons
    /// are fitted to their glyph, ours is not (a 40 pt frame for 14 pt of ink).
    /// Anchoring on the ink gives the same result TO THE EYE, which is what we are after.
    static let panelLeftFromIconInk: CGFloat = 11.5

    /// The inset under the last row, above the panel's bottom edge.
    ///
    /// Measured on "Sound": 5 pt between the bottom of the last row's BOX (the one the
    /// highlight draws) and the panel's edge.
    ///
    /// Only holds for a last row of TEXT — that is the only case we can measure,
    /// Sound and Bluetooth both ending on a "Settings…". For us, that is the case
    /// on option-click, when the footer (Settings / Quit) is displayed.
    static let bottomInset: CGFloat = 5

    /// The inset under the last row when that row carries a BADGE (Equalizer, without the
    /// footer) rather than text.
    ///
    /// A badged row is taller (32 pt against ~22) and its disc stops
    /// `rowVerticalPadding` (3 pt) from the bottom of its box: at an equal inset, the panel seems to
    /// close in on the disc. No system module ends on such a row — so there is
    /// nothing to measure, and this value is an acknowledged by-eye setting.
    /// (Tuned with Léo: 8 → 10, that is 13 pt under the Equalizer disc.)
    static let bottomInsetIconRow: CGFloat = 10

    /// The appear and disappear fades, like "Sound": brisk on opening, slower
    /// on closing.
    static let fadeInDuration: TimeInterval = 0.10
    static let fadeOutDuration: TimeInterval = 0.22

    /// The minimum margin from the screen's edge.
    static let screenEdgeMargin: CGFloat = 8

    // MARK: Transition between routes (root ↔ radio stations)
    //
    // The panel has no native submenus: the station list REPLACES the root content.
    // The switch is therefore a morph — the panel's height goes from one to the other while
    // the two contents cross-fade. The duration and the curve live in `MenuBarShell`, which
    // drives the timer; only the fade's thresholds, a matter for the view, remain here.

    /// The progress at which the outgoing view has finished fading out.
    static let routeFadeOutEnd: CGFloat = 0.42

    /// The progress at which the incoming view starts to appear. Below `routeFadeOutEnd`, then:
    /// the two overlap by a hair, just enough that there is no empty instant.
    static let routeFadeInStart: CGFloat = 0.34

    /// The maximum height of the panel's CONTENT: everything the screen can display between the bottom
    /// of the menu bar and the bottom edge of the usable area (Dock included, `visibleFrame`
    /// already deducting it), keeping the same margin as elsewhere.
    ///
    /// Without this cap, nothing bounded the panel's growth: the window follows the
    /// SwiftUI content's intrinsic size, and beyond twenty-odd radio favourites it ran off
    /// the bottom of the screen. It is the content itself that complies (`MiloPanelView`), the station
    /// list being its only elastic element — as Bluetooth does when the
    /// devices are numerous.
    ///
    /// A WHOLE number, and rounded DOWN: the content's height has to stay integral so that the
    /// sub-pixel alignment lands right (see `shadowMargin`), and rounding up would push
    /// past the cap by the fraction of a point just added.
    ///
    /// The shadow's transparent margin does not enter the calculation: it paints nothing
    /// and can run off the screen without harm (`constrainFrameRect` is neutralized).
    static func maxContentHeight(on screen: NSScreen?) -> CGFloat {
        guard let screen else { return .greatestFiniteMagnitude }
        let available = screen.visibleFrame.height - topGap - screenEdgeMargin
        return max(0, available.rounded(.down))
    }

    // MARK: Drop shadow
    //
    // Measured on a white background: "Sound"'s reaches 48.5 pt while darkening the white
    // by only 48 at the edge. NSWindow's default shadow reaches 15.5 pt and darkens by 72 —
    // three times too short and far too hard. Hence a hand-drawn shadow.

    static let shadowRadius: CGFloat = 23
    static let shadowOpacity: Float = 0.32
    static let shadowOffsetY: CGFloat = 3

    /// The transparent margin around the panel, so the shadow has room to spread.
    /// Must exceed `shadowRadius + shadowOffsetY` (26).
    ///
    /// The half point is not decorative: it is what makes the sub-pixel alignment possible.
    /// AppKit rounds both the origin AND the size of windows to whole points; the panel's
    /// edges being `origin + margin`, a whole margin condemns them to land on
    /// integers — yet both targets measured on "Sound" are half-integers (top 34.5;
    /// left edge 11.5 from the icon's ink, that is 1360.5 for us). With 60.5 and a
    /// whole content height (see `positionPanel`), both land right.
    static let shadowMargin: CGFloat = 60.5
}

// MARK: - Titles

/// The menu's title and the section headers.
///
/// Drawn by hand, and not with `NSMenuItem.sectionHeader(title:)`: an NSMenu's native
/// header renders **everything** grey and small, whereas the system modules (Sound,
/// Bluetooth, Wi-Fi) distinguish their title from their sections. Values measured to the pixel
/// on the "Sound" panel (2x captures):
///
///                        capital    ink peak    stroke density
///   the "Sound" title      21 px       232          0.47   → white, bold
///   the "Output" header    18 px       173          0.49   → grey, bold
///   a row's label          19 px       232          0.41   → white, regular
///
/// In other words: the title is at the labels' size but bold; the header is
/// smaller, grey, and bold as well.
struct MenuTitle: View {
    let text: String

    var body: some View {
        Text(text)
            // `.semibold`, not `.bold`: in bold, the counter of the "o" closes up and
            // the title no longer looks like "Bluetooth" or "Sound".
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, MenuRowMetrics.textInset)
            .padding(.top, MenuRowMetrics.titleTopInset)
            // Tuned with Léo: 2 → 4, that is 13 pt between the title's baseline and the top
            // of the speaker's ink (against 11).
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

// MARK: - Now playing

/// The geometry of the "now playing" row. With no system reference to measure (no native module
/// has an equivalent): chosen values, like the multiroom sub-section's controls.
private enum NowPlayingMetrics {
    static let artworkSize: CGFloat = 48
    static let artworkCornerRadius: CGFloat = 8
    /// The cover art → text gap.
    static let artworkTextGap: CGFloat = 10

    /// A rounded square badge in a corner of the cover art — see `NowPlayingInfo.badgeArtworkURL`.
    static let badgeSize: CGFloat = 16
    static let badgeCornerRadius: CGFloat = 6
    /// The badge's inset from the cover art's bottom and right edges.
    static let badgeInset: CGFloat = 2
    /// The minimum text → buttons gap, before the fade hides it.
    static let textControlsGap: CGFloat = 8

    /// The fade's length — the same value as the multiroom names (`MultiroomMetrics.nameFade`),
    /// for an identical rendering.
    static let textFade: CGFloat = 14
    /// The font size shared by the title and the artist — the two are now distinguished
    /// only by weight and color.
    static let textSize: CGFloat = 12

    /// A control button's hit target (play/pause, next, Radio stop/restart).
    static let controlSize: CGFloat = 22
    static let controlGap: CGFloat = 7
    /// A control icon's default font size (`forward.fill`).
    static let controlIconSize: CGFloat = 13
    /// `play.fill`/`pause.fill`/`stop.fill` fill their bounding box less than
    /// `forward.fill` (a solid triangle against a double chevron + bar): at the same point size,
    /// they look markedly smaller. Corrected by giving them a larger size rather
    /// than by changing the hit target (`controlSize`), which stays the same for both.
    static let playPauseIconSize: CGFloat = 20

    /// The width of the title/artist column, sized for the number of buttons ACTUALLY
    /// displayed by the active source — not a fixed space sized for the worst case. Radio
    /// (a single stop/restart button) and the passive receivers (no button: AirPlay, DLNA,
    /// Qobuz) therefore gain more room for the title than Spotify/music library/CD/TIDAL
    /// (play-pause + next).
    static func textWidth(controlCount: Int) -> CGFloat {
        let controlsWidth = controlCount == 0 ? 0
            : CGFloat(controlCount) * controlSize + CGFloat(controlCount - 1) * controlGap
        let rowContentWidth = MenuRowMetrics.width - 2 * MenuRowMetrics.contentInset
        return rowContentWidth - artworkSize - artworkTextGap - textControlsGap - controlsWidth
    }
}

/// The "now playing" banner: 48×48 cover art on the left, title then artist in the middle, playback
/// controls on the right when the state's `controls` list offers any. Displayed between the panel's title and
/// the volume slider as soon as a song (or, for Radio, a station) is loaded — see
/// `MiloStore.nowPlaying` for the field mapping.
struct NowPlayingRow: View {
    @Bindable var store: MiloStore
    let info: NowPlayingInfo

    /// Radio has neither a real pause nor a next song: a single stop/restart button, distinct from
    /// the generic play-pause/next pair of the other sources — see
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
        if store.state?.source == "radio" { return store.radioSupportsToggle ? .radioToggle : .none }
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
                        systemName: store.radioCanStop ? "stop.fill" : "play.fill",
                        iconSize: NowPlayingMetrics.playPauseIconSize,
                        size: NowPlayingMetrics.controlSize,
                        action: store.toggleRadioNowPlaying
                    )

                case .pauseResume(let hasNext):
                    NowPlayingControlButton(
                        systemName: store.nowPlayingCanPause ? "pause.fill" : "play.fill",
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

/// A control button (play/pause, next, stop/restart) — the same idiom as the multiroom
/// sub-section's `MuteButton`.
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

/// The "now playing" row's cover art. The same idiom as `StationFavicon` (direct loading,
/// with no shared cache): this view never moves within the tree — it is neither recreated by a
/// `ForEach` nor swapped between two morph layers — so `AsyncImage` only reloads
/// when the URL really changes (a new song), never on every render.
private struct NowPlayingArtwork: View {
    let url: URL?
    /// The station's logo as a badge — see `NowPlayingInfo.badgeArtworkURL`. `nil` everywhere
    /// except Radio on a recognized song with its own cover art.
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

/// The station's logo itself, a rounded square, placed well centred in the hole cut out by
/// `NowPlayingArtwork` — see `NowPlayingInfo.badgeArtworkURL`.
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
            onChange: { store.setVolume($0) },
            onHoldChange: { increase, isHolding in
                if isHolding {
                    store.hotkeyManager?.beginButtonHold(direction: increase ? "up" : "down")
                } else {
                    store.hotkeyManager?.endButtonHold()
                }
            }
        )
        .padding(.horizontal, MenuRowMetrics.contentInset)
        .padding(.vertical, 4)
        .frame(width: MenuRowMetrics.width)
    }
}

// MARK: - Audio source

struct SourceRow: View {
    @Bindable var store: MiloStore
    let source: AudioSourceDescriptor
    var showsChevron: Bool = false
    var onChevron: (() -> Void)? = nil

    @State private var isHovering = false

    /// A press-and-hold on the active source: closes it. `@GestureState` resets itself to false
    /// as soon as the finger lifts or the gesture is cancelled (movement beyond
    /// `maximumDistance`) — nothing to clean up by hand.
    @GestureState private var isHoldPressing = false
    /// A timestamp rather than a boolean: the release click following the press has to be swallowed,
    /// but if it never arrives, a flag would stay armed and would eat the next click.
    @State private var holdFiredAt: Date?

    /// Aligned on the web frontend's HOLD_DELAY (useDockAppHold.js).
    private static let holdDelay: TimeInterval = 0.5

    /// The "Mac" source needs the roc-vad driver. Without it, the row stays visible but
    /// leads to Settings rather than failing silently.
    private var needsSetup: Bool {
        source.id == "mac" && !store.isRocVADReady
    }

    /// Only the active source closes on press-and-hold, and not during a transition
    /// already in flight.
    private var canCloseByHold: Bool {
        isActive && !isLoading && !needsSetup
    }

    private var isActive: Bool {
        store.state?.source == source.id
    }

    /// A spinner if the backend reports a transition towards this source, OR if a local click
    /// has just gone out (loadingStates, set before the HTTP request).
    private var isLoading: Bool {
        let starting = store.state?.isSourceStarting ?? false
        return (starting && isActive) || store.loadingStates[source.id] == true
    }

    var body: some View {
        MenuRowContainer(isHovering: $isHovering, action: activate) {
            // The transition spinner sits INSIDE the badge.
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
                // The Radio row carries TWO commands: activating the source (the row's
                // body) and opening the stations (the chevron). Unlike Multiroom, activating
                // Radio when it already is does nothing (see the guard in
                // `MiloStore.selectSource`) — so the chevron has to remain the ONLY target for
                // opening the stations; giving it all the empty space to the right of the label would
                // navigate accidentally on the slightest click on the row.
                //
                // Nesting a button inside a button works — the innermost wins within
                // its own area — but here its area stays that of the chevron (plus a little comfort
                // margin), not the whole rest of the row.
                Button { onChevron?() } label: {
                    ChevronCircle()
                        .padding(.horizontal, 6)
                        // Without this, the button moulds itself onto the chevron and its area is only its
                        // ink's height. We stretch it over the row's height, which the source's
                        // badge sets (26 pt).
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        // The content dims during the press to say that something is being prepared. The fade
        // is markedly shorter than the gesture: the row acknowledges it right away, then
        // stays dimmed until it fires. Spread over the 500 ms, it read like a
        // latency rather than a response.
        .opacity(needsSetup ? 0.55 : (isHoldPressing ? 0.35 : 1))
        .animation(.easeOut(duration: isHoldPressing ? 0.15 : 0.12), value: isHoldPressing)
        // `simultaneousGesture` and not `gesture`: MenuRowContainer's button keeps its click,
        // the two coexist. The gesture is only armed on the active source.
        .simultaneousGesture(holdToClose, including: canCloseByHold ? .all : .none)
    }

    private var holdToClose: some Gesture {
        LongPressGesture(minimumDuration: Self.holdDelay)
            .updating($isHoldPressing) { pressing, state, _ in state = pressing }
            .onEnded { _ in
                holdFiredAt = Date()
                store.closeSource(source.id)
            }
    }

    private func activate() {
        // The release that follows a press-and-hold also triggers the button's click:
        // we swallow it so as not to reactivate the source we have just closed.
        if let firedAt = holdFiredAt {
            holdFiredAt = nil
            if Date().timeIntervalSince(firedAt) < Self.holdDelay + 0.1 { return }
        }

        if needsSetup {
            SettingsWindowPresenter.show(store: store)
        } else {
            store.selectSource(source.id)
        }
    }
}

// MARK: - Feature

/// Multiroom, Equalizer.
///
/// The same row as a source, and not a switch: it is the badge that carries the state,
/// blue when the feature is active, grey otherwise — exactly the language of the
/// "Output" section of "Sound", where the current device is a blue badge.
///
/// A `Toggle` additionally put two competing click targets in an already clickable
/// row: clicking the label did nothing, clicking the switch acted.
struct FeatureRow: View {
    @Bindable var store: MiloStore
    let feature: FeatureDescriptor

    /// Multiroom carries, like the Radio row, TWO commands: the body toggles the
    /// feature, the chevron on the right expands the sub-section (zones/clients). The chevron
    /// appears as soon as multiroom is shown as active (`store.canShowMultiroom`), even before
    /// the zones/clients have loaded.
    var showsChevron: Bool = false
    var isExpanded: Bool = false
    var onChevron: (() -> Void)? = nil

    @State private var isHovering = false

    private var isLoading: Bool { store.loadingStates[feature.id] == true }
    private var isOn: Bool { store.displayedToggleState(feature.id) }

    var body: some View {
        MenuRowContainer(isHovering: $isHovering, action: toggle) {
            // The toggle's spinner lives INSIDE the badge (like the sources'), not on the right.
            RowIcon(icon: feature.icon, isActive: isOn, isLoading: isLoading)

            Text(feature.title)
                .font(.system(size: 13))
                .lineLimit(1)

            if showsChevron {
                // The same construction as the Radio chevron (SourceRow): the expand button
                // takes all the empty space to the right of the label, not just the chevron's ink —
                // a wide target for a command used as much as the row.
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

    /// The click is ignored during the toggle — which is what the switch's `.disabled(isLoading)`
    /// did, and which a clickable row no longer gives for free.
    private func toggle() {
        guard !isLoading else { return }
        store.toggleFeature(feature.id)
    }
}

// MARK: - Multiroom sub-section (inline accordion)

/// The geometry of the multiroom sub-section, in macOS-style "inset-grouped" cards.
private enum MultiroomMetrics {
    /// The cards' background, MEASURED TO THE PIXEL on the "Sound" panel expanded under AirPods (2× capture):
    /// glass at 32,32,32, inset at 52,52,52 — that is a **white veil at 9%** (identical on all
    /// three channels), a background LIGHTER than the glass. Dynamic so as to stay right in light
    /// (switching to black at 9%), the way `secondarySystemFill` inverts white/black.
    static let cardFill: Color = {
        let ns = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: dark ? 1 : 0, alpha: 0.09)
        }
        return Color(nsColor: ns)
    }()

    /// The gap of glass between the Multiroom row and the first card. Measured on "Sound": 5 pt.
    static let gapAboveCards: CGFloat = 5
    /// The cards' margin from the panel's edges.
    static let cardHInset: CGFloat = 10
    /// The gap of glass between two distinct cards (a zone, a standalone client).
    static let cardSpacing: CGFloat = 6
    static let cardCornerRadius: CGFloat = 9

    /// A row's internal insets within a card.
    static let rowHInset: CGFloat = 10
    static let rowVInset: CGFloat = 6

    /// A row's LEADING inset, set so that the NAME (after the badge and the gap) lands
    /// at the same x-coordinate as the parent row's "Multiroom" label — that is
    /// `contentInset + iconSize + iconTextGap` from the panel's edge. We derive it from the metrics
    /// rather than hardcoding it: `cardHInset + rowLeadingInset + iconSize + gap` must
    /// equal that label, hence the subtraction. (The right side keeps `rowHInset`.)
    static let rowLeadingInset: CGFloat =
        MenuRowMetrics.contentInset + MenuRowMetrics.iconSize + MenuRowMetrics.iconTextGap
        - cardHInset - iconSize - gap

    static let iconSize: CGFloat = 18
    static let muteIconSize: CGFloat = 22
    /// The icon → name, and name → controls gap.
    static let gap: CGFloat = 7

    /// The FIXED width of the name column, so that every slider (zone as well as client)
    /// aligns on the same width. A longer name is faded (a gradient) rather than cut off
    /// by "…". Deliberately tight so as to leave as much room as possible for the volume bars:
    /// slightly long names go off in a fade, and that is accepted.
    static let nameWidth: CGFloat = 64
    /// The fade's length at the end of a name.
    static let nameFade: CGFloat = 14

    /// The minimum interval between two network sends during a slider drag. On every
    /// pixel we refresh the thumb locally, but we only send to the backend at this rate
    /// (the final value always goes out on release). Without this, the flood of PATCHes makes
    /// the backend rebroadcast continuously and the whole section re-renders → a jerky drag.
    static let sendThrottle: TimeInterval = 0.06
}

/// The expandable sub-section under the Multiroom row, in **distinct cards**: one card per
/// zone (header + hairline + member clients) and one card per standalone client. Everything is on
/// one line (icon + name + slider + mute) and left-aligned, with no indentation.
struct MultiroomSection: View {
    @Bindable var store: MiloStore

    var body: some View {
        VStack(spacing: MultiroomMetrics.cardSpacing) {
            // Multiroom is on but the registry has not arrived yet (or briefly emptied on a
            // reconnection): the sub-section stays reachable, and says it is waiting.
            if store.multiroomDisplayItems.isEmpty {
                MultiroomCard {
                    MultiroomLoadingRow()
                }
            }
            ForEach(store.multiroomDisplayItems) { item in
                switch item {
                case .zone(let zone, let clients):
                    MultiroomCard {
                        MultiroomRow(store: store, kind: .zone(zone, clients))
                        // A SINGLE hairline, between the zone's header and its clients — not between
                        // each client.
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

/// A rounded grey card that groups its rows.
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

/// A native hairline between the zone's header and its clients: the card's full width, with a
/// slight SYMMETRICAL inset on each side.
private struct MultiroomRowSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, MultiroomMetrics.rowHInset)
    }
}

/// The placeholder row while the zones/clients load: a spinner in the icon slot, the text in the
/// name's column — the same geometry as `MultiroomRow`.
private struct MultiroomLoadingRow: View {
    var body: some View {
        HStack(spacing: MultiroomMetrics.gap) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
                .frame(width: MultiroomMetrics.iconSize, height: MultiroomMetrics.iconSize)

            Text(L("multiroom.loading_systems"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)
        }
        .padding(.leading, MultiroomMetrics.rowLeadingInset)
        .padding(.trailing, MultiroomMetrics.rowHInset)
        .padding(.vertical, MultiroomMetrics.rowVInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A card row: icon + name + slider + mute, on a single line. Serves both
/// a zone (a master slider in DELTA, muting all its clients) and a client (an absolute slider).
private struct MultiroomRow: View {
    @Bindable var store: MiloStore
    let kind: Kind

    enum Kind {
        case zone(MultiroomZone, [MultiroomClient])
        case client(MultiroomClient)
    }

    /// The last value SENT during a drag (the base for the next delta for a zone,
    /// coalescing for a client). `nil` outside a drag.
    @State private var lastSent: Double?
    /// The last scrubbed value (sent or not) — sent on release so as not to lose
    /// the last movement when it falls inside a throttled interval.
    @State private var pending: Double?
    /// The timestamp of the last network send, for the throttle.
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
        // The left set to align the NAME under the "Multiroom" label (see `rowLeadingInset`);
        // the right at the normal `rowHInset`.
        .padding(.leading, MultiroomMetrics.rowLeadingInset)
        .padding(.trailing, MultiroomMetrics.rowHInset)
        .padding(.vertical, MultiroomMetrics.rowVInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Type-dependent derivations

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

    /// The slider only has a grip if the item is reachable AND drives its own volume.
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

    /// Called on every notch of the drag. The thumb already follows locally (see
    /// `MultiroomVolumeSlider`); here we only THROTTLE the network sends.
    private func scrub(_ newValue: Double) {
        pending = newValue
        let now = Date()
        if now.timeIntervalSince(lastSendAt) >= MultiroomMetrics.sendThrottle {
            flushSend(newValue)
            lastSendAt = now
        }
    }

    /// On release: we send the last value (in case it fell inside a throttled
    /// interval), then reset the tracking.
    private func endScrub() {
        if let pending { flushSend(pending) }
        pending = nil
        lastSent = nil
        lastSendAt = .distantPast
    }

    /// Client: absolute volume. Zone: a delta from the last value SENT (the backend has
    /// no zone volume, it passes the delta on to its clients). Since `lastSent` only moves
    /// on an actual send, throttling loses no movement — the next delta catches it up.
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

/// A FIXED-width item name, so as to align every slider column. A name that is too long
/// is not cut off by "…" but **faded** out in a gradient on its right edge — cleaner, and
/// it is the language of macOS (Music, Settings). The fade only covers the last few points
/// of the width: a short name, which does not reach that zone, is unaffected.
private struct FadingText: View {
    let text: String
    let weight: Font.Weight
    var size: CGFloat = 13
    let dimmed: Bool
    /// The text column's frozen width — caller by caller: the multiroom names
    /// align on `MultiroomMetrics.nameWidth`, the "now playing" row reserves room for the
    /// play/pause and next buttons (see `NowPlayingRow`).
    let width: CGFloat
    /// The fade's length at the end of the text.
    let fade: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            // The NATURAL size (no "…" truncation), then set in a fixed width and
            // clipped: the overflowing text is masked, and the gradient makes it disappear in a
            // fade instead of a hard edge.
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

/// The mute button: a speaker that switches to `speaker.slash` once muted.
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

/// A multiroom item's volume slider: SwiftUI's native `Slider` (like this branch's global
/// volume), in `.small` for "Sound"'s thin track.
///
/// During a drag, we display the LOCAL value (`dragValue`) and call `onScrub`
/// on every notch; on release we hand control back to the store's live value (WebSocket echoes).
/// This keeps the server echo, one round trip behind, from making the thumb jump.
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

// MARK: - Radio station (sub-menu)

struct RadioStationRow: View {
    @Bindable var store: MiloStore
    let station: RadioStation

    @State private var isHovering = false

    private var isPlaying: Bool { store.playingRadioStationId == station.id }
    private var isLoading: Bool { store.radioStationLoadingId == station.id }

    /// The same footprint for all three states (spinner, stop, play) so that they land
    /// at exactly the same position — otherwise the spinner (scaled) and the
    /// SF symbol (sized by its font) do not centre in the same place.
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

/// A 32×32 rounded-corner thumbnail for a sub-level row (a radio station, a music library
/// artist/album/song…), with an SF Symbol fallback for entries with no image
/// (many radio favourites have none; not every search result has
/// cover art). The image is recropped `.fill` then clipped to a rounded square, like the favourites
/// grid of the Milō frontend.
private struct MenuThumbnail: View {
    let url: URL?
    let fallbackSystemImage: String

    private let size: CGFloat = 32
    private let cornerRadius: CGFloat = 7

    /// The image already loaded by THIS view. The shared cache serves recreated views, this one avoids
    /// re-reading it on every render pass.
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

/// The `MenuThumbnail` thumbnails already loaded, kept in memory for the session's duration —
/// radio station logos as well as search result cover art.
///
/// URLSession's HTTP cache is not enough: a recreated `AsyncImage` starts again from an
/// ASYNCHRONOUS load pass even when the bytes are already cached, and therefore shows its placeholder
/// for a frame or two. And the station list is recreated on every entry — and once
/// more when the transition hands over from its overlay to the main layer: the
/// logos blinked at the precise moment the switch has to be smooth. An image already seen is
/// now rendered SYNCHRONOUSLY.
///
/// A few dozen 32 pt thumbnails: the cache does not need to be bounded.
@MainActor
private final class FaviconCache {
    static let shared = FaviconCache()

    private var images: [URL: Image] = [:]

    func image(for url: URL) -> Image? { images[url] }

    func store(_ image: Image, for url: URL) { images[url] = image }
}

/// The row displayed when Radio has no favourites.
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

// MARK: - Music library search

/// The search field: a magnifier icon + a `TextField`, without macOS's default chrome (border,
/// background) since it is the panel's glass that serves as the background here. Takes focus as soon as the
/// route is entered, like a Spotlight search — the panel already forces `canBecomeKey`/
/// `makeKey()` (`MenuBarShell`), so there is nothing more to do on the window side for this to work.
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

/// A static status row (the prompt before searching, "no results") — the same dressing as
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

/// The body of the search sub-level: the field lives apart (`MiloPanelView.musicLibraryContent`),
/// this view only carries what follows — prompt / loading / no results / the three
/// result sections. The same precedence arbitration as `SearchView.vue`: loading
/// hides any previous results rather than leaving them in the background during the
/// next debounce.
struct MusicLibrarySearchResultsList: View {
    @Bindable var store: MiloStore

    private var results: MusicLibrarySearchResults { store.musicLibrarySearchResults }

    private var hasQuery: Bool {
        !store.musicLibrarySearchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the sub-level shows while nothing is typed: the recent albums, failing that
    /// the original prompt — an empty library, or a backend that has not (yet) answered. The same
    /// loading > empty > list arbitration as the search results, and the ScrollView
    /// carries the same bottom inset.
    @ViewBuilder
    private var showcase: some View {
        if store.musicLibraryShowcaseLoading {
            MusicLibraryLoadingRow()
        } else if store.musicLibraryShowcaseAlbums.isEmpty {
            MusicLibraryStatusRow(text: L("musicLibrary.search.prompt"))
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    MenuSectionHeader(text: L(store.musicLibraryShowcaseIsRecentlyAdded
                                              ? "musicLibrary.showcase.added"
                                              : "musicLibrary.showcase.played"))
                    ForEach(store.musicLibraryShowcaseAlbums) { album in
                        MusicLibraryAlbumRow(store: store, album: album)
                    }
                }
            }
            .contentMargins(.bottom, PanelMetrics.bottomInset, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    var body: some View {
        if !hasQuery {
            showcase
        } else if store.musicLibrarySearchLoading {
            MusicLibraryLoadingRow()
        } else if results.isEmpty {
            MusicLibraryStatusRow(text: L("musicLibrary.search.noResults"))
        } else {
            // Like `radioContent`: the ScrollView is the sub-level's only elastic element,
            // so it carries the bottom inset itself (see `bottomInset(for:)`).
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

/// The artist page's album list (`MiloPanelView.musicLibraryArtistContent`) — the same
/// loading/empty/list arbitration as `MusicLibrarySearchResultsList`, but with no prompt (we
/// arrive on an explicit intent already, not an empty field to fill).
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

/// The album page's song list (`MiloPanelView.musicLibraryAlbumContent`) — the same
/// construction as `MusicLibraryArtistAlbumsList`. These songs (and not those of any
/// search in progress) form the playback CONTEXT passed to each `MusicLibrarySongRow`.
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

/// An artist row — tappable: leads to the artist's page (their albums), the same chevron as the
/// "Music Library" row itself. Unlike `SourceRow`/Radio, the row's body
/// has no second role to protect (activating the source, etc.): the whole row navigates,
/// the chevron is only a visual marker of the navigation's direction.
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

/// An album row — tappable, for the same reason as `MusicLibraryArtistRow`: leads to the album's
/// page (its songs), whether displayed from a search or from an artist's page.
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

/// A song row — the ONLY one of the three whose tap acts directly rather than navigating:
/// it starts playback (`play_context` with `context`, started at the index of the song touched),
/// replacing whatever is already playing, like a tap on a radio station. `context` is the list
/// the tap came from — the search results, or the open album's songs — not
/// always `store.musicLibrarySearchResults.songs`.
///
/// When THIS song is the one currently loaded by the music library, the icon on the
/// right switches to play/pause (instead of the plain hover marker) and the tap toggles play/
/// pause instead of restarting `play_context` from the beginning — the same button, the same gesture as
/// the root's "now playing" row (`NowPlayingRow`/`toggleNowPlayingPause`).
struct MusicLibrarySongRow: View {
    @Bindable var store: MiloStore
    let song: MusicLibrarySong
    let context: [MusicLibrarySong]

    @State private var isHovering = false

    private var isLoading: Bool { store.musicLibrarySongLoadingId == song.id }
    private var isCurrent: Bool { store.isCurrentMusicLibrarySong(song) }
    private var isPlayingNow: Bool { isCurrent && (store.nowPlaying?.isPlaying ?? false) }

    /// The same footprint for the spinner and the play/pause icon as `RadioStationRow`, for the same
    /// reason: so that they land at exactly the same position.
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
                    // Loaded but paused: the icon invites a restart, like the root's
                    // "now playing" row.
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

// MARK: - Disconnected state

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

// MARK: - Shared building blocks

/// A clickable row with its hover highlight.
///
/// The panel being a window we draw ourselves, no highlight comes from the
/// system: every row paints its own, on its own hover.
private struct MenuRowContainer<Content: View>: View {
    @Binding var isHovering: Bool
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: MenuRowMetrics.iconTextGap) {
                content
            }
            // The highlight is inset by `highlightInset`; the content nevertheless has to
            // start at `contentInset` from the menu's edge, hence the difference.
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

/// The "see the stations" chevron of the Radio row.
///
/// Visually IDENTICAL to the Multiroom chevron (`ExpandChevron`) at rest: a bare chevron, not
/// badged, at the same size and the same tint. The only difference is the behaviour — this one
/// is static and always points right (it LEADS ELSEWHERE, to the station list), where
/// Multiroom's swings round as it expands in place.
private struct ChevronCircle: View {
    var body: some View {
        Image(systemName: "chevron.right")
            // MEASURED TO THE PIXEL on the "AirPods Pro" chevron of the "Sound" panel (2× capture): ink
            // ~10.5 × 6 pt, stroke ~1.5 pt — a THIN chevron (`.regular`), not dense. It is the weight,
            // not the size, that distinguishes it; `.semibold` made it heavy and dark.
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            .padding(.trailing, 2)
    }
}

/// The Multiroom row's expand chevron.
///
/// The same bare chevron as the Radio row (`ChevronCircle`), but animated: Radio LEADS ELSEWHERE (another
/// view) and stays fixed pointing right, where this one expands IN PLACE. This is exactly the language
/// of the "Sound" panel under AirPods — a chevron pointing right when closed, down when open.
private struct ExpandChevron: View {
    let isExpanded: Bool

    /// The rotation and the "pulse" (scale + opacity) are LOCAL state, purely graphical:
    /// neither affects the row's size, so there is no risk of making the window jump
    /// (unlike a `withAnimation` on `multiroomExpanded`, cf. `toggleMultiroom`).
    @State private var rotated = false
    @State private var faded = false

    var body: some View {
        Image(systemName: "chevron.right")
            // Identical to the Radio chevron (`ChevronCircle`): a thin `.regular` chevron measured on the
            // "AirPods Pro" chevron of the "Sound" panel.
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            // +90° clockwise: a closed ">" swings to an open "⌄".
            .rotationEffect(.degrees(rotated ? 90 : 0))
            // The chevron shrinks + fades out, changes direction off-screen, then grows back + reappears
            // at its new position — rather than a bare in-place rotation.
            .scaleEffect(faded ? 0.4 : 1)
            .opacity(faded ? 0 : 1)
            .padding(.trailing, 2)
            .onAppear { rotated = isExpanded }
            .onChange(of: isExpanded) { _, newValue in
                // Two CHAINED phases, not superimposed: the `completion:` guarantees that phase 2
                // only starts once phase 1 has finished. Without it, SwiftUI would see `faded` go to
                // `true` then `false` within the same pass and would never animate the fade-out.
                //   Phase 1: shrink + fade out.
                //   Phase 2: swing the direction round OFF-SCREEN (the chevron is invisible), then grow back +
                //   reappear — so the new chevron "arrives" already turned.
                withAnimation(.easeIn(duration: 0.18)) {
                    faded = true
                } completion: {
                    rotated = newValue
                    withAnimation(.spring(duration: 0.45)) { faded = false }
                }
            }
    }
}

/// The icon badge: accent when active, grey otherwise — the same visual language as the
/// "Output" section of the Sound panel.
///
/// During a load, the spinner replaces the icon INSIDE the badge (instead of showing
/// to the right of the row), for the sources as well as the features.
private struct RowIcon: View {
    let icon: SourceIcon
    let isActive: Bool
    var isLoading: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? AnyShapeStyle(MenuRowMetrics.activeCircleColor)
                               : AnyShapeStyle(MenuRowMetrics.inactiveCircleFill))

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.85)
                    // `.tint` changes nothing here: AppKit's spinning indicator
                    // (`NSProgressIndicator` in `.spinning` style) ignores the tint and always draws
                    // itself according to the effective appearance — black in light, white in dark.
                    // On the active (blue) badge we need white in BOTH appearances,
                    // so we force the subtree into dark appearance to get that white;
                    // on the grey badge, the default black/white is already legible.
                    .colorScheme(isActive ? .dark : colorScheme)
            } else {
                icon.image
                    .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
        }
        .frame(width: MenuRowMetrics.iconSize, height: MenuRowMetrics.iconSize)
    }
}


// MARK: - Back from a sub-level

/// A TITLE row, but clickable: it is set on `textInset` / `titleTopInset` and carries the
/// same semibold as a `MenuTitle` — no badge, hence no `MenuRowContainer`, whose
/// insets start from `contentInset`.
///
/// It lights up on hover like every other clickable row in the panel. Its box is
/// built by hand, exactly like `FooterRow`'s: same fill, same radius, same
/// insets — the only difference is that it aligns on the titles' text (15 pt) and not
/// on the badges (14 pt).
///
/// The text itself does not move: the box extends `textRowVerticalPadding` above it,
/// which is therefore subtracted from the top inset.
///
/// Shared by every sub-level of the panel (radio stations, music library
/// search…) — only `title` changes at the call site.
/// A play button placed to the right of a sub-level's title, when that sub-level has something
/// to start IN FULL: the music library's artist and album pages. `nil`
/// elsewhere (the station list, the search), where the title designates no queue.
struct PanelBackPlayAction {
    /// The queue is being assembled: a spinner in place of the icon.
    var isLoading: Bool
    /// What the icon ANNOUNCES, that is, what the click will do — `true` therefore shows pause.
    var isPlaying: Bool
    var action: () -> Void
}

struct PanelBackRow: View {
    let title: String
    /// Before `onBack` in the parameter list, and not after: the closure the call sites pass as a
    /// trailing closure is the final one, which is only true of the LAST
    /// parameter. Defaults to `nil`, so the sub-levels with no global playback write nothing.
    var play: PanelBackPlayAction? = nil
    let onBack: () -> Void
    @State private var isHovering = false

    /// The same width as `MusicLibrarySongRow`'s end-of-row icons — the header overhangs
    /// precisely their column, and the spinner and the symbol have to land in the same place.
    private let trailingIconSize: CGFloat = 20

    /// The gap between the end of the title and the play icon, in the image of the "now playing"
    /// row's `textControlsGap`: the fade dies there, it never licks the icon.
    private let titleIconGap: CGFloat = 4

    /// The length of the title's end fade — the same value as the "now playing" row's
    /// (`NowPlayingMetrics.textFade`) and as the multiroom names' (`MultiroomMetrics.nameFade`),
    /// for an identical rendering from one end of the panel to the other.
    private let titleFade: CGFloat = 14

    var body: some View {
        Button(action: onBack) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))

                // The title takes ALL the remaining room, instead of its natural width followed
                // by a `Spacer`: it is that width the fade comes to bite into. An album or artist
                // name is arbitrarily long, and being cut off by "…" would clash
                // with the rest of the panel, where everything overflows in a gradient.
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    // The NATURAL size then clipped into the available room — the same construction
                    // as `FadingText`, except that here the width is not known in advance
                    // (it depends on the chevron and on whether the icon is present), hence a
                    // fixed-length fade mask rather than its proportional `stops`.
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: titleFade)
                        }
                    )
                    // The icon is placed in an overlay, so it reserves no room: it is this
                    // inset that keeps room for it, and that makes the fade end before it.
                    .padding(.trailing, play == nil ? 0 : trailingIconSize + titleIconGap)
            }
            // In an overlay, and NOT in the HStack: an overlay does not size its host, so
            // the icon cannot make this header taller than those of the sub-levels that
            // have none — nor make it jump when it gives way to the spinner, which
            // is not the same size. The row stays set on its text, always.
            .overlay(alignment: .trailing) {
                if let play {
                    // A button INSIDE the row's button: the innermost wins within its
                    // own area, exactly like `SourceRow`'s chevron. Here that area is
                    // limited to the icon, the rest of the row still goes back.
                    Button(action: play.action) {
                        Group {
                            if play.isLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: play.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: trailingIconSize)
                        // The row's full height as a target, without dictating any:
                        // in an overlay, `.infinity` settles on the host.
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L(play.isPlaying ? "accessibility.pause" : "accessibility.play"))
                }
            }
            .padding(.leading, MenuRowMetrics.textInset - MenuRowMetrics.highlightInset)
            // The title aligns on the TEXT grid (15 pt), but the play icon aligns
            // on the end-of-row icon column (8 pt from the row's edge, see
            // `MenuRowContainer`): it caps the play/pause column of the songs just
            // below, and a title inset would offset it by 2 pt.
            .padding(.trailing, play == nil ? MenuRowMetrics.textInset - MenuRowMetrics.highlightInset : 8)
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

// MARK: - Footer (option-click)

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
