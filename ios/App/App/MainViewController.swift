import UIKit
import Capacitor

// Sottoclasse del bridge view controller di Capacitor, necessaria solo per
// registrare i plugin locali del progetto (non distribuiti via npm), come
// MisuraLidarPlugin. Il resto del comportamento resta quello standard di
// Capacitor: nessuna modifica alla webview né al caricamento di public/.
class MainViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(MisuraLidarPlugin())
    }
}
