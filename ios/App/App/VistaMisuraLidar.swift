import UIKit
import ARKit
import SceneKit
import CoreVideo

// Modulo "Misura con LiDAR" — versione con campionamento reale di Scene Depth.
//
// Per ciascuno dei 4 punti toccati dall'operatore, la coordinata 3D viene
// determinata PRIMA di tutto leggendo la depth map LiDAR (preferendo
// smoothedSceneDepth, con fallback su sceneDepth grezzo se lo smussato non è
// disponibile in quel frame) e la confidenceMap corrispondente, poi
// retroproiettando pixel+profondità in spazio camera con gli intrinsics della
// camera, e infine trasformando in spazio mondo con camera.transform.
//
// Il raycast su .estimatedPlane resta SOLO come fallback per i frame/pixel in
// cui la depth map non è disponibile o non è utilizzabile (dato non finito,
// fuori range, ecc.) — non è più il metodo primario.
final class VistaMisuraLidar: UIViewController, ARSCNViewDelegate, ARSessionDelegate {

    /// true se il dispositivo supporta realmente Scene Depth (non un check sul
    /// modello di iPhone): è il requisito corretto per ciò che questo modulo usa.
    static var lidarDisponibile: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    var alCompletamento: (([String: Any]?) -> Void)?

    private let sceneView = ARSCNView()
    private let etichettaIstruzioni = UILabel()
    private let etichettaQuote = UILabel()
    private let etichettaLegenda = UILabel()
    private let bottoneAnnulla = UIButton(type: .system)
    private let bottoneRipristina = UIButton(type: .system)
    private let bottoneConferma = UIButton(type: .system)

    /// Un punto misurato, con tutti i metadati richiesti per la tracciabilità
    /// (metodo usato, confidenza, profondità in metri quando disponibile).
    private struct PuntoMisurato {
        var posizione: SCNVector3
        var profonditaM: Double?   // nil per i punti da raycastFallback
        var confidence: String     // "alta" | "media" | "bassa"
        var metodo: String         // "smoothedSceneDepth" | "sceneDepth" | "raycastFallback"
        var nodo: SCNNode
    }

    // Ordine di posizionamento assunto: alto-sx, alto-dx, basso-dx, basso-sx.
    private var punti: [PuntoMisurato] = []
    private var nodoLinee: SCNNode?
    private var nodoInTrascinamento: SCNNode?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configuraSceneView()
        configuraOverlay()
        configuraGesture()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        avviaSessioneAR()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    // MARK: - Setup

    private func configuraSceneView() {
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        sceneView.scene = SCNScene()
        view.addSubview(sceneView)
    }

