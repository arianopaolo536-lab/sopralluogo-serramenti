import UIKit
import ARKit
import SceneKit
import CoreVideo
import CoreImage
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
//
// --- UI (agosto 2026) ---------------------------------------------------
// Interfaccia ricostruita per aderire al mockup approvato ("Misura LiDAR"):
// header scuro, pillola di stato LIVE/FREEZE, toolbar destra (Griglia /
// Centro), pannello quote a tile, barra azioni in basso. Il "parallelismo"
// (blocco lati paralleli) è stato rimosso su richiesta: ogni vertice si
// trascina di nuovo in modo indipendente. Questa sezione tocca SOLO
// presentazione/interazione: nessuna delle funzioni di calcolo/misura/
// depth/freeze è stata modificata.

/// Vista "passante": intercetta il tocco SOLO se cade su un suo sottoview
/// realmente interattivo (es. un pulsante) — altrimenti lascia proseguire il
/// tocco verso la sceneView sottostante. Usata per le card informative in
/// basso, che altrimenti "rubano" i tocchi destinati ai vertici quando il
/// serramento occupa gran parte dello schermo (un vertice può finire
/// visivamente sotto una card).
private final class VistaPassante: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let colpito = super.hitTest(point, with: event) else { return nil }
        return colpito == self ? nil : colpito
    }
}

/// Stessa logica di `VistaPassante`, per i contenitori realizzati con
/// UIStackView (che di per sé non disegna nulla ma può comunque intercettare
/// i tocchi nelle zone vuote/di spaziatura tra le card).
private final class StackPassante: UIStackView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let colpito = super.hitTest(point, with: event) else { return nil }
        return colpito == self ? nil : colpito
    }
}

final class VistaMisuraLidar: UIViewController, ARSCNViewDelegate, ARSessionDelegate {

    /// true se il dispositivo supporta realmente Scene Depth (non un check sul
    /// modello di iPhone): è il requisito corretto per ciò che questo modulo usa.
    static var lidarDisponibile: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    var alCompletamento: (([String: Any]?) -> Void)?

    private let sceneView = ARSCNView()

    // --- Header ---
    private let headerView = UIView()
    private let bottoneIndietro = UIButton(type: .system)
    private let etichettaTitoloHeader = UILabel()
    private let etichettaSottotitoloHeader = UILabel()
    private let bottoneGuida = UIButton(type: .system)

    // --- Pillola di stato LIVE/FREEZE + istruzione persistente ---
    private let pillStato = VistaPassante()
    private let puntinoStato = UIView()
    private let etichettaStato = UILabel()
    private let etichettaIstruzionePill = UILabel()

    // --- Toolbar destra (Griglia / Centro) ---
    private let toolbarDestra = StackPassante()
    private let bottoneToolGriglia = UIButton(type: .system)
    private let bottoneToolCentro = UIButton(type: .system)
    private var grigliaAttiva = false
    private var livelloGriglia: CAShapeLayer?

    // --- Badge tecnici (Profondità / Attendibilità) ---
    private let badgeProfonditaLabel = UILabel()
    private let badgeAttendibilitaLabel = UILabel()

    // --- Pannello quote (tile Larghezza / Altezza / Superficie / Attendibilità) ---
    private let tileLarghezzaValore = UILabel()
    private let tileAltezzaValore = UILabel()
    private let tileSuperficieValore = UILabel()
    private let tileAttendibilitaValore = UILabel()

    // --- Stepper inferiore ---
    private var puntiniStepper: [UIView] = []
    private var etichetteStepper: [UILabel] = []

    /// Contenitore verticale di tutte le card in basso (quote, azioni),
    /// ancorato alla safe area inferiore.
    private let stackInferiore = StackPassante()

    /// Un solo popup (invece di scritte fisse sullo schermo, che disturbavano
    /// la mira sui vertici): mostra messaggi transitori (errori, avvisi,
    /// legenda iniziale) e sparisce da solo dopo qualche secondo di
    /// inattività. È un vero pannello "a vetro" (blur nativo).
    private let vetroPopup = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let etichettaPopup = UILabel()

    private let bottoneAnnulla = UIButton(type: .system)
    private let bottoneRipristina = UIButton(type: .system)
    private let bottoneConferma = UIButton(type: .system)

    /// Verde brand QID (stesso --primary del sito, #1d6f5c), usato per gli
    /// accenti "glass" (bordi, pulsante primario) coerenti col resto dell'app.
    private let coloreBrand = UIColor(red: 0.114, green: 0.435, blue: 0.361, alpha: 1)
    private let coloreBrandScuro = UIColor(red: 0.078, green: 0.314, blue: 0.259, alpha: 1)
    /// Blu notte/antracite dell'header e delle card, rosso QID per
    /// annulla/elimina, blu accento per lo stato FREEZE, verde acceso per il
    /// contorno AR (più visibile del giallo precedente su vetri/muri chiari).
    private let coloreSfondoHeader = UIColor(red: 0.043, green: 0.075, blue: 0.114, alpha: 1)
    private let coloreCardScura = UIColor(red: 0.067, green: 0.098, blue: 0.137, alpha: 0.82)
    private let coloreBluAccento = UIColor(red: 0.22, green: 0.51, blue: 0.86, alpha: 1)
    private let coloreRossoQID = UIColor(red: 0.753, green: 0.224, blue: 0.169, alpha: 1)
    private let coloreContornoAR = UIColor(red: 0.204, green: 0.780, blue: 0.549, alpha: 1)

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
    /// Immagine a colori (capturedImage) del fotogramma congelato, già
    /// convertita e raddrizzata NELL'ISTANTE STESSO del fermo immagine — non
    /// riletta più tardi da frame.capturedImage, perché quel CVPixelBuffer
    /// (diverso dalla depth map, che invece resta valida) può essere
    /// riciclato da ARKit nel tempo in cui l'operatore trascina i vertici,
    /// rendendo la lettura tardiva silenziosamente vuota/nulla. Usata solo
    /// per generare la foto con le quote scritte sopra alla conferma.
    private var immagineCongelata: UIImage?
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

    // MARK: - Overlay: assemblaggio dei componenti della nuova UI

