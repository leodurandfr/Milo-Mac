import AppKit

class LoadingSpinner: NSView {
    private let strokeWidth: CGFloat = 1.5
    private let animationDuration: Double = 1.4
    private var animationTimer: Timer?
    private var currentStep = 0
    private let totalSteps = 8  // 8 positions, rotation continue
    
    // Les 8 positions du spinner dans l'ordre horaire (12h en haut)
    private let positions: [CGFloat] = [90, 135, 180, 225, 270, 315, 0, 45]  // 12h, 1h30, 3h, 4h30, 6h, 7h30, 9h, 10h30
    
    // Layers pour chaque trait avec transitions
    private var strokeLayers: [CAShapeLayer] = []
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        createStrokeLayers()
    }
    
    private func createStrokeLayers() {
        let spinnerSize: CGFloat = 18
        let centerX = bounds.midX
        let centerY = bounds.midY
        let radius: CGFloat = (spinnerSize / 2) - strokeWidth
        
        // Créer un layer pour chaque trait
        for (index, angle) in positions.enumerated() {
            let strokeLayer = CAShapeLayer()
            
            // Calculer les points de début et fin du trait
            let startRadius = radius * 0.6
            let endRadius = radius * 0.9
            
            // Convertir l'angle en radians
            let angleRad = angle * .pi / 180
            let startPoint = CGPoint(
                x: centerX + cos(angleRad) * startRadius,
                y: centerY + sin(angleRad) * startRadius
            )
            let endPoint = CGPoint(
                x: centerX + cos(angleRad) * endRadius,
                y: centerY + sin(angleRad) * endRadius
            )
            
            // Créer le path du trait
            let path = CGMutablePath()
            path.move(to: startPoint)
            path.addLine(to: endPoint)
            
            // Configurer le layer
            strokeLayer.path = path
            strokeLayer.strokeColor = NSColor.white.cgColor
            strokeLayer.lineWidth = strokeWidth
            strokeLayer.lineCap = .round
            strokeLayer.fillColor = NSColor.clear.cgColor
            strokeLayer.opacity = Float(getOpacityForPosition(index))
            
            // Ajouter des actions d'animation pour les transitions fluides
            strokeLayer.actions = [
                "opacity": createSmoothOpacityAnimation()
            ]
            
            layer?.addSublayer(strokeLayer)
            strokeLayers.append(strokeLayer)
        }
    }
    
    private func createSmoothOpacityAnimation() -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.duration = 0.175  // Même durée qu'un step (1.4s / 8 = 0.175s)
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)  // Transition fluide
        return animation
    }
    
    override func draw(_ dirtyRect: NSRect) {
        // Les CAShapeLayer gèrent tout l'affichage maintenant
    }
    
    private func getOpacityForPosition(_ position: Int) -> CGFloat {
        // Animation corrigée : la "lumière" avance et laisse une traînée derrière
        // currentStep indique la position "de fin de traînée"
        
        // Calculer la distance entre cette position et la position actuelle
        let distance = (position - currentStep + 8) % 8
        
        switch distance {
        case 0: return 1.00     // Début de trainé
        case 1: return 0.64     // 1 position derrière
        case 2: return 0.32     // 2 positions derrière
        case 3: return 0.24     // 3 positions derrière
        default: return 0.16    // Toutes les autres positions (faibles)
        }
    }
    
    private func updateOpacities() {
        // Mise à jour des opacités avec transitions automatiques
        for (index, layer) in strokeLayers.enumerated() {
            let newOpacity = Float(getOpacityForPosition(index))
            layer.opacity = newOpacity
        }
    }
    
    func startAnimating() {
        stopAnimating()

        // Pour que 12h (position 0) soit case 0 (opacité 1.0), il faut currentStep = 0
        currentStep = 0
        updateOpacities()
        
        // Timer : 1.4s / 8 positions = 0.175s par step
        let stepInterval = animationDuration / Double(totalSteps)
        
        animationTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // CORRECTION : Changer le sens pour aller dans le sens horaire
            self.currentStep = (self.currentStep - 1 + self.totalSteps) % self.totalSteps
            
            
            // Mettre à jour les opacités avec transitions
            self.updateOpacities()
        }
        
        // S'assurer que le timer fonctionne même quand le menu est ouvert
        if let timer = animationTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    func stopAnimating() {
        // Pas de bloc différé ici : stopAnimating() est appelé depuis deinit,
        // et capturer self dans une closure échappante pendant la
        // désallocation est un use-after-free. L'invalidation synchrone suffit.
        animationTimer?.invalidate()
        animationTimer = nil
        currentStep = 0  // Reset à la position de départ (12h brillant)

        // Reset des opacités
        updateOpacities()
    }
    
    override func layout() {
        super.layout()
        // Recréer les layers si la taille change
        if !strokeLayers.isEmpty {
            strokeLayers.forEach { $0.removeFromSuperlayer() }
            strokeLayers.removeAll()
            createStrokeLayers()
        }
    }
    
    deinit {
        stopAnimating()
    }
}