    private func avviaSessioneAR() {
        let config = ARWorldTrackingConfiguration()
        // Scene reconstruction: utile alla qualità generale della sessione sui
        // dispositivi che la supportano, ma NON è più un requisito — il
        // requisito reale è il supporto a Scene Depth (vedi lidarDisponibile).
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        // Il plane detection resta attivo: serve al fallback raycast quando la
        // depth map non è disponibile/utilizzabile per uno o più frame.
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    private func configuraOverlay() {
        etichettaIstruzioni.text = "Individuazione del piano in corso... inquadra il serramento da 40-80 cm di distanza."
        etichettaIstruzioni.textColor = .white
        etichettaIstruzioni.numberOfLines = 2
        etichettaIstruzioni.font = .systemFont(ofSize: 15, weight: .semibold)
        etichettaIstruzioni.textAlignment = .center
        etichettaIstruzioni.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        etichettaIstruzioni.layer.cornerRadius = 10
        etichettaIstruzioni.layer.masksToBounds = true
        etichettaIstruzioni.translatesAutoresizingMaskIntoConstraints = false

        etichettaLegenda.text = "🟢 A = Alta   🟡 M = Media   🟠 B = Bassa   🟣 R = Fallback raycast (no depth)"
        etichettaLegenda.textColor = .white
        etichettaLegenda.numberOfLines = 2
        etichettaLegenda.font = .systemFont(ofSize: 12, weight: .medium)
        etichettaLegenda.textAlignment = .center
        etichettaLegenda.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        etichettaLegenda.layer.cornerRadius = 8
        etichettaLegenda.layer.masksToBounds = true
        etichettaLegenda.translatesAutoresizingMaskIntoConstraints = false

        etichettaQuote.text = ""
        etichettaQuote.textColor = .white
        etichettaQuote.numberOfLines = 5
        etichettaQuote.font = .monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        etichettaQuote.textAlignment = .center
        etichettaQuote.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        etichettaQuote.layer.cornerRadius = 10
        etichettaQuote.layer.masksToBounds = true
        etichettaQuote.translatesAutoresizingMaskIntoConstraints = false
        etichettaQuote.isHidden = true

        bottoneAnnulla.setTitle("Annulla", for: .normal)
        bottoneAnnulla.setTitleColor(.white, for: .normal)
        bottoneAnnulla.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        bottoneAnnulla.layer.cornerRadius = 10
        bottoneAnnulla.addTarget(self, action: #selector(annulla), for: .touchUpInside)

        bottoneRipristina.setTitle("Ripristina punti", for: .normal)
        bottoneRipristina.setTitleColor(.white, for: .normal)
        bottoneRipristina.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        bottoneRipristina.layer.cornerRadius = 10
        bottoneRipristina.addTarget(self, action: #selector(ripristinaPunti), for: .touchUpInside)

        bottoneConferma.setTitle("Conferma misura", for: .normal)
        bottoneConferma.setTitleColor(.white, for: .normal)
        bottoneConferma.backgroundColor = UIColor(red: 0.114, green: 0.435, blue: 0.361, alpha: 1) // verde brand
        bottoneConferma.layer.cornerRadius = 10
        bottoneConferma.isEnabled = false
        bottoneConferma.alpha = 0.4
        bottoneConferma.addTarget(self, action: #selector(conferma), for: .touchUpInside)

        let barraBottoni = UIStackView(arrangedSubviews: [bottoneAnnulla, bottoneRipristina, bottoneConferma])
        barraBottoni.axis = .horizontal
        barraBottoni.distribution = .fillEqually
        barraBottoni.spacing = 10
        barraBottoni.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(etichettaIstruzioni)
        view.addSubview(etichettaLegenda)
        view.addSubview(etichettaQuote)
        view.addSubview(barraBottoni)

        NSLayoutConstraint.activate([
            etichettaIstruzioni.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            etichettaIstruzioni.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            etichettaIstruzioni.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            etichettaLegenda.topAnchor.constraint(equalTo: etichettaIstruzioni.bottomAnchor, constant: 8),
            etichettaLegenda.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            etichettaLegenda.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            etichettaQuote.topAnchor.constraint(equalTo: etichettaLegenda.bottomAnchor, constant: 10),
            etichettaQuote.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            etichettaQuote.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30),

            barraBottoni.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            barraBottoni.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            barraBottoni.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            barraBottoni.heightAnchor.constraint(equalToConstant: 46),
        ])
    }

    private func configuraGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(gestitoTap(_:)))
        sceneView.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(gestitoPan(_:)))
        sceneView.addGestureRecognizer(pan)
    }

    // MARK: - Interazione: posizionamento e correzione dei 4 punti

    @objc private func gestitoTap(_ gesture: UITapGestureRecognizer) {
        guard punti.count < 4 else { return }
        let posizione = gesture.location(in: sceneView)
        guard let misurato = puntoDaSchermo(posizione) else {
            etichettaIstruzioni.text = "Punto non rilevato: avvicina o inquadra meglio la superficie."
            return
        }
        if misurato.confidence == "bassa" || misurato.metodo == "raycastFallback" {
            richiediConfermaBassaAffidabilita(misurato)
        } else {
            aggiungiPunto(misurato)
        }
    }

    @objc private func gestitoPan(_ gesture: UIPanGestureRecognizer) {
        let posizione = gesture.location(in: sceneView)
        switch gesture.state {
        case .began:
            let risultati = sceneView.hitTest(posizione, options: [:])
            nodoInTrascinamento = risultati.first(where: { r in
                punti.contains(where: { $0.nodo == r.node || $0.nodo == r.node.parent })
            })?.node
            // Se è stata colpita l'etichetta 3D (figlia della sfera) risaliamo al nodo sfera.
            if let colpito = nodoInTrascinamento, !punti.contains(where: { $0.nodo == colpito }) {
                nodoInTrascinamento = colpito.parent
            }
        case .changed:
            guard let nodo = nodoInTrascinamento, let indice = punti.firstIndex(where: { $0.nodo == nodo }) else { return }
            guard let misurato = puntoDaSchermo(posizione) else { return }
            // Durante il trascinamento aggiorniamo posizione/qualità dal vivo, senza
            // interrompere il gesto con un alert: la verifica di bassa affidabilità
            // per un punto corretto a mano avviene al rilascio del dito (.ended).
            aggiornaPunto(indice, con: misurato)
        case .ended, .cancelled:
            if let nodo = nodoInTrascinamento, let indice = punti.firstIndex(where: { $0.nodo == nodo }) {
                let p = punti[indice]
                if p.confidence == "bassa" || p.metodo == "raycastFallback" {
                    etichettaIstruzioni.text = "Punto \(indice + 1) corretto con affidabilità bassa (\(etichettaBreve(p))): verificalo prima di confermare."
                }
            }
            nodoInTrascinamento = nil
        default:
            break
        }
    }

