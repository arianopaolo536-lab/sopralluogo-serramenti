import UIKit
import ARKit
import SceneKit
import CoreVideo
import simd

// Modulo "Misura con LiDAR" — versione con campionamento reale di Scene Depth
// e flusso di interazione rivisto dopo il secondo test sul campo:
//
//   - Un solo tocco (vicino al centro del serramento) propone SUBITO un
//     rettangolo simmetrico con 4 vertici, invece di richiedere 4 tocchi in
//     sequenza con conferme intermedie.
//   - Nessun popup/alert bloccante: la qualità di ciascun vertice si vede dal
//     colore/lettera, l'operatore corregge semplicemente trascinando.
//   - Il trascinamento riconosce il vertice più vicino al dito usando la
//     distanza sullo schermo (proiezione 2D), non un hit-test 3D preciso:
//     molto più facile da "agganciare" anche su un punto piccolo o lontano.
//   - Nessun blocco per "telefono non fermo": si corregge in tempo reale
//     trascinando, quindi il vincolo di stabilità sul tocco iniziale è stato
//     rimosso (rallentava senza un reale beneficio, dato il resto del flusso).
//   - FERMO IMMAGINE al primo tocco: il tremolio del flusso live in mano
//     rendeva impreciso il puntamento dei 4 angoli. Al tocco iniziale il
//     fotogramma (immagine + depth map di quell'istante) viene congelato:
//     da lì in poi si lavora su un'immagine ferma, non più sul video che
//     continua a muoversi. "Ripristina" fa ripartire la camera live per
//     ri-tentare con un'inquadratura diversa.
//
// Per ciascun vertice, la coordinata 3D viene determinata PRIMA di tutto
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
    /// Un solo popup (invece di 3 scritte fisse in cima allo schermo, che
    /// disturbavano la mira sui vertici): mostra istruzioni/legenda/quote a
    /// seconda del momento e sparisce da solo dopo qualche secondo di inattività.
    private let etichettaPopup = UILabel()
    private let bottoneAnnulla = UIButton(type: .system)
    private let bottoneRipristina = UIButton(type: .system)
    private let bottoneConferma = UIButton(type: .system)
    private let bottoneParallelo = UIButton(type: .system)

    /// Un vertice misurato, con tutti i metadati richiesti per la tracciabilità
    /// (metodo usato, confidenza, profondità in metri quando disponibile).
    private struct PuntoMisurato {
        var posizione: SCNVector3
        var profonditaM: Double?   // nil per i punti da raycastFallback
        var confidence: String     // "alta" | "media" | "bassa"
        var metodo: String         // "smoothedSceneDepth" | "sceneDepth" | "raycastFallback"
        var nodo: SCNNode
    }

    // Ordine dei 4 vertici: alto-sx, alto-dx, basso-dx, basso-sx.
    // O sono tutti e 4 presenti (rettangolo proposto), o l'array è vuoto.
    private var punti: [PuntoMisurato] = []
    private var nodoLinee: SCNNode?
    /// Indice (in `punti`) del vertice attualmente trascinato, se presente.
    private var indiceInTrascinamento: Int?
    /// Il fotogramma "congelato" al primo tocco: quando presente, tutte le
    /// letture di profondità (creazione E trascinamento dei vertici) usano
    /// SEMPRE questo, mai il frame live — è il fermo immagine che elimina il
    /// tremolio della camera in mano durante il posizionamento dei punti.
    private var frameCongelato: ARFrame?
    /// Contatore usato da mostraMessaggio per capire, quando scade il timer di
    /// auto-nascondi di UN messaggio, se nel frattempo non ne è già arrivato
    /// uno più recente (nel qual caso non deve nascondere nulla).
    private var generazioneMessaggio = 0

    /// Tolleranza (in punti schermo) entro cui un tocco/trascinamento viene
    /// associato al vertice più vicino: intenzionalmente generosa, dato che i
    /// vertici vanno "agganciati" facilmente col dito.
    private let tolleranzaTrascinamento: CGFloat = 70

    /// Mentre si trascina, il punto viene campionato più in alto rispetto al
    /// dito (come i "pin" di Mappe): così il dito non copre più il punto che
    /// si sta posizionando e si vede sempre dove sta andando a finire.
    private let scostamentoDito: CGFloat = 80

    /// "Parallelismo" abilitabile/disabilitabile a scelta dell'operatore: a
    /// differenza della vecchia rettifica automatica (che ricalcolava TUTTO il
    /// rettangolo e lo faceva ruotare in modo imprevedibile), qui si muove SOLO
    /// la coppia di vertici collegata a quello trascinato — lato alto insieme,
    /// oppure lato basso insieme — traslandola in blocco così il lato resta
    /// parallelo a se stesso. Flusso consigliato: prima i due vertici alti (col
    /// parallelismo attivo restano allineati), poi i due bassi.
    private var parallelismoAttivo = false

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
        mostraMessaggio(
            "Tocca il centro approssimativo del serramento: l'immagine si ferma e comparirà un rettangolo da correggere trascinando i 4 angoli.\n🟢 A = Alta   🟡 M = Media   🟠 B = Bassa   🟣 R = Fallback raycast",
            autoNascondiDopo: 6
        )
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
        etichettaPopup.textColor = .white
        etichettaPopup.numberOfLines = 6
        etichettaPopup.font = .systemFont(ofSize: 14, weight: .semibold)
        etichettaPopup.textAlignment = .center
        etichettaPopup.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        etichettaPopup.layer.cornerRadius = 12
        etichettaPopup.layer.masksToBounds = true
        etichettaPopup.translatesAutoresizingMaskIntoConstraints = false
        etichettaPopup.alpha = 0
        etichettaPopup.isUserInteractionEnabled = false

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

        bottoneConferma.setTitle("Fine misura", for: .normal)
        bottoneConferma.setTitleColor(.white, for: .normal)
        bottoneConferma.backgroundColor = UIColor(red: 0.114, green: 0.435, blue: 0.361, alpha: 1) // verde brand
        bottoneConferma.layer.cornerRadius = 10
        bottoneConferma.isEnabled = false
        bottoneConferma.alpha = 0.4
        bottoneConferma.addTarget(self, action: #selector(conferma), for: .touchUpInside)

        bottoneParallelo.layer.cornerRadius = 10
        bottoneParallelo.addTarget(self, action: #selector(toggleParallelismo), for: .touchUpInside)
        aggiornaAspettoBottoneParallelo()

        let barraBottoni = UIStackView(arrangedSubviews: [bottoneAnnulla, bottoneRipristina, bottoneConferma])
        barraBottoni.axis = .horizontal
        barraBottoni.distribution = .fillEqually
        barraBottoni.spacing = 8

        for bottone in [bottoneAnnulla, bottoneRipristina, bottoneConferma, bottoneParallelo] {
            bottone.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            bottone.titleLabel?.adjustsFontSizeToFitWidth = true
            bottone.titleLabel?.minimumScaleFactor = 0.6
        }

        // Tutti i controlli in basso (niente più scritte fisse in cima che
        // disturbano la mira sui vertici durante la misurazione): il tasto
        // parallelismo sopra, i 3 pulsanti principali sotto.
        let barraControlli = UIStackView(arrangedSubviews: [bottoneParallelo, barraBottoni])
        barraControlli.axis = .vertical
        barraControlli.spacing = 8
        barraControlli.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(etichettaPopup)
        view.addSubview(barraControlli)

        NSLayoutConstraint.activate([
            etichettaPopup.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            etichettaPopup.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            etichettaPopup.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            etichettaPopup.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            barraControlli.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            barraControlli.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            barraControlli.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),

            bottoneParallelo.heightAnchor.constraint(equalToConstant: 40),
            barraBottoni.heightAnchor.constraint(equalToConstant: 46),
        ])
    }

    private func configuraGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(gestitoTap(_:)))
        sceneView.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(gestitoPan(_:)))
        sceneView.addGestureRecognizer(pan)
    }

    // MARK: - Interazione: un tocco propone il rettangolo, poi si corregge trascinando

    @objc private func gestitoTap(_ gesture: UITapGestureRecognizer) {
        // Il rettangolo esiste già: da qui in poi si corregge solo trascinando
        // i vertici, un nuovo tocco non fa nulla (evita di ricreare tutto per
        // sbaglio e di perdere le correzioni già fatte).
        guard punti.isEmpty else { return }
        guard let frame = sceneView.session.currentFrame else {
            mostraMessaggio("Fotogramma non ancora pronto: attendi un istante e riprova.")
            return
        }

        let posizione = gesture.location(in: sceneView)
        // Il campionamento di QUESTO punto usa ancora la sessione live (per
        // poter contare sul fallback raycast se la depth map non è pronta lì);
        // solo se il punto è valido congeliamo il fotogramma per tutto il resto.
        guard let misurato = puntoDaSchermo(posizione) else {
            mostraMessaggio("Punto non rilevato: avvicina o inquadra meglio la superficie.")
            return
        }
        frameCongelato = frame
        sceneView.session.pause()
        creaRettangoloSimmetrico(centro: misurato, frame: frame)
    }

    /// Crea un rettangolo simmetrico (angoli retti, lati uguali a coppie)
    /// centrato sul punto toccato, orientato come il piano frontale alla
    /// camera in quel momento. È solo un punto di partenza: l'operatore lo
    /// allinea al vero serramento trascinando ciascun angolo.
    private func creaRettangoloSimmetrico(centro: PuntoMisurato, frame: ARFrame) {
        let trasformCamera = frame.camera.transform
        let asseDestro = simd_normalize(simd_float3(trasformCamera.columns.0.x, trasformCamera.columns.0.y, trasformCamera.columns.0.z))
        let asseSu = simd_normalize(simd_float3(trasformCamera.columns.1.x, trasformCamera.columns.1.y, trasformCamera.columns.1.z))
        let centroPos = simd_float3(centro.posizione.x, centro.posizione.y, centro.posizione.z)

        // Dimensioni di partenza (0.8 x 1.2 m): una finestra "media" plausibile,
        // solo come punto di partenza — l'operatore la corregge subito dopo.
        let mezzaLarghezza: Float = 0.4
        let mezzaAltezza: Float = 0.6

        let offsetAngoli: [(Float, Float)] = [
            (-1, 1),  // alto-sx
            (1, 1),   // alto-dx
            (1, -1),  // basso-dx
            (-1, -1), // basso-sx
        ]

        punti.forEach { $0.nodo.removeFromParentNode() }
        punti = offsetAngoli.map { (ox, oy) in
            let posizioneMondo = centroPos + asseDestro * (ox * mezzaLarghezza) + asseSu * (oy * mezzaAltezza)
            var pm = PuntoMisurato(
                posizione: SCNVector3(posizioneMondo.x, posizioneMondo.y, posizioneMondo.z),
                profonditaM: centro.profonditaM,
                confidence: centro.confidence,
                metodo: centro.metodo,
                nodo: SCNNode()
            )
            pm.nodo = creaNodoPunto(per: pm)
            sceneView.scene.rootNode.addChildNode(pm.nodo)
            return pm
        }

        bottoneConferma.isEnabled = true
        bottoneConferma.alpha = 1
        // ridisegnaLineeECalcola() mostra subito le quote nel popup: è già
        // un'indicazione sufficiente che da qui si corregge trascinando.
        ridisegnaLineeECalcola()
    }

    // MARK: - Trascinamento: si sceglie il vertice più vicino sullo SCHERMO (2D),
    // non tramite hit-test 3D sulla geometria — molto più facile da "agganciare".

    @objc private func gestitoPan(_ gesture: UIPanGestureRecognizer) {
        let posizione = gesture.location(in: sceneView)
        switch gesture.state {
        case .began:
            guard !punti.isEmpty else { return }
            var indiceMigliore: Int?
            var distanzaMinima = tolleranzaTrascinamento
            for (i, p) in punti.enumerated() {
                let proiettato = sceneView.projectPoint(p.nodo.position)
                let d = hypot(CGFloat(proiettato.x) - posizione.x, CGFloat(proiettato.y) - posizione.y)
                if d < distanzaMinima {
                    distanzaMinima = d
                    indiceMigliore = i
                }
            }
            indiceInTrascinamento = indiceMigliore
            if let indice = indiceMigliore {
                // "Solleva" il punto agganciato (si ingrandisce leggermente):
                // conferma visivamente quale vertice si sta trascinando anche
                // se il dito lo copre nell'istante del tocco.
                punti[indice].nodo.runAction(.scale(to: 1.4, duration: 0.1))
            }
        case .changed:
            guard let indice = indiceInTrascinamento, indice < punti.count else { return }
            // Si campiona più in alto rispetto al dito (come un pin di
            // Mappe): il dito copre il punto di tocco, ma il punto vero
            // resta visibile più su, spostato della stessa quantità.
            let posizioneCampionamento = CGPoint(x: posizione.x, y: posizione.y - scostamentoDito)
            guard let misurato = puntoDaSchermo(posizioneCampionamento) else { return }
            if parallelismoAttivo, indice == 2 || indice == 3 {
                // Lato basso: con il lato alto già sistemato, qui conta solo
                // "quanto in basso" (altezza) — la posizione orizzontale/di
                // profondità resta agganciata al vertice alto corrispondente,
                // così il lato basso è sempre parallelo a quello alto e tutti
                // gli angoli restano a 90°.
                aggiornaLatoBassoVincolatoAllAlto(indiceTrascinato: indice, misurato: misurato)
            } else {
                let posizionePrecedente = punti[indice].posizione
                aggiornaPunto(indice, con: misurato)
                if parallelismoAttivo, let partner = indicePartnerParallelo(indice) {
                    let delta = SCNVector3(
                        misurato.posizione.x - posizionePrecedente.x,
                        misurato.posizione.y - posizionePrecedente.y,
                        misurato.posizione.z - posizionePrecedente.z
                    )
                    traslaPunto(partner, delta: delta)
                }
            }
        case .ended, .cancelled:
            // Il punto "si riappoggia" (torna alla dimensione normale) quando
            // si solleva il dito.
            if let indice = indiceInTrascinamento, indice < punti.count {
                punti[indice].nodo.runAction(.scale(to: 1.0, duration: 0.15))
            }
            indiceInTrascinamento = nil
        default:
            break
        }
    }

    // MARK: - Determinazione del punto 3D: Scene Depth prima, raycast come fallback

    private func puntoDaSchermo(_ posizioneSchermo: CGPoint) -> PuntoMisurato? {
        // Se il fotogramma è congelato (dopo il primo tocco), si usa SEMPRE
        // quello: niente più nuove letture dal video live, tutta la misura
        // (creazione e trascinamenti) resta ancorata a quell'unico scatto.
        guard let frame = frameCongelato ?? sceneView.session.currentFrame else { return nil }
        if let daDepth = puntoDaDepthMap(posizioneSchermo, frame: frame) {
            return daDepth
        }
        // Fallback raycast: utile solo prima del fermo immagine (richiede una
        // sessione live in tracking); a fotogramma congelato la depth map
        // già campionata resta l'unica fonte, com'è corretto che sia.
        guard frameCongelato == nil else { return nil }
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

    // MARK: - Aggiornamento di un vertice esistente (dopo trascinamento)

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
        bottoneConferma.isEnabled = false
        bottoneConferma.alpha = 0.4
        // Se il fotogramma era congelato, si riparte dalla camera live per
        // poter ri-tentare con un'inquadratura diversa.
        if frameCongelato != nil {
            frameCongelato = nil
            avviaSessioneAR()
        }
        mostraMessaggio(
            "Tocca il centro approssimativo del serramento: l'immagine si ferma e comparirà un rettangolo da correggere trascinando i 4 angoli.",
            autoNascondiDopo: 4
        )
    }

    // MARK: - Aspetto dei vertici (colore + testo, non solo colore)

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
        // Sfera ben visibile: la tolleranza di trascinamento è comunque basata
        // sulla distanza sullo schermo (non sulla geometria), quindi qui conta
        // soprattutto la visibilità, non la dimensione del bersaglio.
        let sfera = SCNSphere(radius: 0.026)
        sfera.firstMaterial?.diffuse.contents = coloreQualita(misurato)
        sfera.firstMaterial?.emission.contents = coloreQualita(misurato)
        let nodo = SCNNode(geometry: sfera)
        nodo.position = misurato.posizione
        nodo.renderingOrder = 20
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
        nodoTesto.position = SCNVector3(0.012, 0.016, 0)
        nodoTesto.constraints = [SCNBillboardConstraint()]
        nodoTesto.renderingOrder = 10
        nodoGenitore.addChildNode(nodoTesto)
    }

    // MARK: - Calcolo quote

    private func ridisegnaLineeECalcola() {
        nodoLinee?.removeFromParentNode()
        guard punti.count == 4 else { return }
        let posizioni = punti.map { $0.nodo.position }
        // Larghezza/altezza come media dei due lati opposti: già di per sé
        // auto-correttiva sulle piccole asimmetrie, SENZA ricalcolare
        // un'orientamento globale che farebbe "ruotare" tutta la forma quando
        // si sposta un solo angolo — ogni vertice resta indipendente.
        let larghezzaM = (distanza(posizioni[0], posizioni[1]) + distanza(posizioni[3], posizioni[2])) / 2
        let altezzaM = (distanza(posizioni[0], posizioni[3]) + distanza(posizioni[1], posizioni[2])) / 2
        let superficieM2 = larghezzaM * altezzaM

        let riepilogoPunti = punti.enumerated().map { i, p in "P\(i + 1)=\(letteraQualita(p))" }.joined(separator: "  ")
        let testoQuote = String(
            format: "L = %.0f mm   H = %.0f mm\nSuperficie = %.2f m²\n(MISURA INDICATIVA — DA VERIFICARE)\n%@",
            larghezzaM * 1000, altezzaM * 1000, superficieM2, riepilogoPunti
        )
        // Ogni aggiornamento (durante il trascinamento) fa comparire/rimanere
        // visibile il popup; 1.8s dopo l'ultimo aggiornamento (cioè quando si
        // smette di toccare) sparisce da solo, lasciando la vista libera.
        mostraMessaggio(testoQuote, autoNascondiDopo: 1.8)

        nodoLinee = disegnaRettangolo(posizioni)
        if let linee = nodoLinee { sceneView.scene.rootNode.addChildNode(linee) }
    }

    private func distanza(_ a: SCNVector3, _ b: SCNVector3) -> Float {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return sqrtf(dx * dx + dy * dy + dz * dz)
    }

    /// Disegna il quadrilatero usando DIRETTAMENTE le posizioni dei 4 vertici
    /// trascinati (nessuna rettifica/riorientamento globale): ogni angolo si
    /// sposta in modo diretto e indipendente, senza far "ruotare" il resto
    /// della forma. Contorno con cilindri sottili (ben visibili, a differenza
    /// delle semplici linee di SceneKit che restano sempre molto sottili) più
    /// una faccia semitrasparente che riempie l'area.
    private func disegnaRettangolo(_ vertici: [SCNVector3]) -> SCNNode {
        let contenitore = SCNNode()
        for i in 0..<vertici.count {
            let a = vertici[i]
            let b = vertici[(i + 1) % vertici.count]
            contenitore.addChildNode(cilindroTra(a, b, raggio: 0.007, colore: .systemYellow))
        }
        contenitore.addChildNode(creaFacciaSemitrasparente(vertici))
        return contenitore
    }

    private func cilindroTra(_ a: SCNVector3, _ b: SCNVector3, raggio: CGFloat, colore: UIColor) -> SCNNode {
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        let lunghezza = sqrtf(dx * dx + dy * dy + dz * dz)
        let cilindro = SCNCylinder(radius: raggio, height: CGFloat(max(lunghezza, 0.0001)))
        cilindro.firstMaterial?.diffuse.contents = colore
        cilindro.firstMaterial?.emission.contents = colore
        cilindro.firstMaterial?.lightingModel = .constant
        let nodo = SCNNode(geometry: cilindro)
        nodo.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        // Sempre disegnata sopra la faccia semitrasparente (evita che il
        // riempimento "mangi" visivamente il contorno).
        nodo.renderingOrder = 10

        // SCNCylinder è orientato di default lungo l'asse Y locale (0,1,0):
        // calcoliamo la rotazione che porta (0,1,0) sulla direzione a->b.
        guard lunghezza > 0.0001 else { return nodo }
        let direzione = simd_normalize(simd_float3(dx, dy, dz))
        let asseY = simd_float3(0, 1, 0)
        let prodottoScalare = max(-1, min(1, simd_dot(asseY, direzione)))
        if prodottoScalare < -0.9999 {
            nodo.rotation = SCNVector4(1, 0, 0, Float.pi)
        } else if prodottoScalare < 0.9999 {
            let asseRotazione = simd_normalize(simd_cross(asseY, direzione))
            nodo.rotation = SCNVector4(asseRotazione.x, asseRotazione.y, asseRotazione.z, acos(prodottoScalare))
        }
        return nodo
    }

    private func creaFacciaSemitrasparente(_ vertici: [SCNVector3]) -> SCNNode {
        // Ventaglio di 4 triangoli dal baricentro, invece di 2 triangoli con
        // una diagonale al centro: i 4 punti reali agganciati col dito quasi
        // mai sono perfettamente complanari, e la diagonale creava una
        // "piega"/cucitura visibile in mezzo che sembrava una seconda linea.
        // Col ventaglio dal centro la superficie resta comunque chiusa ma
        // senza quella cucitura lunga e visibile.
        let centro = SCNVector3(
            (vertici[0].x + vertici[1].x + vertici[2].x + vertici[3].x) / 4,
            (vertici[0].y + vertici[1].y + vertici[2].y + vertici[3].y) / 4,
            (vertici[0].z + vertici[1].z + vertici[2].z + vertici[3].z) / 4
        )
        let tuttiIVertici = [centro] + vertici // 0 = centro, 1...4 = angoli
        var indici: [Int32] = []
        for i in 0..<4 {
            let a = Int32(1 + i)
            let b = Int32(1 + (i + 1) % 4)
            indici.append(contentsOf: [0, a, b])
        }
        let sorgente = SCNGeometrySource(vertices: tuttiIVertici)
        let elemento = SCNGeometryElement(indices: indici, primitiveType: .triangles)
        let geometria = SCNGeometry(sources: [sorgente], elements: [elemento])
        let materiale = SCNMaterial()
        materiale.diffuse.contents = UIColor.systemYellow.withAlphaComponent(0.28)
        materiale.isDoubleSided = true
        materiale.lightingModel = .constant
        // Impostazioni esplicite di alpha-blend: senza queste, su alcuni
        // dispositivi il doppio lato (isDoubleSided) unito alla scrittura sullo
        // z-buffer fa sembrare la superficie molto più opaca del previsto
        // invece che semitrasparente.
        materiale.blendMode = .alpha
        materiale.writesToDepthBuffer = false
        materiale.readsFromDepthBuffer = false
        geometria.materials = [materiale]
        let nodo = SCNNode(geometry: geometria)
        nodo.renderingOrder = 0
        return nodo
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

    // MARK: - Messaggi di stato: un solo popup che appare e sparisce da solo

    /// Mostra `testo` nel popup (con una breve dissolvenza in entrata) e lo fa
    /// sparire da solo dopo `autoNascondiDopo` secondi di inattività — cioè se
    /// nel frattempo non arriva un messaggio più recente che rimandi la
    /// scadenza (per es. durante un trascinamento continuo, dove ogni
    /// aggiornamento tiene il popup visibile finché non ci si ferma).
    /// `autoNascondiDopo: 0` lo lascia visibile finché non arriva un altro messaggio.
    private func mostraMessaggio(_ testo: String, autoNascondiDopo secondi: TimeInterval = 2.5) {
        etichettaPopup.text = testo
        generazioneMessaggio += 1
        let generazioneCorrente = generazioneMessaggio
        UIView.animate(withDuration: 0.15) {
            self.etichettaPopup.alpha = 1
        }
        guard secondi > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + secondi) { [weak self] in
            guard let self = self, self.generazioneMessaggio == generazioneCorrente else { return }
            UIView.animate(withDuration: 0.3) {
                self.etichettaPopup.alpha = 0
            }
        }
    }

    // MARK: - Azioni

    @objc private func annulla() {
        alCompletamento?(nil)
    }

    /// Attiva/disattiva il parallelismo: quando attivo, muovere un vertice
    /// trascina con sé (in blocco, stessa traslazione) il vertice abbinato
    /// sullo stesso lato, così quel lato resta parallelo a se stesso invece di
    /// doverlo allineare a mano punto per punto. Le finestre sono quasi sempre
    /// a squadro, quindi allineare prima i due vertici alti e poi i due bassi
    /// con questo aiuto attivo è in genere il modo più rapido di procedere.
    @objc private func toggleParallelismo() {
        parallelismoAttivo.toggle()
        aggiornaAspettoBottoneParallelo()
        mostraMessaggio(
            parallelismoAttivo
                ? "Parallelismo ON: sposta un vertice, quello abbinato sullo stesso lato lo segue. Fai prima i due alti, poi i due bassi."
                : "Parallelismo OFF: ogni vertice si muove da solo."
        )
    }

    private func aggiornaAspettoBottoneParallelo() {
        if parallelismoAttivo {
            bottoneParallelo.setTitle("🔒 Parallelismo: ON", for: .normal)
            bottoneParallelo.setTitleColor(.white, for: .normal)
            bottoneParallelo.backgroundColor = UIColor(red: 0.114, green: 0.435, blue: 0.361, alpha: 1) // verde brand
        } else {
            bottoneParallelo.setTitle("🔓 Parallelismo: OFF", for: .normal)
            bottoneParallelo.setTitleColor(.white, for: .normal)
            bottoneParallelo.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        }
    }

    /// Indice del vertice "abbinato" sullo stesso lato: 0=alto-sx/1=alto-dx
    /// formano il lato alto, 3=basso-sx/2=basso-dx formano il lato basso.
    private func indicePartnerParallelo(_ indice: Int) -> Int? {
        switch indice {
        case 0: return 1
        case 1: return 0
        case 2: return 3
        case 3: return 2
        default: return nil
        }
    }

    /// Trasla rigidamente un vertice (stessa direzione e distanza del
    /// trascinamento appena fatto sul suo abbinato), senza ricampionare la
    /// depth map: non è una nuova misura, è solo "seguire" il lato in blocco.
    private func traslaPunto(_ indice: Int, delta: SCNVector3) {
        guard indice < punti.count else { return }
        let posizioneAttuale = punti[indice].posizione
        let nuovaPosizione = SCNVector3(
            posizioneAttuale.x + delta.x,
            posizioneAttuale.y + delta.y,
            posizioneAttuale.z + delta.z
        )
        let nodoEsistente = punti[indice].nodo
        nodoEsistente.position = nuovaPosizione
        punti[indice].posizione = nuovaPosizione
        ridisegnaLineeECalcola()
    }

    /// Lato basso vincolato al lato alto: le finestre sono quasi sempre a
    /// squadro, quindi una volta sistemato il lato alto (2 vertici) il lato
    /// basso serve solo per dire "quanto è alta" la finestra — orizzontalmente
    /// e in profondità resta sempre allineato al vertice alto corrispondente.
    /// Risultato: i 2 angoli in basso restano sempre a 90° e paralleli al lato
    /// alto, indipendentemente da dove si tocca esattamente con il dito.
    private func aggiornaLatoBassoVincolatoAllAlto(indiceTrascinato: Int, misurato: PuntoMisurato) {
        guard punti.count == 4, indiceTrascinato == 2 || indiceTrascinato == 3 else { return }

        let altoSx = simd_float3(punti[0].nodo.position.x, punti[0].nodo.position.y, punti[0].nodo.position.z)
        let altoDx = simd_float3(punti[1].nodo.position.x, punti[1].nodo.position.y, punti[1].nodo.position.z)
        let latoAlto = altoDx - altoSx
        guard simd_length(latoAlto) > 0.0001 else { return }
        let direzioneAlto = simd_normalize(latoAlto)

        // Direzione "verso il basso" ortogonalizzata rispetto al lato alto
        // (garantisce i 90° esatti), partendo dal basso reale del mondo.
        let bassoMondo = simd_float3(0, -1, 0)
        var giu = bassoMondo - direzioneAlto * simd_dot(bassoMondo, direzioneAlto)
        if simd_length(giu) < 0.0001 { giu = simd_float3(0, -1, 0) } // caso limite: lato alto verticale
        giu = simd_normalize(giu)

        let puntoTrascinato = simd_float3(misurato.posizione.x, misurato.posizione.y, misurato.posizione.z)
        let altoDiRiferimento = indiceTrascinato == 2 ? altoDx : altoSx
        // Altezza = quanto in basso è stato trascinato il dito rispetto al
        // proprio vertice alto, proiettato sulla direzione "giù": è l'unico
        // grado di libertà che l'operatore controlla per il lato basso.
        let altezza = max(0, simd_dot(puntoTrascinato - altoDiRiferimento, giu))

        let nuovoBassoSxV = altoSx + giu * altezza
        let nuovoBassoDxV = altoDx + giu * altezza
        let nuovoBassoSx = SCNVector3(nuovoBassoSxV.x, nuovoBassoSxV.y, nuovoBassoSxV.z)
        let nuovoBassoDx = SCNVector3(nuovoBassoDxV.x, nuovoBassoDxV.y, nuovoBassoDxV.z)

        // Il vertice effettivamente toccato prende anche i metadati della
        // nuova lettura (confidenza/metodo/profondità); l'altro angolo basso
        // lo segue solo in posizione, per restare parallelo al lato alto.
        if indiceTrascinato == 3 {
            aggiornaMetadatiEPosizione(3, misurato: misurato, posizione: nuovoBassoSx)
            aggiornaSoloPosizione(2, nuovoBassoDx)
        } else {
            aggiornaMetadatiEPosizione(2, misurato: misurato, posizione: nuovoBassoDx)
            aggiornaSoloPosizione(3, nuovoBassoSx)
        }
        ridisegnaLineeECalcola()
    }

    private func aggiornaMetadatiEPosizione(_ indice: Int, misurato: PuntoMisurato, posizione: SCNVector3) {
        guard indice < punti.count else { return }
        let nodo = punti[indice].nodo
        nodo.position = posizione
        nodo.childNodes.forEach { $0.removeFromParentNode() }
        var m = misurato
        m.posizione = posizione
        aggiornaAspettoNodo(nodo, per: m)
        punti[indice].posizione = posizione
        punti[indice].profonditaM = misurato.profonditaM
        punti[indice].confidence = misurato.confidence
        punti[indice].metodo = misurato.metodo
    }

    private func aggiornaSoloPosizione(_ indice: Int, _ posizione: SCNVector3) {
        guard indice < punti.count else { return }
        punti[indice].nodo.position = posizione
        punti[indice].posizione = posizione
    }

    @objc private func conferma() {
        guard punti.count == 4 else { return }
        let posizioni = punti.map { $0.nodo.position }
        // Stesso calcolo (media dei lati opposti) usato per il testo mostrato
        // a schermo, così la misura salvata corrisponde esattamente a quella vista.
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
        mostraMessaggio("Sessione AR interrotta: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        mostraMessaggio("Sessione AR interrotta temporaneamente.")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        avviaSessioneAR()
    }
}
