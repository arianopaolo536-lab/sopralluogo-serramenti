import Foundation
import Capacitor
import ARKit

// Plugin Capacitor locale (non pubblicato su npm) che espone al JavaScript
// esistente (public/app.js) la funzione di misurazione con LiDAR.
//
// Contratto verso il JS (esteso dopo la revisione "vero uso di Scene Depth":
// vedi VistaMisuraLidar.swift per come vengono determinati i 4 punti):
//   Capacitor.Plugins.MisuraLidar.misura() -> Promise<{
//     larghezza, altezza, superficie,             // cm/cm/m², coerenti con il resto dell'app
//     metodoMisura: "ar_lidar_scene_depth",
//     dispositivo,                                 // es. "iPhone15,2 · iOS 18.0"
//     attendibilita: "alta" | "media" | "bassa",    // qualitativa, derivata dalla confidenceMap reale
//     confermataOperatore: true,
//     punti: [{ profondita_m, confidence, metodo }] // dettaglio per ciascuno dei 4 punti
//   }>
//
// Nessuna di queste API tocca il backend Express/Render: il risultato viene
// salvato dal JS esistente con lo stesso PATCH /api/serramenti/:id già in uso.
@objc(MisuraLidarPlugin)
public class MisuraLidarPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "MisuraLidarPlugin"
    public let jsName = "MisuraLidar"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "disponibile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "misura", returnType: CAPPluginReturnPromise),
    ]

    private var callInCorso: CAPPluginCall?

    // Il JS lo chiama per decidere se mostrare o nascondere il pulsante
    // "Misura con LiDAR" nella scheda serramento (nessun LiDAR = pulsante nascosto).
    @objc func disponibile(_ call: CAPPluginCall) {
        call.resolve(["disponibile": VistaMisuraLidar.lidarDisponibile])
    }

    @objc func misura(_ call: CAPPluginCall) {
        guard VistaMisuraLidar.lidarDisponibile else {
            call.reject("Questo dispositivo non supporta Scene Depth (nessun sensore LiDAR utilizzabile).")
            return
        }
        callInCorso = call
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let vc = VistaMisuraLidar()
            vc.modalPresentationStyle = .fullScreen
            vc.alCompletamento = { [weak self] risultato in
                guard let self = self else { return }
                self.bridge?.viewController?.dismiss(animated: true) {
                    if let risultato = risultato {
                        self.callInCorso?.resolve(risultato)
                    } else {
                        self.callInCorso?.reject("Misurazione annullata dall'operatore.")
                    }
                    self.callInCorso = nil
                }
            }
            self.bridge?.viewController?.present(vc, animated: true)
        }
    }
}