    // MARK: - Determinazione del punto 3D: Scene Depth prima, raycast come fallback

    private func puntoDaSchermo(_ posizioneSchermo: CGPoint) -> PuntoMisurato? {
        guard let frame = sceneView.session.currentFrame else { return nil }
        if let daDepth = puntoDaDepthMap(posizioneSchermo, frame: frame) {
            return daDepth
        }
        // Fallback: depth map assente o non utilizzabile per questo pixel/frame
        // (punto 5/13 della revisione: il modulo non si blocca mai per questo).
        return puntoDaRaycast(posizioneSchermo)
    }

    private func puntoDaDepthMap(_ posizioneSchermo: CGPoint, frame: ARFrame) -> PuntoMisurato? {
        var depthData: ARDepthData?
        var nomeMetodo = ""
        if let smussata = frame.smoothedSceneDepth {
            depthData = smussata
            nomeMetodo = "smoothedSceneDepth"
        } else if let grezza = frame.sceneDepth {
            depthData = grezza
            nomeMetodo = "sceneDepth"
        }
        guard let depthData = depthData else { return nil }

        let depthMap = depthData.depthMap
        let larghezzaDepth = CVPixelBufferGetWidth(depthMap)
        let altezzaDepth = CVPixelBufferGetHeight(depthMap)
        guard larghezzaDepth > 0, altezzaDepth > 0 else { return nil }

        let viewportSize = sceneView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }

        // Conversione screen -> coordinate immagine normalizzate (0...1), poi ->
        // pixel della depth map. displayTransform tiene conto dell'orientamento.
        let orientamento = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let normalizzato = CGPoint(x: posizioneSchermo.x / viewportSize.width, y: posizioneSchermo.y / viewportSize.height)
        let trasformazione = frame.displayTransform(for: orientamento, viewportSize: viewportSize)
        guard let inversa = trasformazione.inverted() as CGAffineTransform? else { return nil }
        let puntoImmagine = normalizzato.applying(inversa)

