import SwiftUI

/// Slider de volume : le `Slider` **natif** de SwiftUI, sans surcouche.
///
/// Aucun style forcé (pas de `.controlSize(.extraLarge)`, pas de pastille masquée, pas
/// d'icône superposée) : le contrôle système adopte Liquid Glass de lui-même à
/// l'interaction, et on hérite du clavier et de l'accessibilité sans rien écrire.
/// L'icône de haut-parleur est posée à côté du rail, comme le fait le natif.
struct VolumeSlider: View {
    @Binding var valueDb: Double
    let range: (minDb: Double, maxDb: Double)
    let onChange: (Double) -> Void
    /// Maintien d'une icône (`true` = augmenter, `false` = diminuer) : `true`/`false`
    /// pour le second paramètre marque le début/la fin de la pression, exactement les
    /// deux bords qu'il faut pour piloter le "hold" du raccourci clavier depuis un
    /// bouton de souris plutôt qu'une touche.
    let onHoldChange: (_ increase: Bool, _ isHolding: Bool) -> Void

    /// Grossissement de l'icône pendant le "bounce" qui signale qu'on a atteint une
    /// extrémité. Repart tout seul à 1 une fois le spring de retour terminé.
    @State private var minIconScale: CGFloat = 1
    @State private var maxIconScale: CGFloat = 1

    /// N'arme le bounce qu'à l'ENTRÉE dans l'extrémité, pas à chaque valeur reçue tant
    /// qu'on y reste collé (le thumb continue d'émettre pendant qu'on le maintient en
    /// butée) — sans ça le spring se relance en boucle et ne finit jamais sa course.
    @State private var wasAtMin = false
    @State private var wasAtMax = false

    var body: some View {
        // Deux icônes encadrent le rail, comme le panneau « Son » : un haut-parleur nu à
        // gauche, un haut-parleur avec ondes à droite. Elles bornent l'échelle et,
        // cliquées, crantent le volume d'un pas — exactement ce que fait le raccourci
        // clavier, en façade.
        //
        // Posées AUTOUR du Slider, dans ce HStack, et non via `minimumValueLabel` /
        // `maximumValueLabel` : ces labels-là ignorent la police qu'on leur passe et se
        // dimensionnent eux-mêmes (vérifié — passer de 14 à 10,5 pt ne changeait rien au
        // rendu). En les sortant, on reprend la main sur leur taille, et le Slider reste
        // natif.
        HStack(spacing: MenuRowMetrics.sliderIconGap) {
            // Le pas et la répétition accélérée vivent dans `onHoldChange` (câblé sur
            // `GlobalHotkeyManager` côté appelant) — pas d'action ici : `isPressed`
            // (via le `ButtonStyle`) est le seul signal utile, il porte à la fois le
            // début et la fin du maintien.
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
                // `.small` amincit le rail : le Slider par défaut a un rail de 6 px là où
                // celui de « Son » n'en fait que 4.
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

    /// Grossit puis relâche — même ressort qu'au premier jet (l'amplitude et le rebond
    /// élastique du retour étaient bons), mais étiré dans le temps : montée plus lente,
    /// pause plus longue en haut, retour plus lent.
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

    // MARK: - Valeur

    private var binding: Binding<Double> {
        Binding(
            get: { valueDb.clamped(to: bounds) },
            set: { onChange($0) }
        )
    }

    /// Les limites viennent du backend et peuvent arriver dégénérées (0/0) le temps que
    /// le cache s'amorce — un `Slider` avec un intervalle vide plante.
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

/// Couleur ET signal de maintien des icônes de haut-parleur, tous deux câblés sur
/// `isPressed` plutôt que sur une action de `Button` — un tap classique ne distingue
/// pas "début" de "fin" de pression, alors que c'est justement ce dont a besoin le
/// "hold" façon raccourci clavier (voir `onHoldChange` sur `VolumeSlider`).
///
/// Couleur : au repos, `.secondary` (le style hiérarchique) s'assombrit en composant
/// avec le style primaire de l'environnement — visible à travers le verre du panneau,
/// où il rend nettement plus gris que dans « Son ». `secondaryLabelColor` est la même
/// couleur sémantique système, mais appliquée à plat (une seule passe d'opacité, pas de
/// composition hiérarchique), ce qui est exactement ce que fait le natif. Tenue,
/// l'icône passe à `labelColor` — le même gris à pleine opacité, donc blanc en
/// apparence sombre. Aucune `withAnimation` : le changement suit `isPressed` sans
/// fondu, gris dès le relâchement, comme demandé.
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