    private func configuraOverlay() {
        costruisciHeader()
        costruisciPillStato()
        costruisciToolbarDestra()
        costruisciPopupTransitorio()
        costruisciPannelloInferiore()
    }

    private func costruisciHeader() {
        headerView.backgroundColor = coloreSfondoHeader
        headerView.translatesAutoresizingMaskIntoConstraints = false

        bottoneIndietro.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        bottoneIndietro.tintColor = .white
        bottoneIndietro.addTarget(self, action: #selector(annulla), for: .touchUpInside)
        bottoneIndietro.translatesAutoresizingMaskIntoConstraints = false

        etichettaTitoloHeader.text = "Misura LiDAR"
        etichettaTitoloHeader.font = .systemFont(ofSize: 17, weight: .bold)
        etichettaTitoloHeader.textColor = .white
        etichettaTitoloHeader.textAlignment = .center

        etichettaSottotitoloHeader.text = "Posiziona i 4 vertici del serramento"
        etichettaSottotitoloHeader.font = .systemFont(ofSize: 12, weight: .regular)
        etichettaSottotitoloHeader.textColor = UIColor.white.withAlphaComponent(0.6)
        etichettaSottotitoloHeader.textAlignment = .center

        let stackTitoli = UIStackView(arrangedSubviews: [etichettaTitoloHeader, etichettaSottotitoloHeader])
        stackTitoli.axis = .vertical
        stackTitoli.spacing = 2
        stackTitoli.alignment = .center
        stackTitoli.translatesAutoresizingMaskIntoConstraints = false

        bottoneGuida.setTitle("Guida", for: .normal)
        bottoneGuida.setImage(UIImage(systemName: "questionmark.circle"), for: .normal)
        bottoneGuida.tintColor = .white
        bottoneGuida.setTitleColor(.white, for: .normal)
        bottoneGuida.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        bottoneGuida.addTarget(self, action: #selector(mostraGuida), for: .touchUpInside)
        bottoneGuida.translatesAutoresizingMaskIntoConstraints = false

        headerView.addSubview(bottoneIndietro)
        headerView.addSubview(stackTitoli)
        headerView.addSubview(bottoneGuida)
        view.addSubview(headerView)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 64),

            bottoneIndietro.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bottoneIndietro.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -14),
            bottoneIndietro.widthAnchor.constraint(equalToConstant: 30),
            bottoneIndietro.heightAnchor.constraint(equalToConstant: 30),

            stackTitoli.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            stackTitoli.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -8),
            stackTitoli.leadingAnchor.constraint(greaterThanOrEqualTo: bottoneIndietro.trailingAnchor, constant: 8),
            stackTitoli.trailingAnchor.constraint(lessThanOrEqualTo: bottoneGuida.leadingAnchor, constant: -8),

