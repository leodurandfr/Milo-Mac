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

    var body: some View {
        // Les deux icônes encadrent le rail via `minimumValueLabel` / `maximumValueLabel`,
        // l'API native du Slider — c'est exactement ce que fait le panneau « Son » : un
        // haut-parleur nu à gauche, un haut-parleur avec ondes à droite. Elles sont
        // **statiques** : elles bornent l'échelle, elles ne suivent pas le volume.
        // Les icônes sont posées AUTOUR du slider, et non via `minimumValueLabel` /
        // `maximumValueLabel` : ces labels-là ignorent la police qu'on leur passe et se
        // dimensionnent eux-mêmes (vérifié — passer de 14 à 10,5 pt ne changeait rien au
        // rendu). En les sortant, on reprend la main sur leur taille, et le Slider reste
        // natif.
        HStack(spacing: MenuRowMetrics.sliderIconGap) {
            Image(systemName: "speaker.fill")
                .font(.system(size: MenuRowMetrics.sliderIconSize))
                .foregroundStyle(.secondary)

            Slider(value: binding, in: bounds)
                // `.small` amincit le rail : le Slider par défaut a un rail de 6 px là où
                // celui de « Son » n'en fait que 4.
                .controlSize(.small)
                .accessibilityLabel(L("accessibility.volume_slider"))

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: MenuRowMetrics.sliderIconSize))
                .foregroundStyle(.secondary)
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