        let depthX = Int((puntoImmagine.x * CGFloat(larghezzaDepth)).rounded())
        let depthY = Int((puntoImmagine.y * CGFloat(altezzaDepth)).rounded())
        guard depthX >= 0, depthX < larghezzaDepth, depthY >= 0, depthY < altezzaDepth else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        guard let baseDepth = CVPixelBufferGetBaseAddress(depthMap) else {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            return nil
        }
        let bytesPerRigaDepth = CVPixelBufferGetBytesPerRow(depthMap)
        let rigaDepth = baseDepth.advanced(by: depthY * bytesPerRigaDepth)
        let valoreProfondita = rigaDepth.assumingMemoryBound(to: Float32.self)[depthX]
        CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)

        // Scarta letture non utilizzabili (punto 5): NaN, zero, o fuori dal range
        // sensato per la misura di un serramento (5 cm - 8 m).
        guard valoreProfondita.isFinite, valoreProfondita > 0.05, valoreProfondita < 8.0 else { return nil }

        var livello: ARConfidenceLevel = .low
        if let confidenceMap = depthData.confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            if let baseConf = CVPixelBufferGetBaseAddress(confidenceMap) {
                let cWidth = CVPixelBufferGetWidth(confidenceMap)
                let cHeight = CVPixelBufferGetHeight(confidenceMap)
                let cx = min(max(depthX, 0), max(cWidth - 1, 0))
                let cy = min(max(depthY, 0), max(cHeight - 1, 0))
                let bytesPerRigaConf = CVPixelBufferGetBytesPerRow(confidenceMap)
                let rigaConf = baseConf.advanced(by: cy * bytesPerRigaConf)
                let grezzo = rigaConf.assumingMemoryBound(to: UInt8.self)[cx]
                livello = ARConfidenceLevel(rawValue: Int(grezzo)) ?? .low
            }
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
        }

        // Retroproiezione pixel + profondità -> spazio camera. Gli intrinsics sono
        // definiti sulla risoluzione dell'immagine a colori: li riscaliamo alla
        // risoluzione (più bassa) della depth map prima di usarli.
        let intrinsics = frame.camera.intrinsics
        let risoluzioneImmagine = frame.camera.imageResolution
        guard risoluzioneImmagine.width > 0, risoluzioneImmagine.height > 0 else { return nil }
        let scalaX = Float(larghezzaDepth) / Float(risoluzioneImmagine.width)
        let scalaY = Float(altezzaDepth) / Float(risoluzioneImmagine.height)
        let fx = intrinsics[0][0] * scalaX
        let fy = intrinsics[1][1] * scalaY
        let cx = intrinsics[2][0] * scalaX
        let cy = intrinsics[2][1] * scalaY
        guard fx != 0, fy != 0 else { return nil }

        let z = valoreProfondita
        let xCamera = (Float(depthX) - cx) / fx * z
        // L'asse Y dei pixel immagine cresce verso il basso, quello camera verso l'alto: segno invertito.
        let yCamera = -(Float(depthY) - cy) / fy * z
        // La camera ARKit guarda lungo -Z nel proprio spazio locale.
        let puntoCamera = simd_float4(xCamera, yCamera, -z, 1)
        let puntoMondo4 = frame.camera.transform * puntoCamera
        let posizioneMondo = SCNVector3(puntoMondo4.x, puntoMondo4.y, puntoMondo4.z)

        let confidenceTesto: String
        switch livello {
        case .high: confidenceTesto = "alta"
        case .medium: confidenceTesto = "media"
        case .low: confidenceTesto = "bassa"
        @unknown default: confidenceTesto = "bassa"
        }

        return PuntoMisurato(
            posizione: posizioneMondo,
            profonditaM: Double(valoreProfondita),
            confidence: confidenceTesto,
            metodo: nomeMetodo,
            nodo: SCNNode()
        )
    }

    private func puntoDaRaycast(_ posizioneSchermo: CGPoint) -> PuntoMisurato? {
        guard let query = sceneView.raycastQuery(from: posizioneSchermo, allowing: .estimatedPlane, alignment: .any) else { return nil }
        let risultati = sceneView.session.raycast(query)
        guard let primo = risultati.first else { return nil }
        let colonna = primo.worldTransform.columns.3
        return PuntoMisurato(
            posizione: SCNVector3(colonna.x, colonna.y, colonna.z),
            profonditaM: nil,
            confidence: "bassa",
            metodo: "raycastFallback",
            nodo: SCNNode()
        )
    }

    // MARK: - Conferma per punti a bassa affidabilità (punto 8 della revisione)

    private func richiediConfermaBassaAffidabilita(_ misurato: PuntoMisurato) {
        let motivo = misurato.metodo == "raycastFallback"
            ? "nessun dato di profondità LiDAR disponibile in questo punto (uso il solo rilevamento del piano)"
            : "profondità LiDAR letta ma con confidenza bassa"
        let alert = UIAlertController(
            title: "Punto poco affidabile",
            message: "\(motivo.capitalized). Vuoi usare comunque questo punto o toccare di nuovo un punto più netto del serramento?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Usa comunque", style: .default) { [weak self] _ in
            self?.aggiungiPunto(misurato)
        })
        alert.addAction(UIAlertAction(title: "Riprova", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Gestione punti in scena

    private func aggiungiPunto(_ misurato: PuntoMisurato) {
        var m = misurato
        m.nodo = creaNodoPunto(per: misurato)
        sceneView.scene.rootNode.addChildNode(m.nodo)
        punti.append(m)

        if punti.count < 4 {
            etichettaIstruzioni.text = "Punto \(punti.count) di 4 posizionato (\(etichettaBreve(m))). Tocca l'angolo successivo."
        } else {
            etichettaIstruzioni.text = "4 punti posizionati. Trascina un punto per correggerlo, oppure conferma."
            bottoneConferma.isEnabled = true
            bottoneConferma.alpha = 1
        }
        ridisegnaLineeECalcola()
    }

    private func aggiornaPunto(_ indice: Int, con misurato: PuntoMisurato) {
        let nodoEsistente = punti[indice].nodo
        nodoEsistente.position = SCNVector3(misurato.posizione.x, misurato.posizione.y, misurato.posizione.z)
        nodoEsistente.childNodes.forEach { $0.removeFromParentNode() }
        aggiornaAspettoNodo(nodoEsistente, per: misurato)
        punti[indice].posizione = misurato.posizione
        punti[indice].profonditaM = misurato.profonditaM
        punti[indice].confidence = misurato.confidence
        punti[indice].metodo = misurato.metodo
        ridisegnaLineeECalcola()
    }

    @objc private func ripristinaPunti() {
        punti.forEach { $0.nodo.removeFromParentNode() }
        punti.removeAll()
        nodoLinee?.removeFromParentNode()
        nodoLinee = nil
        etichettaQuote.isHidden = true
        bottoneConferma.isEnabled = false
        bottoneConferma.alpha = 0.4
        etichettaIstruzioni.text = "Tocca per posizionare il punto 1 di 4 (un angolo del serramento)."
    }

    // MARK: - Aspetto dei punti (colore + testo, non solo colore: punto 7)

    private func coloreQualita(_ p: PuntoMisurato) -> UIColor {
        if p.metodo == "raycastFallback" { return .systemPurple }
        switch p.confidence {
        case "alta": return .systemGreen
        case "media": return .systemYellow
        default: return .systemOrange
        }
    }

    private func letteraQualita(_ p: PuntoMisurato) -> String {
        if p.metodo == "raycastFallback" { return "R" }
        switch p.confidence {
        case "alta": return "A"
        case "media": return "M"
        default: return "B"
        }
    }

    private func etichettaBreve(_ p: PuntoMisurato) -> String {
        switch (p.metodo, p.confidence) {
        case ("raycastFallback", _): return "R · fallback raycast"
        default: return "\(letteraQualita(p)) · confidenza \(p.confidence)"
        }
    }

    private func creaNodoPunto(per misurato: PuntoMisurato) -> SCNNode {
        let sfera = SCNSphere(radius: 0.008)
        sfera.firstMaterial?.diffuse.contents = coloreQualita(misurato)
        sfera.firstMaterial?.emission.contents = coloreQualita(misurato)
        let nodo = SCNNode(geometry: sfera)
        nodo.position = misurato.posizione
        aggiungiEtichetta3D(letteraQualita(misurato), colore: coloreQualita(misurato), a: nodo)
        return nodo
    }

    private func aggiornaAspettoNodo(_ nodo: SCNNode, per misurato: PuntoMisurato) {
        (nodo.geometry as? SCNSphere)?.firstMaterial?.diffuse.contents = coloreQualita(misurato)
        (nodo.geometry as? SCNSphere)?.firstMaterial?.emission.contents = coloreQualita(misurato)
        aggiungiEtichetta3D(letteraQualita(misurato), colore: coloreQualita(misurato), a: nodo)
    }

    private func aggiungiEtichetta3D(_ testo: String, colore: UIColor, a nodoGenitore: SCNNode) {
        let geometriaTesto = SCNText(string: testo, extrusionDepth: 0.4)
        geometriaTesto.font = UIFont.boldSystemFont(ofSize: 8)
        geometriaTesto.flatness = 0.2
        geometriaTesto.firstMaterial?.diffuse.contents = colore
        geometriaTesto.firstMaterial?.readsFromDepthBuffer = false
        let nodoTesto = SCNNode(geometry: geometriaTesto)
        nodoTesto.scale = SCNVector3(0.0012, 0.0012, 0.0012)
        nodoTesto.position = SCNVector3(0.01, 0.014, 0)
        nodoTesto.constraints = [SCNBillboardConstraint()]
        nodoTesto.renderingOrder = 10
        nodoGenitore.addChildNode(nodoTesto)
    }

    // MARK: - Calcolo quote

    private func ridisegnaLineeECalcola() {
        nodoLinee?.removeFromParentNode()
        guard punti.count == 4 else { return }
        let posizioni = punti.map { $0.nodo.position }

        let larghezza1 = distanza(posizioni[0], posizioni[1])
        let larghezza2 = distanza(posizioni[3], posizioni[2])
        let altezza1 = distanza(posizioni[0], posizioni[3])
        let altezza2 = distanza(posizioni[1], posizioni[2])
        let larghezzaM = (larghezza1 + larghezza2) / 2
        let altezzaM = (altezza1 + altezza2) / 2
        let superficieM2 = larghezzaM * altezzaM

        let riepilogoPunti = punti.enumerated().map { i, p in "P\(i + 1)=\(letteraQualita(p))" }.joined(separator: "  ")
        etichettaQuote.isHidden = false
        etichettaQuote.text = String(
            format: "L = %.0f mm   H = %.0f mm\nSuperficie = %.2f m²\n(MISURA INDICATIVA — DA VERIFICARE)\n%@",
            larghezzaM * 1000, altezzaM * 1000, superficieM2, riepilogoPunti
        )

        nodoLinee = disegnaContorno(posizioni)
        if let linee = nodoLinee { sceneView.scene.rootNode.addChildNode(linee) }
    }

    private func distanza(_ a: SCNVector3, _ b: SCNVector3) -> Float {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return sqrtf(dx * dx + dy * dy + dz * dz)
    }

    private func disegnaContorno(_ punti: [SCNVector3]) -> SCNNode {
        let contenitore = SCNNode()
        for i in 0..<punti.count {
            let a = punti[i]
            let b = punti[(i + 1) % punti.count]
            contenitore.addChildNode(lineaTra(a, b))
        }
        return contenitore
    }

    private func lineaTra(_ a: SCNVector3, _ b: SCNVector3) -> SCNNode {
        let indici: [Int32] = [0, 1]
        let sorgente = SCNGeometrySource(vertices: [a, b])
        let elemento = SCNGeometryElement(indices: indici, primitiveType: .line)
        let geometria = SCNGeometry(sources: [sorgente], elements: [elemento])
        geometria.firstMaterial?.diffuse.contents = UIColor.systemGreen
        return SCNNode(geometry: geometria)
    }

    // MARK: - Attendibilità complessiva (punto 9): solo ALTA/MEDIA/BASSA, nessuna percentuale inventata

    private func attendibilitaComplessiva() -> String {
        let usaFallback = punti.contains { $0.metodo == "raycastFallback" }
        let haBassa = punti.contains { $0.confidence == "bassa" }
        let haMedia = punti.contains { $0.confidence == "media" }
        if usaFallback || haBassa { return "bassa" }
        if haMedia { return "media" }
        return "alta"
    }

    private func identificatoreDispositivo() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let modello = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in String(cString: ptr) }
        }
        return "\(modello) · iOS \(UIDevice.current.systemVersion)"
    }

    // MARK: - Azioni

    @objc private func annulla() {
        alCompletamento?(nil)
    }

    @objc private func conferma() {
        guard punti.count == 4 else { return }
        let posizioni = punti.map { $0.nodo.position }
        let larghezzaM = (distanza(posizioni[0], posizioni[1]) + distanza(posizioni[3], posizioni[2])) / 2
        let altezzaM = (distanza(posizioni[0], posizioni[3]) + distanza(posizioni[1], posizioni[2])) / 2
        let larghezzaCm = Double(larghezzaM * 100)
        let altezzaCm = Double(altezzaM * 100)
        let superficieM2 = Double(larghezzaM * altezzaM)

        let puntiJson: [[String: Any]] = punti.map { p in
            [
                "profondita_m": p.profonditaM ?? NSNull(),
                "confidence": p.confidence,
                "metodo": p.metodo,
            ]
        }

        let risultato: [String: Any] = [
            "larghezza": (larghezzaCm * 10).rounded() / 10,     // cm, un decimale
            "altezza": (altezzaCm * 10).rounded() / 10,
            "superficie": (superficieM2 * 100).rounded() / 100,  // m²
            "metodoMisura": "ar_lidar_scene_depth",
            "dispositivo": identificatoreDispositivo(),
            "attendibilita": attendibilitaComplessiva(),
            "confermataOperatore": true,
            "punti": puntiJson,
        ]
        alCompletamento?(risultato)
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didFailWithError error: Error) {
        etichettaIstruzioni.text = "Sessione AR interrotta: \(error.localizedDescription)"
    }

    func sessionWasInterrupted(_ session: ARSession) {
        etichettaIstruzioni.text = "Sessione AR interrotta temporaneamente."
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        avviaSessioneAR()
    }
}