            bottoneGuida.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            bottoneGuida.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -14),
        ])
    }

    @objc private func mostraGuida() {
        let alert = UIAlertController(
            title: "Come funziona",
            message: "1. Inquadra il serramento e tocca il centro: l'immagine si ferma (FREEZE).\n2. Trascina i 4 vertici sugli angoli reali.\n3. Controlla le quote nel pannello e conferma la misura.\n\n🟢 Alta   🟡 Media   🟠 Bassa   🟣 Fallback raycast",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Ho capito", style: .default))
        present(alert, animated: true)
    }

    private func costruisciPillStato() {
        pillStato.backgroundColor = coloreCardScura
        pillStato.layer.cornerRadius = 16
        pillStato.layer.borderWidth = 1
        pillStato.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        pillStato.translatesAutoresizingMaskIntoConstraints = false

        puntinoStato.layer.cornerRadius = 4
        puntinoStato.translatesAutoresizingMaskIntoConstraints = false

        etichettaStato.font = .systemFont(ofSize: 12, weight: .bold)
        etichettaStato.textColor = .white

        let rigaPill = UIStackView(arrangedSubviews: [puntinoStato, etichettaStato])
        rigaPill.axis = .horizontal
        rigaPill.spacing = 6
        rigaPill.alignment = .center
        rigaPill.translatesAutoresizingMaskIntoConstraints = false

        pillStato.addSubview(rigaPill)
        view.addSubview(pillStato)

        etichettaIstruzionePill.font = .systemFont(ofSize: 11, weight: .medium)
        etichettaIstruzionePill.textColor = UIColor.white.withAlphaComponent(0.75)
        etichettaIstruzionePill.textAlignment = .center
        etichettaIstruzionePill.numberOfLines = 2
        etichettaIstruzionePill.translatesAutoresizingMaskIntoConstraints = false
        etichettaIstruzionePill.text = "Tocca il centro del serramento per iniziare"
        view.addSubview(etichettaIstruzionePill)

        NSLayoutConstraint.activate([
            pillStato.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 10),
            pillStato.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pillStato.heightAnchor.constraint(equalToConstant: 32),

            rigaPill.leadingAnchor.constraint(equalTo: pillStato.leadingAnchor, constant: 12),
            rigaPill.trailingAnchor.constraint(equalTo: pillStato.trailingAnchor, constant: -12),
            rigaPill.centerYAnchor.constraint(equalTo: pillStato.centerYAnchor),

            puntinoStato.widthAnchor.constraint(equalToConstant: 8),
            puntinoStato.heightAnchor.constraint(equalToConstant: 8),

            etichettaIstruzionePill.topAnchor.constraint(equalTo: pillStato.bottomAnchor, constant: 6),
            etichettaIstruzionePill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            etichettaIstruzionePill.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            etichettaIstruzionePill.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
        ])

        aggiornaPillStato()
    }

    /// Aggiorna la pillola LIVE/FREEZE in base a `frameCongelato`: nessuna
    /// nuova logica di stato, legge semplicemente lo stesso flag già usato dal
    /// resto del modulo per decidere se il fotogramma è congelato o live.
    private func aggiornaPillStato() {
        if frameCongelato != nil {
            etichettaStato.text = "FREEZE"
            puntinoStato.backgroundColor = coloreBluAccento
        } else {
            etichettaStato.text = "LIVE"
            puntinoStato.backgroundColor = .systemGreen
        }
    }

    private func styleIconButton(_ bottone: UIButton) {
        bottone.tintColor = .white
        bottone.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        bottone.layer.cornerRadius = 20
        bottone.translatesAutoresizingMaskIntoConstraints = false
        bottone.widthAnchor.constraint(equalToConstant: 40).isActive = true
        bottone.heightAnchor.constraint(equalToConstant: 40).isActive = true
    }

    private func wrapConDidascalia(_ bottone: UIButton, testo: String) -> UIStackView {
        let didascalia = UILabel()
        didascalia.text = testo
        didascalia.font = .systemFont(ofSize: 10, weight: .semibold)
        didascalia.textColor = UIColor.white.withAlphaComponent(0.85)
        didascalia.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [bottone, didascalia])
        stack.axis = .vertical
        stack.spacing = 4
        stack.alignment = .center
        return stack
    }

    private func costruisciToolbarDestra() {
        styleIconButton(bottoneToolGriglia)
        bottoneToolGriglia.setImage(UIImage(systemName: "grid"), for: .normal)
        bottoneToolGriglia.addTarget(self, action: #selector(toggleGriglia), for: .touchUpInside)

        styleIconButton(bottoneToolCentro)
        bottoneToolCentro.setImage(UIImage(systemName: "scope"), for: .normal)
        bottoneToolCentro.addTarget(self, action: #selector(evidenziaCentro), for: .touchUpInside)

        toolbarDestra.axis = .vertical
        toolbarDestra.spacing = 16
        toolbarDestra.alignment = .center
        toolbarDestra.translatesAutoresizingMaskIntoConstraints = false
        toolbarDestra.addArrangedSubview(wrapConDidascalia(bottoneToolGriglia, testo: "Griglia"))
        toolbarDestra.addArrangedSubview(wrapConDidascalia(bottoneToolCentro, testo: "Centro"))
        view.addSubview(toolbarDestra)

        NSLayoutConstraint.activate([
            toolbarDestra.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            toolbarDestra.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        // Nascosta finché non ci sono vertici da correggere: prima del primo
        // tocco la schermata deve restare il più libera possibile per mirare
        // al centro del serramento.
        toolbarDestra.alpha = 0
    }

    /// Griglia dei terzi puramente decorativa (aiuto all'inquadratura): un
    /// CAShapeLayer statico sopra la camera, nessun impatto su misure/depth.
    @objc private func toggleGriglia() {
        grigliaAttiva.toggle()
        bottoneToolGriglia.backgroundColor = grigliaAttiva ? coloreBrand : UIColor.white.withAlphaComponent(0.12)
        if grigliaAttiva {
            disegnaGriglia()
        } else {
            livelloGriglia?.removeFromSuperlayer()
            livelloGriglia = nil
        }
    }

    private func disegnaGriglia() {
        livelloGriglia?.removeFromSuperlayer()
        let layer = CAShapeLayer()
        let path = UIBezierPath()
        let w = sceneView.bounds.width, h = sceneView.bounds.height
        for i in 1...2 {
            let x = w * CGFloat(i) / 3
            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h))
            let y = h * CGFloat(i) / 3
            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y))
        }
        layer.path = path.cgPath
        layer.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
        layer.lineWidth = 1
        layer.fillColor = UIColor.clear.cgColor
        sceneView.layer.addSublayer(layer)
        livelloGriglia = layer
    }

    /// "Centro": evidenzia con un piccolo impulso visivo i vertici già
    /// posizionati (nessuna nuova misura, solo un'animazione SceneKit).
    @objc private func evidenziaCentro() {
        guard !punti.isEmpty else {
            mostraMessaggio("Posiziona prima i 4 vertici.")
            return
        }
        for p in punti {
            let impulso = SCNAction.sequence([.scale(to: 1.6, duration: 0.15), .scale(to: 1.0, duration: 0.15)])
            p.nodo.runAction(impulso)
        }
    }

    private func costruisciPopupTransitorio() {
        vetroPopup.layer.cornerRadius = 14
        vetroPopup.layer.masksToBounds = true
        vetroPopup.layer.borderWidth = 1
        vetroPopup.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        vetroPopup.translatesAutoresizingMaskIntoConstraints = false
        vetroPopup.alpha = 0
        vetroPopup.isUserInteractionEnabled = false

        let accentoPopup = UIView()
        accentoPopup.backgroundColor = coloreBrand.withAlphaComponent(0.85)
        accentoPopup.translatesAutoresizingMaskIntoConstraints = false

        etichettaPopup.textColor = .white
        etichettaPopup.numberOfLines = 6
        etichettaPopup.font = .systemFont(ofSize: 13, weight: .semibold)
        etichettaPopup.textAlignment = .center
        etichettaPopup.translatesAutoresizingMaskIntoConstraints = false

        vetroPopup.contentView.addSubview(accentoPopup)
        vetroPopup.contentView.addSubview(etichettaPopup)
        view.addSubview(vetroPopup)

        NSLayoutConstraint.activate([
            vetroPopup.topAnchor.constraint(equalTo: pillStato.bottomAnchor, constant: 36),
            vetroPopup.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            vetroPopup.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            vetroPopup.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            accentoPopup.topAnchor.constraint(equalTo: vetroPopup.contentView.topAnchor),
            accentoPopup.leadingAnchor.constraint(equalTo: vetroPopup.contentView.leadingAnchor),
            accentoPopup.trailingAnchor.constraint(equalTo: vetroPopup.contentView.trailingAnchor),
            accentoPopup.heightAnchor.constraint(equalToConstant: 3),

            etichettaPopup.topAnchor.constraint(equalTo: accentoPopup.bottomAnchor, constant: 10),
            etichettaPopup.leadingAnchor.constraint(equalTo: vetroPopup.contentView.leadingAnchor, constant: 14),
            etichettaPopup.trailingAnchor.constraint(equalTo: vetroPopup.contentView.trailingAnchor, constant: -14),
            etichettaPopup.bottomAnchor.constraint(equalTo: vetroPopup.contentView.bottomAnchor, constant: -10),
        ])
    }

    private func creaCardScura() -> UIView {
        // VistaPassante: lo sfondo della card non deve rubare il tocco a un
        // vertice che si trovasse visivamente sotto di essa — solo i
        // pulsanti/controlli reali al suo interno restano cliccabili.
        let v = VistaPassante()
        v.backgroundColor = coloreCardScura
        v.layer.cornerRadius = 16
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    private func creaBadgePill(titolo: String, valoreLabel: UILabel) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        container.layer.cornerRadius = 12
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let etichettaTitolo = UILabel()
        etichettaTitolo.text = titolo
        etichettaTitolo.font = .systemFont(ofSize: 10, weight: .semibold)
        etichettaTitolo.textColor = UIColor.white.withAlphaComponent(0.65)

        valoreLabel.font = .systemFont(ofSize: 13, weight: .bold)
        valoreLabel.textColor = .white
        valoreLabel.text = "—"

        let stack = UIStackView(arrangedSubviews: [etichettaTitolo, valoreLabel])
        stack.axis = .vertical
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
        ])
        return container
    }

    private func costruisciRigaBadge() -> UIView {
        let containerProf = creaBadgePill(titolo: "PROFONDITÀ", valoreLabel: badgeProfonditaLabel)
        let containerAtt = creaBadgePill(titolo: "ATTENDIBILITÀ", valoreLabel: badgeAttendibilitaLabel)
        let riga = UIStackView(arrangedSubviews: [containerProf, containerAtt])
        riga.axis = .horizontal
        riga.spacing = 10
        riga.distribution = .fillEqually
        riga.translatesAutoresizingMaskIntoConstraints = false
        return riga
    }

    private func creaMetricTile(titolo: String, valoreLabel: UILabel) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        valoreLabel.font = .systemFont(ofSize: 18, weight: .bold)
        valoreLabel.textColor = .white
        valoreLabel.textAlignment = .center
        valoreLabel.adjustsFontSizeToFitWidth = true
        valoreLabel.minimumScaleFactor = 0.6
        valoreLabel.text = "—"

        let etichetta = UILabel()
        etichetta.text = titolo
        etichetta.font = .systemFont(ofSize: 10, weight: .semibold)
        etichetta.textColor = UIColor.white.withAlphaComponent(0.6)
        etichetta.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [valoreLabel, etichetta])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    private func costruisciPannelloQuote() -> UIView {
        let card = creaCardScura()
        let tileL = creaMetricTile(titolo: "LARGHEZZA", valoreLabel: tileLarghezzaValore)
        let tileH = creaMetricTile(titolo: "ALTEZZA", valoreLabel: tileAltezzaValore)
        let tileS = creaMetricTile(titolo: "SUPERFICIE", valoreLabel: tileSuperficieValore)
        let tileA = creaMetricTile(titolo: "ATTENDIBILITÀ", valoreLabel: tileAttendibilitaValore)
        let riga = UIStackView(arrangedSubviews: [tileL, tileH, tileS, tileA])
        riga.axis = .horizontal
        riga.distribution = .fillEqually
        riga.spacing = 6
        riga.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(riga)
        NSLayoutConstraint.activate([
            riga.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            riga.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            riga.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            riga.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
        ])
        return card
    }

    private func costruisciBarraAzioni() -> UIView {
        bottoneAnnulla.setTitle("🗑 Cancella", for: .normal)
        bottoneAnnulla.setTitleColor(.white, for: .normal)
        bottoneAnnulla.backgroundColor = coloreRossoQID.withAlphaComponent(0.85)
        bottoneAnnulla.layer.cornerRadius = 10
        bottoneAnnulla.addTarget(self, action: #selector(annulla), for: .touchUpInside)

        bottoneRipristina.setTitle("🔄 Reset punti", for: .normal)
        bottoneRipristina.setTitleColor(.white, for: .normal)
        bottoneRipristina.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        bottoneRipristina.layer.cornerRadius = 10
        bottoneRipristina.layer.borderWidth = 1
        bottoneRipristina.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        bottoneRipristina.addTarget(self, action: #selector(ripristinaPunti), for: .touchUpInside)

        bottoneConferma.setTitle("✓ Conferma misura", for: .normal)
        bottoneConferma.setTitleColor(.white, for: .normal)
        bottoneConferma.layer.cornerRadius = 12
        bottoneConferma.isEnabled = false
        bottoneConferma.alpha = 0.4
        bottoneConferma.addTarget(self, action: #selector(conferma), for: .touchUpInside)
        applicaGradienteBrand(a: bottoneConferma)

        for bottone in [bottoneAnnulla, bottoneRipristina, bottoneConferma] {
            bottone.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            bottone.titleLabel?.adjustsFontSizeToFitWidth = true
            bottone.titleLabel?.minimumScaleFactor = 0.7
        }
        bottoneAnnulla.translatesAutoresizingMaskIntoConstraints = false
        bottoneRipristina.translatesAutoresizingMaskIntoConstraints = false
        bottoneConferma.translatesAutoresizingMaskIntoConstraints = false
        bottoneAnnulla.heightAnchor.constraint(equalToConstant: 46).isActive = true
        bottoneRipristina.heightAnchor.constraint(equalToConstant: 46).isActive = true
        bottoneConferma.heightAnchor.constraint(equalToConstant: 54).isActive = true

        let rigaSecondarie = UIStackView(arrangedSubviews: [bottoneAnnulla, bottoneRipristina])
        rigaSecondarie.axis = .horizontal
        rigaSecondarie.spacing = 8
        rigaSecondarie.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [rigaSecondarie, bottoneConferma])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func costruisciStepper() -> UIView {
        let titoli = ["1 Inquadra", "2 Ferma", "3 Posiziona", "4 Conferma"]
        var voci: [UIView] = []
        for titolo in titoli {
            let punto = UIView()
            punto.layer.cornerRadius = 4
            punto.backgroundColor = UIColor.white.withAlphaComponent(0.25)
            punto.translatesAutoresizingMaskIntoConstraints = false
            punto.widthAnchor.constraint(equalToConstant: 8).isActive = true
            punto.heightAnchor.constraint(equalToConstant: 8).isActive = true

            let etichetta = UILabel()
            etichetta.text = titolo
            etichetta.font = .systemFont(ofSize: 9, weight: .semibold)
            etichetta.textColor = UIColor.white.withAlphaComponent(0.5)
            etichetta.textAlignment = .center

            let colonna = UIStackView(arrangedSubviews: [punto, etichetta])
            colonna.axis = .vertical
            colonna.spacing = 3
            colonna.alignment = .center

            puntiniStepper.append(punto)
            etichetteStepper.append(etichetta)
            voci.append(colonna)
        }
        let riga = UIStackView(arrangedSubviews: voci)
        riga.axis = .horizontal
        riga.distribution = .fillEqually
        riga.translatesAutoresizingMaskIntoConstraints = false
        aggiornaStepper()
        return riga
    }

    /// Evidenzia lo step corrente leggendo solo stato già esistente
    /// (frameCongelato, numero di punti): nessuna nuova macchina a stati.
    private func aggiornaStepper() {
        guard puntiniStepper.count == 4, etichetteStepper.count == 4 else { return }
        let stato: [Bool] = [true, frameCongelato != nil, punti.count == 4, false]
        for (i, attivo) in stato.enumerated() {
            puntiniStepper[i].backgroundColor = attivo ? coloreBrand : UIColor.white.withAlphaComponent(0.25)
            etichetteStepper[i].textColor = attivo ? .white : UIColor.white.withAlphaComponent(0.5)
        }
    }

    // Nota: la riga badge (Profondità/Attendibilità) e lo stepper del mockup
    // sono stati tolti dal pannello reale — l'Attendibilità è già nella tile
    // del pannello quote, e ogni card in più riduceva lo spazio libero per
    // mirare/trascinare i vertici sull'inquadratura reale ("la schermata è
    // troppo piena, non riesco a puntare"). Le funzioni restano definite ma
    // non vengono più aggiunte allo stack visibile.
    private func costruisciPannelloInferiore() {
        let pannelloQuote = costruisciPannelloQuote()
        let barraAzioni = costruisciBarraAzioni()

        stackInferiore.axis = .vertical
        stackInferiore.spacing = 10
        stackInferiore.translatesAutoresizingMaskIntoConstraints = false
        stackInferiore.addArrangedSubview(pannelloQuote)
        stackInferiore.addArrangedSubview(barraAzioni)
        view.addSubview(stackInferiore)

        NSLayoutConstraint.activate([
            stackInferiore.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stackInferiore.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stackInferiore.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
        ])
        // Nascosto finché non esiste un rettangolo da correggere: prima del
        // primo tocco la schermata resta libera per mirare al centro.
        stackInferiore.alpha = 0
    }

    /// Applica al pulsante primario un gradiente verde brand (chiaro→scuro),
    /// come il `.btn-primary` del sito, invece di un verde piatto. Il layer
    /// viene tenuto sincronizzato con le dimensioni reali del pulsante in
    /// `viewDidLayoutSubviews()` (qui, a configurazione, il pulsante non ha
    /// ancora una dimensione definitiva).
    private func applicaGradienteBrand(a bottone: UIButton) {
        let gradiente = CAGradientLayer()
        gradiente.colors = [coloreBrand.cgColor, coloreBrandScuro.cgColor]
        gradiente.startPoint = CGPoint(x: 0, y: 0)
        gradiente.endPoint = CGPoint(x: 1, y: 1)
        gradiente.cornerRadius = bottone.layer.cornerRadius
        gradiente.name = "gradienteBrand"
        bottone.layer.insertSublayer(gradiente, at: 0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let gradiente = bottoneConferma.layer.sublayers?.first(where: { $0.name == "gradienteBrand" }) {
            gradiente.frame = bottoneConferma.bounds
        }
        if grigliaAttiva {
            disegnaGriglia()
        }
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
        // Cattura e converte SUBITO l'immagine a colori (vedi commento sulla
        // proprietà immagineCongelata): è l'unico momento in cui è certo che
        // il CVPixelBuffer di frame.capturedImage sia ancora valido.
        immagineCongelata = creaImmagineDrittaDaFrame(frame)
        sceneView.session.pause()
        aggiornaPillStato()
        creaRettangoloSimmetrico(centro: misurato, frame: frame)
    }

    /// Converte frame.capturedImage (CVPixelBuffer nell'orientamento nativo
    /// del sensore, landscape) in una UIImage "dritta" come la vede
    /// l'operatore in portrait — stessa convenzione già usata altrove in
    /// questo file per l'orientamento camera/schermo.
    private func creaImmagineDrittaDaFrame(_ frame: ARFrame) -> UIImage? {
        let immagineCI = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let contesto = CIContext()
        guard let cgImage = contesto.createCGImage(immagineCI, from: immagineCI.extent) else {
            print("⚠️ creaImmagineDrittaDaFrame: createCGImage ha restituito nil")
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Crea un rettangolo simmetrico (angoli retti, lati uguali a coppie)
    /// centrato sul punto toccato, orientato come il piano frontale alla
    /// camera in quel momento. È solo un punto di partenza: l'operatore lo
    /// allinea al vero serramento trascinando ciascun angolo.
    private func creaRettangoloSimmetrico(centro: PuntoMisurato, frame: ARFrame) {
        // IMPORTANTE: si usa il pointOfView della SCNView (non
        // frame.camera.transform) per "destro"/"su". frame.camera.transform è
        // riferito al sensore della fotocamera nel suo orientamento nativo
        // (landscape), NON all'orientamento a schermo (portrait) con cui si
        // tiene davvero il telefono: usarlo direttamente faceva partire il
        // rettangolo ruotato di 90° rispetto allo schermo, così L e H
        // finivano scambiate una volta che l'operatore allineava i 4 angoli
        // alla vera finestra. Il pointOfView invece è già coerente con lo
        // schermo (è lo stesso transform usato per proiettare i punti nel
        // trascinamento), quindi "destro"/"su" corrispondono davvero a
        // destra/su visti sullo schermo.
        let trasformVista = (sceneView.pointOfView?.simdWorldTransform) ?? frame.camera.transform
        let asseDestro = simd_normalize(simd_float3(trasformVista.columns.0.x, trasformVista.columns.0.y, trasformVista.columns.0.z))
        let asseSu = simd_normalize(simd_float3(trasformVista.columns.1.x, trasformVista.columns.1.y, trasformVista.columns.1.z))
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
        punti = offsetAngoli.enumerated().map { (indice, coppia) in
            let (ox, oy) = coppia
            let posizioneMondo = centroPos + asseDestro * (ox * mezzaLarghezza) + asseSu * (oy * mezzaAltezza)
            var pm = PuntoMisurato(
                posizione: SCNVector3(posizioneMondo.x, posizioneMondo.y, posizioneMondo.z),
                profonditaM: centro.profonditaM,
                confidence: centro.confidence,
                metodo: centro.metodo,
                nodo: SCNNode()
            )
            pm.nodo = creaNodoPunto(per: pm, indice: indice)
            sceneView.scene.rootNode.addChildNode(pm.nodo)
            return pm
        }

        bottoneConferma.isEnabled = true
        bottoneConferma.alpha = 1
        etichettaIstruzionePill.text = "Trascina i 4 angoli per allinearli al serramento"
        aggiornaStepper()
        // Ora che il rettangolo esiste, i pannelli/toolbar tornano visibili
        // (erano nascosti per lasciare lo schermo libero durante la mira).
        UIView.animate(withDuration: 0.25) {
            self.stackInferiore.alpha = 1
            self.toolbarDestra.alpha = 1
        }
        // ridisegnaLineeECalcola() aggiorna subito il pannello quote: è già
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
                // Schermo libero durante il trascinamento vero e proprio: i
                // pannelli/toolbar tornano dopo il rilascio del dito (vedi
                // .ended/.cancelled più sotto).
                UIView.animate(withDuration: 0.12) {
                    self.stackInferiore.alpha = 0
                    self.toolbarDestra.alpha = 0
                    self.etichettaIstruzionePill.alpha = 0
                }
            }
        case .changed:
            guard let indice = indiceInTrascinamento, indice < punti.count else { return }
            // Si campiona più in alto rispetto al dito (come un pin di
            // Mappe): il dito copre il punto di tocco, ma il punto vero
            // resta visibile più su, spostato della stessa quantità.
            let posizioneCampionamento = CGPoint(x: posizione.x, y: posizione.y - scostamentoDito)
            guard let misurato = puntoDaSchermo(posizioneCampionamento) else { return }
            // Ogni vertice si trascina in modo indipendente (il parallelismo
            // guidato è stato rimosso su richiesta): nessun vincolo tra lato
            // alto e lato basso, l'operatore allinea i 4 angoli liberamente.
            aggiornaPunto(indice, con: misurato)
        case .ended, .cancelled:
            // Il punto "si riappoggia" (torna alla dimensione normale) quando
            // si solleva il dito.
            if let indice = indiceInTrascinamento, indice < punti.count {
                punti[indice].nodo.runAction(.scale(to: 1.0, duration: 0.15))
            }
            // Dito sollevato: i pannelli riappaiono (solo se il rettangolo
            // esiste ancora — a riposo restano comunque nascosti prima del
            // primo tocco).
            UIView.animate(withDuration: 0.2) {
                self.etichettaIstruzionePill.alpha = 1
                if !self.punti.isEmpty {
                    self.stackInferiore.alpha = 1
                    self.toolbarDestra.alpha = 1
                }
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
        aggiornaAspettoNodo(nodoEsistente, per: misurato, indice: indice)
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
            immagineCongelata = nil
            avviaSessioneAR()
        }
        tileLarghezzaValore.text = "—"
        tileAltezzaValore.text = "—"
        tileSuperficieValore.text = "—"
        tileAttendibilitaValore.text = "—"
        badgeProfonditaLabel.text = "—"
        badgeAttendibilitaLabel.text = "—"
        etichettaIstruzionePill.text = "Tocca il centro del serramento per iniziare"
        aggiornaPillStato()
        aggiornaStepper()
        UIView.animate(withDuration: 0.2) {
            self.stackInferiore.alpha = 0
            self.toolbarDestra.alpha = 0
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

    /// Sfera colorata secondo la qualità del punto (invariato) + etichetta 3D
    /// col NUMERO del vertice (1-4), non più con la lettera di qualità: nel
    /// nuovo pannello quote la qualità si legge già dal colore/dai badge, il
    /// numero aiuta a capire "quale angolo è questo" mentre si trascina.
    private func creaNodoPunto(per misurato: PuntoMisurato, indice: Int) -> SCNNode {
        let sfera = SCNSphere(radius: 0.026)
        sfera.firstMaterial?.diffuse.contents = coloreQualita(misurato)
        sfera.firstMaterial?.emission.contents = coloreQualita(misurato)
        let nodo = SCNNode(geometry: sfera)
        nodo.position = misurato.posizione
        nodo.renderingOrder = 20
        aggiungiEtichetta3D("\(indice + 1)", colore: coloreQualita(misurato), a: nodo)
        return nodo
    }

    private func aggiornaAspettoNodo(_ nodo: SCNNode, per misurato: PuntoMisurato, indice: Int) {
        (nodo.geometry as? SCNSphere)?.firstMaterial?.diffuse.contents = coloreQualita(misurato)
        (nodo.geometry as? SCNSphere)?.firstMaterial?.emission.contents = coloreQualita(misurato)
        aggiungiEtichetta3D("\(indice + 1)", colore: coloreQualita(misurato), a: nodo)
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

        aggiornaPannelliInformativi(larghezzaM: larghezzaM, altezzaM: altezzaM, superficieM2: superficieM2)

        nodoLinee = disegnaRettangolo(posizioni)
        if let linee = nodoLinee { sceneView.scene.rootNode.addChildNode(linee) }
    }

    /// Aggiorna SOLO la presentazione (tile quote, badge, stepper) con i
    /// valori già calcolati da `ridisegnaLineeECalcola`: non esegue alcun
    /// nuovo calcolo di misura, sostituisce semplicemente il vecchio popup di
    /// testo con i pannelli persistenti del mockup.
    private func aggiornaPannelliInformativi(larghezzaM: Float, altezzaM: Float, superficieM2: Float) {
        tileLarghezzaValore.text = String(format: "%.0f mm", larghezzaM * 1000)
        tileAltezzaValore.text = String(format: "%.0f mm", altezzaM * 1000)
        tileSuperficieValore.text = String(format: "%.2f m²", superficieM2)

        let attendibilita = attendibilitaComplessiva()
        tileAttendibilitaValore.text = attendibilita.capitalized
        badgeAttendibilitaLabel.text = attendibilita.capitalized

        let profonditaDisponibili = punti.compactMap { $0.profonditaM }
        if !profonditaDisponibili.isEmpty {
            let media = profonditaDisponibili.reduce(0, +) / Double(profonditaDisponibili.count)
            badgeProfonditaLabel.text = String(format: "%.2f m", media)
        } else {
            badgeProfonditaLabel.text = "—"
        }

        aggiornaStepper()
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
    /// una faccia semitrasparente che riempie l'area. Verde QID (invece del
    /// precedente giallo) per coerenza con la nuova UI — puro colore, zero
    /// effetto sui calcoli.
    private func disegnaRettangolo(_ vertici: [SCNVector3]) -> SCNNode {
        let contenitore = SCNNode()
        for i in 0..<vertici.count {
            let a = vertici[i]
            let b = vertici[(i + 1) % vertici.count]
            contenitore.addChildNode(cilindroTra(a, b, raggio: 0.007, colore: coloreContornoAR))
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
        materiale.diffuse.contents = coloreContornoAR.withAlphaComponent(0.24)
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
            self.vetroPopup.alpha = 1
        }
        guard secondi > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + secondi) { [weak self] in
            guard let self = self, self.generazioneMessaggio == generazioneCorrente else { return }
            UIView.animate(withDuration: 0.3) {
                self.vetroPopup.alpha = 0
            }
        }
    }

    // MARK: - Azioni

    @objc private func annulla() {
        alCompletamento?(nil)
    }

    // MARK: - Foto della misurazione con le quote scritte sopra

    /// Disegna sopra l'immagine CONGELATA (catturata subito al fermo
    /// immagine, vedi `immagineCongelata`) il rettangolo dei 4 vertici + le
    /// quote, per ottenere una foto "prova" della misurazione da allegare al
    /// serramento. Larghezza/altezza/superficie sono passate già calcolate da
    /// `conferma()` (stessa formula, nessun ricalcolo): questa funzione tocca
    /// solo la resa grafica.
    private func creaFotoConMisure(larghezzaM: Float, altezzaM: Float, superficieM2: Float) -> Data? {
        guard let frame = frameCongelato, let immagineBase = immagineCongelata, punti.count == 4 else {
            print("⚠️ creaFotoConMisure: frameCongelato==nil: \(frameCongelato == nil), immagineCongelata==nil: \(immagineCongelata == nil), punti: \(punti.count)")
            return nil
        }

        // Riduce la risoluzione (lato massimo 1600px) prima di disegnare e
        // codificare: la risoluzione nativa della capturedImage può essere
        // grande, e una stringa base64 troppo pesante rischia di rallentare
        // o inceppare il trasferimento nativo->JS attraverso il bridge
        // Capacitor. I 4 vertici restano comunque proiettati correttamente a
        // QUALSIASI dimensione: projectPoint(viewportSize:) è pensato apposta
        // per essere indipendente dalla risoluzione scelta.
        let latoMassimo: CGFloat = 1600
        let fattoreScala = min(1, latoMassimo / max(immagineBase.size.width, immagineBase.size.height))
        let viewportSize = CGSize(
            width: (immagineBase.size.width * fattoreScala).rounded(),
            height: (immagineBase.size.height * fattoreScala).rounded()
        )
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            print("⚠️ creaFotoConMisure: viewportSize non valido")
            return nil
        }

        // scale = 1 esplicito: senza questo UIGraphicsImageRenderer userebbe
        // lo scale factor dello schermo (2x/3x), disallineando le coordinate
        // disegnate qui sotto (calcolate in "pixel immagine", non in punti).
        let formato = UIGraphicsImageRendererFormat()
        formato.scale = 1
        let renderer = UIGraphicsImageRenderer(size: viewportSize, format: formato)

        // Riproietta i 4 vertici (stesso frame, stessa camera) nello spazio
        // pixel di QUESTA immagine (già alla risoluzione ridotta):
        // ARCamera.projectPoint è l'API pensata apposta per riportare un
        // punto 3D su una foto già scattata, dato l'orientamento e la
        // dimensione della foto stessa — qualunque essa sia.
        let puntiSchermo: [CGPoint] = punti.map { p in
            frame.camera.projectPoint(
                simd_float3(p.nodo.position.x, p.nodo.position.y, p.nodo.position.z),
                orientation: .portrait,
                viewportSize: viewportSize
            )
        }

        // Disegna una "linea quota" in stile tecnico/righello: linea con
        // tacche perpendicolari alle estremità + etichetta su una pillola
        // scura al centro (leggibile su qualunque sfondo della foto).
        func disegnaLineaQuota(_ cg: CGContext, da a: CGPoint, a b: CGPoint, etichetta: String) {
            cg.saveGState()
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(3)
            cg.move(to: a)
            cg.addLine(to: b)
            let dx = b.x - a.x, dy = b.y - a.y
            let lunghezza = max(sqrt(dx * dx + dy * dy), 0.001)
            let perpX = -dy / lunghezza * 10
            let perpY = dx / lunghezza * 10
            for punto in [a, b] {
                cg.move(to: CGPoint(x: punto.x - perpX, y: punto.y - perpY))
                cg.addLine(to: CGPoint(x: punto.x + perpX, y: punto.y + perpY))
            }
            cg.strokePath()
            cg.restoreGState()

            let centro = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let font = UIFont.boldSystemFont(ofSize: 26)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            let dimensione = (etichetta as NSString).size(withAttributes: attrs)
            let paddingX: CGFloat = 10, paddingY: CGFloat = 6
            let pillRect = CGRect(
                x: centro.x - dimensione.width / 2 - paddingX,
                y: centro.y - dimensione.height / 2 - paddingY,
                width: dimensione.width + paddingX * 2,
                height: dimensione.height + paddingY * 2
            )
            UIColor.black.withAlphaComponent(0.72).setFill()
            UIBezierPath(roundedRect: pillRect, cornerRadius: pillRect.height / 2).fill()
            (etichetta as NSString).draw(
                at: CGPoint(x: centro.x - dimensione.width / 2, y: centro.y - dimensione.height / 2),
                withAttributes: attrs
            )
        }

        // Righello orizzontale (larghezza) offset sopra il lato alto (0=alto-sx,
        // 1=alto-dx); righello verticale (altezza) offset a sinistra del lato
        // sinistro (0=alto-sx, 3=basso-sx). Clampati a un margine minimo dal
        // bordo dell'immagine, nel raro caso il serramento riempia il fotogramma.
        let offsetRighello: CGFloat = 44
        let yRighelloOrizzontale = max(min(puntiSchermo[0].y, puntiSchermo[1].y) - offsetRighello, 30)
        let righelloOrizzontaleA = CGPoint(x: puntiSchermo[0].x, y: yRighelloOrizzontale)
        let righelloOrizzontaleB = CGPoint(x: puntiSchermo[1].x, y: yRighelloOrizzontale)
        let xRighelloVerticale = max(min(puntiSchermo[0].x, puntiSchermo[3].x) - offsetRighello, 30)
        let righelloVerticaleA = CGPoint(x: xRighelloVerticale, y: puntiSchermo[0].y)
        let righelloVerticaleB = CGPoint(x: xRighelloVerticale, y: puntiSchermo[3].y)

        let immagineFinale = renderer.image { ctx in
            // draw(in:) invece di draw(at:): ridimensiona l'immagine sorgente
            // (a piena risoluzione) dentro il canvas più piccolo.
            immagineBase.draw(in: CGRect(origin: .zero, size: viewportSize))
            let cg = ctx.cgContext

            cg.setLineWidth(4)
            cg.setStrokeColor(coloreContornoAR.cgColor)
            cg.setFillColor(coloreContornoAR.withAlphaComponent(0.22).cgColor)
            let percorso = CGMutablePath()
            percorso.addLines(between: puntiSchermo)
            percorso.closeSubpath()
            cg.addPath(percorso)
            cg.drawPath(using: .fillStroke)

            for (i, punto) in puntiSchermo.enumerated() {
                cg.setFillColor(coloreContornoAR.cgColor)
                let raggio: CGFloat = 15
                cg.fillEllipse(in: CGRect(x: punto.x - raggio, y: punto.y - raggio, width: raggio * 2, height: raggio * 2))
                let numero = "\(i + 1)" as NSString
                numero.draw(
                    at: CGPoint(x: punto.x - 6, y: punto.y - 11),
                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.white]
                )
            }

            // Linee sottili di richiamo dai vertici reali al righello (come nei
            // disegni tecnici), poi il righello vero e proprio con tacche+etichetta.
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.55).cgColor)
            cg.setLineWidth(1.5)
            cg.move(to: puntiSchermo[0]); cg.addLine(to: righelloOrizzontaleA)
            cg.move(to: puntiSchermo[1]); cg.addLine(to: righelloOrizzontaleB)
            cg.move(to: puntiSchermo[0]); cg.addLine(to: righelloVerticaleA)
            cg.move(to: puntiSchermo[3]); cg.addLine(to: righelloVerticaleB)
            cg.strokePath()

            disegnaLineaQuota(cg, da: righelloOrizzontaleA, a: righelloOrizzontaleB, etichetta: String(format: "%.0f mm", larghezzaM * 1000))
            disegnaLineaQuota(cg, da: righelloVerticaleA, a: righelloVerticaleB, etichetta: String(format: "%.0f mm", altezzaM * 1000))

            // Banda scura in basso, molto più grande e leggibile: riga
            // principale con L/H/superficie in grande, riga secondaria più
            // piccola con attendibilità e dispositivo.
            let bandaAltezza: CGFloat = 120
            let bandaRect = CGRect(x: 0, y: viewportSize.height - bandaAltezza, width: viewportSize.width, height: bandaAltezza)
            cg.setFillColor(UIColor.black.withAlphaComponent(0.7).cgColor)
            cg.fill(bandaRect)

            let paragrafo = NSMutableParagraphStyle()
            paragrafo.alignment = .center

            let testoPrincipale = String(format: "L = %.0f mm   H = %.0f mm   S = %.2f m²", larghezzaM * 1000, altezzaM * 1000, superficieM2)
            (testoPrincipale as NSString).draw(
                in: CGRect(x: bandaRect.minX + 10, y: bandaRect.minY + 16, width: bandaRect.width - 20, height: 44),
                withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 30),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragrafo,
                ]
            )

            let testoSecondario = "\(attendibilitaComplessiva().capitalized) · \(identificatoreDispositivo())"
            (testoSecondario as NSString).draw(
                in: CGRect(x: bandaRect.minX + 10, y: bandaRect.minY + 68, width: bandaRect.width - 20, height: 30),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 16, weight: .medium),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.85),
                    .paragraphStyle: paragrafo,
                ]
            )
        }
        let dati = immagineFinale.jpegData(compressionQuality: 0.7)
        if let dati = dati {
            print("📷 creaFotoConMisure: JPEG generato, \(dati.count / 1024) KB, \(Int(viewportSize.width))×\(Int(viewportSize.height))")
        } else {
            print("⚠️ creaFotoConMisure: jpegData ha restituito nil")
        }
        return dati
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

        var risultato: [String: Any] = [
            "larghezza": (larghezzaCm * 10).rounded() / 10,     // cm, un decimale
            "altezza": (altezzaCm * 10).rounded() / 10,
            "superficie": (superficieM2 * 100).rounded() / 100,  // m²
            "metodoMisura": "ar_lidar_scene_depth",
            "dispositivo": identificatoreDispositivo(),
            "attendibilita": attendibilitaComplessiva(),
            "confermataOperatore": true,
            "punti": puntiJson,
        ]

        // Foto della misurazione con le quote scritte sopra: comoda
        // documentazione visiva da allegare al serramento, in aggiunta ai
        // valori numerici già calcolati sopra (non ricalcolati, solo passati
        // come testo). Se la generazione fallisce per qualunque motivo si
        // procede comunque con la sola misura numerica: non blocca la conferma.
        if let datiFoto = creaFotoConMisure(larghezzaM: larghezzaM, altezzaM: altezzaM, superficieM2: Float(superficieM2)) {
            risultato["fotoConMisureBase64"] = datiFoto.base64EncodedString()
        }

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
