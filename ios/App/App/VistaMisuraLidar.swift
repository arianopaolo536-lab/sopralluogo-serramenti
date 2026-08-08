import UIKit
import ARKit
import SceneKit
import CoreVideo
import Vision
import simd

// Modulo "Misura con LiDAR" — versione con campionamento reale di Scene Depth,
// più le tre correzioni emerse dal primo test sul campo:
//   1) Stabilizzazione: il tocco per posizionare un punto è accettato solo
//      quando il telefono è fermo da un breve intervallo (misurato frame per
//      frame su traslazione e rotazione della camera).
//   2) Assistenza al riconoscimento dei vertici: Vision (VNDetectRectanglesRequest,
//      on-device, nessuna API esterna) individua un rettangolo nell'inquadratura
//      e i suoi 4 vertici vengono mostrati come piccoli cerchi; toccando vicino
//      a uno di essi il punto si aggancia lì. È solo un aiuto: se non rileva
//      nulla, o l'operatore tocca altrove, funziona tutto esattamente come
//      prima (nessuna regressione).
//   3) Conferma punto-per-punto: dopo il tocco il punto resta "in sospeso"
//      (colore/lettera già visibili, trascinabile per correggerlo) ed entra
//      nella misura solo dopo aver premuto "Conferma punto".
//
// Per ciascun punto, la coordinata 3D viene determinata PRIMA di tutto
// leggendo la depth map LiDAR (preferendo smoothedSceneDepth, con fallback su
// sceneDepth grezzo se lo smussato non è disponibile in quel frame) e la
// confidenceMap corrispondente, poi retroproiettando pixel+profondità in
// spazio camera con gli intrinsics della camera, e infine trasformando in
// spazio mondo con camera.transform. Il raycast su .estimatedPlane resta SOLO
// come fallback per i frame/pixel in cui la depth map non è disponibile o non
// è utilizzabile — non è mai il metodo primario.
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
    private let bottoneConfermaPunto = UIButton(type: .system)
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
    /// Punto toccato ma non ancora confermato dall'operatore (punto 3 della revisione).
    private var puntoPendente: PuntoMisurato?
    private var nodoLinee: SCNNode?
    private var nodoInTrascinamento: SCNNode?
    /// Evita che un messaggio di stato (es. "Punto confermato") venga
    /// sovrascritto nello stesso istante dall'indicatore di stabilità, che si
    /// aggiorna a ogni frame.
    private var etichettaBloccataFino: Date = .distantPast

    // MARK: - Stabilizzazione (punto 1 della revisione)

    private var trasformCameraPrecedente: simd_float4x4?
    private var frameStabiliConsecutivi: Int = 0
    private let frameStabiliRichiesti = 16
    private let sogliaTraslazionePerFrame: Float = 0.0018  // ~1.8 mm tra un frame e l'altro
    private let sogliaRotazionePerFrame: Float = 0.006     // radianti, circa 0.35°
    private var stabilitaOk: Bool { frameStabiliConsecutivi >= frameStabiliRichiesti }

    // MARK: - Riconoscimento vertici assistito (punto 2 della revisione)

    private let codaRilevamentoVertici = DispatchQueue(label: "it.qid.rilevamento-vertici")
    private var rilevamentoVerticiInCorso = false
    private var contatoreFrameRilevamento = 0
    private var verticiRilevatiSchermo: [CGPoint] = []
    private var cicliVuotiConsecutiviRilevamento = 0
    private var livelliIndicatoriVertici: [CAShapeLayer] = []
    private let tolleranzaAggancioVertice: CGFloat = 36

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
        trasformCameraPrecedente = nil
        frameStabiliConsecutivi = 0
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

        etichettaLegenda.text = "🟢 A = Alta   🟡 M = Media   🟠 B = Bassa   🟣 R = Fallback raycast (no depth)   ⚪ = vertice suggerito"
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

        bottoneRipristina.setTitle("Ripristina", for: .normal)
        bottoneRipristina.setTitleColor(.white, for: .normal)
        bottoneRipristina.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        bottoneRipristina.layer.cornerRadius = 10
        bottoneRipristina.addTarget(self, action: #selector(ripristinaPunti), for: .touchUpInside)

        bottoneConfermaPunto.setTitle("Conferma punto", for: .normal)
        bottoneConfermaPunto.setTitleColor(.white, for: .normal)
        bottoneConfermaPunto.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.9)
        bottoneConfermaPunto.layer.cornerRadius = 10
        bottoneConfermaPunto.isEnabled = false
        bottoneConfermaPunto.alpha = 0.4
        bottoneConfermaPunto.addTarget(self, action: #selector(confermaPunto), for: .touchUpInside)

        bottoneConferma.setTitle("Fine misura", for: .normal)
        bottoneConferma.setTitleColor(.white, for: .normal)
        bottoneConferma.backgroundColor = UIColor(red: 0.114, green: 0.435, blue: 0.361, alpha: 1) // verde brand
        bottoneConferma.layer.cornerRadius = 10
        bottoneConferma.isEnabled = false
        bottoneConferma.alpha = 0.4
        bottoneConferma.addTarget(self, action: #selector(conferma), for: .touchUpInside)

        let barraBottoni = UIStackView(arrangedSubviews: [bottoneAnnulla, bottoneRipristina, bottoneConfermaPunto, bottoneConferma])
        barraBottoni.axis = .horizontal
        barraBottoni.distribution = .fillEqually
        barraBottoni.spacing = 8
        barraBottoni.translatesAutoresizingMaskIntoConstraints = false

        for bottone in [bottoneAnnulla, bottoneRipristina, bottoneConfermaPunto, bottoneConferma] {
            bottone.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            bottone.titleLabel?.adjustsFontSizeToFitWidth = true
            bottone.titleLabel?.minimumScaleFactor = 0.55
        }

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

    // MARK: - Interazione: posizionamento, aggancio al vertice suggerito, conferma

    @objc private func gestitoTap(_ gesture: UITapGestureRecognizer) {
        guard punti.count < 4 else { return }
        guard stabilitaOk else {
            mostraMessaggio("🔴 Tieni fermo il telefono un istante, poi tocca di nuovo.")
            return
        }
        var posizione = gesture.location(in: sceneView)
        if let agganciato = verticeSuggeritoVicino(a: posizione) {
            posizione = agganciato
        }
        guard let misurato = puntoDaSchermo(posizione) else {
            mostraMessaggio("Punto non rilevato: avvicina o inquadra meglio la superficie.")
            return
        }
        impostaPuntoPendente(misurato)
    }

    private func verticeSuggeritoVicino(a posizione: CGPoint) -> CGPoint? {
        var migliore: CGPoint?
        var distanzaMinima = tolleranzaAggancioVertice
        for v in verticiRilevatiSchermo {
            let d = hypot(v.x - posizione.x, v.y - posizione.y)
            if d < distanzaMinima {
                distanzaMinima = d
                migliore = v
            }
        }
        return migliore
    }

    @objc private func gestitoPan(_ gesture: UIPanGestureRecognizer) {
        let posizione = gesture.location(in: sceneView)
        switch gesture.state {
        case .began:
            // boundingBoxOnly rende il bersaglio più permissivo (usa il cubo che
            // racchiude la sfera invece della geometria esatta): più facile da
            // agganciare col dito, soprattutto su un punto piccolo e lontano.
            let opzioni: [SCNHitTestOption: Any] = [.boundingBoxOnly: true]
            let risultati = sceneView.hitTest(posizione, options: opzioni)
            var candidato = risultati.first(where: { r in
                (puntoPendente?.nodo == r.node) || punti.contains(where: { $0.nodo == r.node })
            })?.node
            if candidato == nil {
                // Può essere stata colpita l'etichetta 3D (figlia della sfera): risaliamo al genitore.
                candidato = risultati.first(where: { r in
                    (puntoPendente?.nodo == r.node.parent) || punti.contains(where: { $0.nodo == r.node.parent })
                })?.node.parent
            }
            nodoInTrascinamento = candidato
        case .changed:
            guard let nodo = nodoInTrascinamento else { return }
            guard let misurato = puntoDaSchermo(posizione) else { return }
            if puntoPendente?.nodo == nodo {
                aggiornaPuntoPendente(con: misurato)
            } else if let indice = punti.firstIndex(where: { $0.nodo == nodo }) {
                aggiornaPunto(indice, con: misurato)
            }
        case .ended, .cancelled:
            if let nodo = nodoInTrascinamento, let indice = punti.firstIndex(where: { $0.nodo == nodo }) {
                let p = punti[indice]
                if p.confidence == "bassa" || p.metodo == "raycastFallback" {
                    mostraMessaggio("Punto \(indice + 1) corretto con affidabilità bassa (\(etichettaBreve(p))): verificalo.")
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
        // (il modulo non si blocca mai per questo).
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

        // Scarta letture non utilizzabili: NaN, zero, o fuori dal range sensato
        // per la misura di un serramento (5 cm - 8 m).
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

    // MARK: - Punto in sospeso: aggiusta e conferma (punto 3 della revisione)

    private func impostaPuntoPendente(_ misurato: PuntoMisurato) {
        puntoPendente?.nodo.removeFromParentNode()
        var m = misurato
        m.nodo = creaNodoPunto(per: misurato)
        sceneView.scene.rootNode.addChildNode(m.nodo)
        puntoPendente = m
        bottoneConfermaPunto.isEnabled = true
        bottoneConfermaPunto.alpha = 1
        mostraMessaggio("Punto \(punti.count + 1) di 4 — trascina per aggiustare, poi \"Conferma punto\" (\(etichettaBreve(m))).")
    }

    private func aggiornaPuntoPendente(con misurato: PuntoMisurato) {
        guard var m = puntoPendente else { return }
        m.nodo.position = misurato.posizione
        m.nodo.childNodes.forEach { $0.removeFromParentNode() }
        aggiornaAspettoNodo(m.nodo, per: misurato)
        m.posizione = misurato.posizione
        m.profonditaM = misurato.profonditaM
        m.confidence = misurato.confidence
        m.metodo = misurato.metodo
        puntoPendente = m
        mostraMessaggio("Punto \(punti.count + 1) di 4 — trascina per aggiustare, poi \"Conferma punto\" (\(etichettaBreve(m))).")
    }

    @objc private func confermaPunto() {
        guard let m = puntoPendente else { return }
        if m.confidence == "bassa" || m.metodo == "raycastFallback" {
            richiediConfermaBassaAffidabilita(m)
        } else {
            finalizzaPuntoPendente(m)
        }
    }

    private func finalizzaPuntoPendente(_ misurato: PuntoMisurato) {
        punti.append(misurato)
        puntoPendente = nil
        bottoneConfermaPunto.isEnabled = false
        bottoneConfermaPunto.alpha = 0.4
        if punti.count < 4 {
            mostraMessaggio("Punto \(punti.count) confermato (\(etichettaBreve(misurato))). Tocca l'angolo successivo.")
        } else {
            mostraMessaggio("4 punti confermati. Puoi ancora trascinare un punto per correggerlo, oppure concludi.")
            bottoneConferma.isEnabled = true
            bottoneConferma.alpha = 1
        }
        ridisegnaLineeECalcola()
    }

    // MARK: - Conferma per punti a bassa affidabilità

    private func richiediConfermaBassaAffidabilita(_ misurato: PuntoMisurato) {
        let motivo = misurato.metodo == "raycastFallback"
            ? "nessun dato di profondità LiDAR disponibile in questo punto (uso il solo rilevamento del piano)"
            : "profondità LiDAR letta ma con confidenza bassa"
        let alert = UIAlertController(
            title: "Punto poco affidabile",
            message: "\(motivo.capitalized). Vuoi confermarlo comunque o aggiustarlo/toccare di nuovo un punto più netto?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Conferma comunque", style: .default) { [weak self] _ in
            self?.finalizzaPuntoPendente(misurato)
        })
        alert.addAction(UIAlertAction(title: "Aggiusta", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Gestione punti confermati

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
        puntoPendente?.nodo.removeFromParentNode()
        puntoPendente = nil
        bottoneConfermaPunto.isEnabled = false
        bottoneConfermaPunto.alpha = 0.4
        nodoLinee?.removeFromParentNode()
        nodoLinee = nil
        etichettaQuote.isHidden = true
        bottoneConferma.isEnabled = false
        bottoneConferma.alpha = 0.4
        mostraMessaggio("Tocca per posizionare il punto 1 di 4 (un angolo del serramento).")
    }

    // MARK: - Aspetto dei punti (colore + testo, non solo colore)

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
        // Raggio maggiorato rispetto alla prima versione: oltre a essere più
        // visibile, offre un bersaglio più grande al tocco/trascinamento.
        let sfera = SCNSphere(radius: 0.015)
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

    // MARK: - Attendibilità complessiva: solo ALTA/MEDIA/BASSA, nessuna percentuale inventata

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

    // MARK: - Messaggi di stato (con piccolo "blocco" anti-sovrascrittura dall'indicatore di stabilità)

    private func mostraMessaggio(_ testo: String, bloccaPer secondi: TimeInterval = 1.2) {
        etichettaIstruzioni.text = testo
        etichettaBloccataFino = Date().addingTimeInterval(secondi)
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

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        aggiornaStabilita(frame: frame)
        aggiornaRilevamentoVerticiSeNecessario(frame: frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        mostraMessaggio("Sessione AR interrotta: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        mostraMessaggio("Sessione AR interrotta temporaneamente.")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        avviaSessioneAR()
    }

    // MARK: - Stabilizzazione: calcolo frame per frame

    private func aggiornaStabilita(frame: ARFrame) {
        defer { trasformCameraPrecedente = frame.camera.transform }
        guard let precedente = trasformCameraPrecedente else {
            frameStabiliConsecutivi = 0
            return
        }
        let attuale = frame.camera.transform
        let posPrecedente = simd_float3(precedente.columns.3.x, precedente.columns.3.y, precedente.columns.3.z)
        let posAttuale = simd_float3(attuale.columns.3.x, attuale.columns.3.y, attuale.columns.3.z)
        let deltaTraslazione = simd_distance(posPrecedente, posAttuale)

        // Variazione di orientamento: confrontiamo la direzione di puntamento
        // (asse -Z locale della camera) tra le due trasformazioni.
        let direzionePrecedente = simd_normalize(simd_float3(-precedente.columns.2.x, -precedente.columns.2.y, -precedente.columns.2.z))
        let direzioneAttuale = simd_normalize(simd_float3(-attuale.columns.2.x, -attuale.columns.2.y, -attuale.columns.2.z))
        let cosAngolo = max(-1, min(1, simd_dot(direzionePrecedente, direzioneAttuale)))
        let deltaRotazione = acos(cosAngolo)

        if deltaTraslazione < sogliaTraslazionePerFrame && deltaRotazione < sogliaRotazionePerFrame {
            frameStabiliConsecutivi += 1
        } else {
            frameStabiliConsecutivi = 0
        }

        aggiornaIndicatoreStabilita()
    }

    private func aggiornaIndicatoreStabilita() {
        guard Date() >= etichettaBloccataFino else { return }
        guard puntoPendente == nil, punti.count < 4 else { return }
        etichettaIstruzioni.text = stabilitaOk
            ? "🟢 Stabile — tocca l'angolo \(punti.count + 1) di 4."
            : "🔴 Tieni fermo il telefono un istante..."
    }

    // MARK: - Riconoscimento vertici assistito: rilevamento periodico in background

    private func aggiornaRilevamentoVerticiSeNecessario(frame: ARFrame) {
        contatoreFrameRilevamento += 1
        // Ogni ~20 frame invece di 15: rilevare meno spesso riduce lo sfarfallio,
        // dato che ora smussiamo comunque le posizioni (vedi aggiornaVerticiRilevati).
        guard contatoreFrameRilevamento % 20 == 0 else { return }
        guard punti.count < 4 else {
            if !verticiRilevatiSchermo.isEmpty {
                verticiRilevatiSchermo = []
                aggiornaIndicatoriVertici()
            }
            return
        }
        guard !rilevamentoVerticiInCorso else { return }
        rilevamentoVerticiInCorso = true

        let pixelBuffer = frame.capturedImage
        let viewportSize = sceneView.bounds.size
        let orientamento = view.window?.windowScene?.interfaceOrientation ?? .portrait
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            rilevamentoVerticiInCorso = false
            return
        }

        codaRilevamentoVertici.async { [weak self] in
            guard let self = self else { return }
            let request = VNDetectRectanglesRequest()
            // Un solo rettangolo (il migliore): niente più di 4 vertici mostrati
            // insieme, evitando il "caos" di più rettangoli candidati.
            request.maximumObservations = 1
            request.minimumConfidence = 0.75
            request.minimumAspectRatio = 0.2
            request.quadratureTolerance = 25

            var puntiTrovati: [CGPoint] = []
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            do {
                try handler.perform([request])
                if let migliore = request.results?.first {
                    for verticeNormalizzato in [migliore.topLeft, migliore.topRight, migliore.bottomRight, migliore.bottomLeft] {
                        let schermo = self.puntoSchermoDaImmagineNormalizzata(
                            verticeNormalizzato, frame: frame, viewportSize: viewportSize, orientamento: orientamento
                        )
                        puntiTrovati.append(schermo)
                    }
                }
            } catch {
                // Nessun crash: se il rilevamento fallisce per qualunque motivo,
                // semplicemente non ci sono vertici suggeriti in questo ciclo —
                // il tocco manuale continua a funzionare esattamente come sempre.
            }

            DispatchQueue.main.async {
                self.aggiornaVerticiRilevati(puntiTrovati)
                self.rilevamentoVerticiInCorso = false
            }
        }
    }

    /// Aggiorna i vertici suggeriti evitando lo sfarfallio: se il nuovo
    /// rilevamento ha lo stesso numero di punti di quello precedente li
    /// avviciniamo gradualmente (smussamento) invece di sostituirli di colpo;
    /// se il rilevamento non trova nulla, aspettiamo un paio di cicli vuoti
    /// consecutivi prima di far sparire i cerchi (un singolo ciclo "vuoto" non
    /// deve far lampeggiare l'indicatore).
    private func aggiornaVerticiRilevati(_ nuovi: [CGPoint]) {
        if nuovi.isEmpty {
            cicliVuotiConsecutiviRilevamento += 1
            guard cicliVuotiConsecutiviRilevamento >= 3, !verticiRilevatiSchermo.isEmpty else { return }
            verticiRilevatiSchermo = []
            aggiornaIndicatoriVertici()
            return
        }
        cicliVuotiConsecutiviRilevamento = 0

        if verticiRilevatiSchermo.count == nuovi.count {
            let fattoreSmussamento: CGFloat = 0.35
            verticiRilevatiSchermo = zip(verticiRilevatiSchermo, nuovi).map { vecchio, nuovo in
                CGPoint(
                    x: vecchio.x + (nuovo.x - vecchio.x) * fattoreSmussamento,
                    y: vecchio.y + (nuovo.y - vecchio.y) * fattoreSmussamento
                )
            }
        } else {
            verticiRilevatiSchermo = nuovi
        }
        aggiornaIndicatoriVertici()
    }

    /// Converte un punto rilevato da Vision (coordinate immagine normalizzate,
    /// origine in basso a sinistra, Y verso l'alto) in un punto sullo schermo,
    /// riusando la stessa trasformazione (frame.displayTransform) già usata per
    /// mappare i tocchi sullo schermo sulla depth map, ma in direzione inversa.
    private func puntoSchermoDaImmagineNormalizzata(
        _ puntoVision: CGPoint, frame: ARFrame, viewportSize: CGSize, orientamento: UIInterfaceOrientation
    ) -> CGPoint {
        let puntoImmagineOrigineAltoSx = CGPoint(x: puntoVision.x, y: 1 - puntoVision.y)
        let trasformazione = frame.displayTransform(for: orientamento, viewportSize: viewportSize)
        let normalizzato = puntoImmagineOrigineAltoSx.applying(trasformazione)
        return CGPoint(x: normalizzato.x * viewportSize.width, y: normalizzato.y * viewportSize.height)
    }

    private func aggiornaIndicatoriVertici() {
        livelliIndicatoriVertici.forEach { $0.removeFromSuperlayer() }
        livelliIndicatoriVertici.removeAll()
        for punto in verticiRilevatiSchermo {
            let raggio: CGFloat = 9
            let layer = CAShapeLayer()
            layer.path = UIBezierPath(ovalIn: CGRect(x: -raggio, y: -raggio, width: raggio * 2, height: raggio * 2)).cgPath
            layer.position = punto
            layer.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 2
            sceneView.layer.addSublayer(layer)
            livelliIndicatoriVertici.append(layer)
        }
    }
}
