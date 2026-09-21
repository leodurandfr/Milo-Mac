import SwiftUI

/// Volume slider: SwiftUI's **native** `Slider`, with no layer on top.
///
/// No forced styling (no `.controlSize(.extraLarge)`, no hidden thumb, no overlaid icon):
/// the system control adopts Liquid Glass on its own when interacted with, and we inherit
/// keyboard support and accessibility without writing a line.
/// The speaker icon sits next to the track, the way the native control does it.
struct VolumeSlider: View {
    @Binding var valueDb: Double
    let range: (minDb: Double, maxDb: Double)
    let onChange: (Double) -> Void
    /// Holding an icon (`true` = increase, `false` = decrease): `true`/`false` for the
    /// second parameter marks the start/end of the press, exactly the two edges needed
    /// to drive the keyboard shortcut's "hold" from a mouse button rather than a key.
    let onHoldChange: (_ increase: Bool, _ isHolding: Bool) -> Void

    /// Icon magnification during the "bounce" that signals an end of the range has been
    /// reached. Returns to 1 on its own once the spring back is done.
    @State private var minIconScale: CGFloat = 1
    @State private var maxIconScale: CGFloat = 1

    /// Arms the bounce only on ENTERING the end of the range, not on every value received
    /// while pinned there (the thumb keeps emitting while held against the stop) — without
    /// this the spring restarts in a loop and never finishes its travel.
    @State private var wasAtMin = false
    @State private var wasAtMax = false

    var body: some View {
        // Two icons frame the track, like the "Sound" panel: a bare speaker on the left,
        // a speaker with waves on the right. They bound the scale and, when clicked, notch
        // the volume by one step — exactly what the keyboard shortcut does, in visible form.
        //
        // Placed AROUND the Slider, in this HStack, rather than via `minimumValueLabel` /
        // `maximumValueLabel`: those labels ignore the font handed to them and size
        // themselves (verified — going from 14 to 10.5 pt changed nothing in the render).
        // Taking them out puts us back in control of their size, and the Slider stays
        // native.
        HStack(spacing: MenuRowMetrics.sliderIconGap) {
            // The step and the accelerating repeat live in `onHoldChange` (wired to
            // `GlobalHotkeyManager` on the caller's side) — no action here: `isPressed`
            // (via the `ButtonStyle`) is the only useful signal, and it carries both the
            // start and the end of the hold.
            Button {} label: {
                Image(systemName: "speaker.fill")
                    .font(.system(size: MenuRowMetrics.sliderIconSize))
                    .scaleEffect(minIconScale)
            }
            .buttonStyle(VolumeIconButtonStyle { isPressed in
                onHoldChange(false, isPressed)
            })
            .accessibilityLabel(L("accessibility.volume_decrease"))

            Slider(value: binding, in: bounds)
                // `.small` thins the track: the default Slider has a 6 px track where
                // "Sound" has only 4.
                .controlSize(.small)
                .accessibilityLabel(L("accessibility.volume_slider"))

            Button {} label: {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: MenuRowMetrics.sliderIconSize))
                    .scaleEffect(maxIconScale)
            }
            .buttonStyle(VolumeIconButtonStyle { isPressed in
                onHoldChange(true, isPressed)
            })
            .accessibilityLabel(L("accessibility.volume_increase"))
        }
        .onChange(of: valueDb) { _, newValue in
            let atMin = newValue <= bounds.lowerBound
            let atMax = newValue >= bounds.upperBound

            if atMin, !wasAtMin { bounce($minIconScale) }
            if atMax, !wasAtMax { bounce($maxIconScale) }

            wasAtMin = atMin
            wasAtMax = atMax
        }
    }

    /// Grows then releases — the same spring as the first pass (the amplitude and the
    /// elastic rebound on the way back were right), but stretched in time: slower rise,
    /// longer pause at the top, slower return.
    private func bounce(_ scale: Binding<CGFloat>) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.35)) {
            scale.wrappedValue = 1.3
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) {
                scale.wrappedValue = 1
            }
        }
    }

    // MARK: - Value

    private var binding: Binding<Double> {
        Binding(
            get: { valueDb.clamped(to: bounds) },
            set: { onChange($0) }
        )
    }

    /// The limits come from the backend and can arrive degenerate (0/0) while the cache
    /// bootstraps — a `Slider` with an empty range crashes.
    private var bounds: ClosedRange<Double> {
        guard range.maxDb > range.minDb else {
            return VolumeDefaults.limitMinDb...VolumeDefaults.limitMaxDb
        }
        return range.minDb...range.maxDb
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Both the color AND the hold signal of the speaker icons, wired to `isPressed` rather
/// than to a `Button` action — a plain tap does not distinguish "start" from "end" of a
/// press, and that is precisely what the keyboard-shortcut-style "hold" needs (see
/// `onHoldChange` on `VolumeSlider`).
///
/// Color: at rest, `.secondary` (the hierarchical style) darkens by compositing with the
/// environment's primary style — visible through the panel's glass, where it renders
/// markedly greyer than in "Sound". `secondaryLabelColor` is the same semantic system
/// color, but applied flat (a single opacity pass, no hierarchical compositing), which is
/// exactly what the native control does. While held, the icon switches to `labelColor` —
/// the same grey at full opacity, hence white in dark appearance. No `withAnimation`: the
/// change follows `isPressed` with no fade, grey the moment it is released, as intended.
private struct VolumeIconButtonStyle: ButtonStyle {
    let onPressedChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(nsColor: configuration.isPressed ? .labelColor : .secondaryLabelColor))
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressedChange(isPressed)
            }
    }
}
