# Guida: compilare e testare il prototipo "Misura con LiDAR" su iPhone

Questa guida è per il tuo Mac (Xcode) — io non posso compilare Swift né aprire
Xcode da qui, ho generato tutto il progetto e i file nativi, l'ultimo passo è
sul tuo computer.

## Cosa è già stato fatto (in questo repository)

- `capacitor.config.json` — configurazione Capacitor, `webDir: "public"` (l'app nativa carica lo stesso sito che gira su Render).
- `ios/` — progetto Xcode completo, generato con `npx cap add ios` (contiene `App.xcodeproj`, storyboard, `Info.plist`, ecc.). **Non toccare a mano i file generati da Capacitor**, salvo quelli elencati sotto che ho aggiunto/modificato io.
- `ios/App/App/MainViewController.swift` — registra il plugin locale nel bridge Capacitor.
- `ios/App/App/MisuraLidarPlugin.swift` — il plugin (`Capacitor.Plugins.MisuraLidar`), espone `disponibile()` e `misura()`.
- `ios/App/App/VistaMisuraLidar.swift` — la schermata nativa ARKit/LiDAR con il flusso richiesto: apertura fotocamera → sessione ARKit → 4 punti → correzione manuale (trascinamento) → calcolo L/H/superficie → conferma → ritorno alla webview.
- `ios/App/App/Info.plist` — aggiunte le descrizioni permessi necessarie (fotocamera, microfono, riconoscimento vocale).
- `ios/App/App/Base.lproj/Main.storyboard` — il view controller iniziale ora è `MainViewController` invece del default Capacitor.
- Lato web (`public/app.js`, `public/index.html`): un pulsante "📐 Misura con LiDAR" nella scheda serramento, **nascosto di default** e mostrato solo se l'app gira dentro il contenitore nativo su un dispositivo con LiDAR — sul sito Render/browser resta sempre nascosto, nessuna regressione.

## Prerequisiti sul Mac

- Xcode (ultima versione stabile) installato da App Store.
- Un Apple ID iscritto all'Apple Developer Program (99$/anno) per firmare l'app e installarla su un iPhone fisico — necessario perché il simulatore iOS **non supporta LiDAR** (serve un iPhone Pro/Pro Max reale, o iPad Pro con LiDAR).
- CocoaPods, se non già installato: `sudo gem install cocoapods`.

## Passi

1. Scarica/sincronizza questa cartella di progetto sul Mac (stessa cartella che usi per git).
2. Da terminale, nella cartella del progetto:
   ```
   npm install
   npx cap sync ios
   ```
   (`cap sync` copia l'ultima versione di `public/` dentro `ios/App/App/public` e installa i pod — rifallo ogni volta che modifichi HTML/CSS/JS e vuoi vederlo nell'app nativa).
3. Apri il progetto in Xcode:
   ```
   npx cap open ios
   ```
4. In Xcode: seleziona il target "App" → scheda "Signing & Capabilities" → seleziona il tuo team Apple Developer (Automatically manage signing).
5. Collega un iPhone con LiDAR (iPhone 12 Pro/Pro Max o successivi Pro/Pro Max, o iPad Pro 2020+) via cavo, selezionalo come destinazione, premi ▶ Run.
6. La prima volta, sull'iPhone: Impostazioni → Generali → VPN e gestione dispositivi → fidati del tuo certificato sviluppatore.
7. Alla prima apertura, l'app chiederà il permesso fotocamera (serve sia per le foto normali sia per il LiDAR) — concedilo.

## Come testare il modulo

1. Apri un sopralluogo, tab "Rilievo misure" → "Aggiungi serramento".
2. Se il dispositivo ha LiDAR, vedrai il pulsante "📐 Misura con LiDAR" sotto il campo foto (su iPhone senza LiDAR resta nascosto, come previsto).
3. Tocca il pulsante: si apre la schermata nativa a schermo intero, individua il piano, tocca i 4 angoli del serramento (l'ordine consigliato: alto-sx, alto-dx, basso-dx, basso-sx), correggi trascinando un punto se necessario, poi "Conferma misura".
4. I campi Larghezza/Altezza del form si compilano da soli con il valore misurato — **restano comunque modificabili a mano** prima di premere "Salva serramento" (nessuna misura diventa definitiva senza il tuo intervento, come richiesto).

## Costruire la statistica di accuratezza reale sul campo

Per questo primo prototipo non ho costruito una tabella dedicata ai log di test
(non era nello scope richiesto per questa fase). Il dato tecnico è comunque già
tracciato: ogni serramento salvato con LiDAR registra `metodo_misurazione`,
`dispositivo_misurazione`, `attendibilita` e, se poi correggi manualmente
larghezza/altezza, la correzione finisce automaticamente in `storico_misure`
con valore precedente/nuovo e timestamp.

Per i test sul campo, il modo più rapido con quello che c'è già: dopo aver
confermato la misura LiDAR, usa il campo **Note** del serramento (con la
dettatura vocale già funzionante) per dire ad esempio "Metro laser: 121,0 cm x
148,5 cm, distanza operatore circa 60 cm" — tutto resta nella stessa scheda,
consultabile e confrontabile con `larghezza_cm`/`altezza_cm` salvati dal
LiDAR. Se dopo i primi test sul campo vuoi una tabella/report dedicato che
calcola automaticamente lo scarto in mm, lo costruiamo nella fase successiva
sulla base dei dati reali raccolti così — evitiamo di disegnarla ora su ipotesi.

## Convivenza con la versione web

Il sito su Render continua a funzionare esattamente come prima da Safari/Chrome:
nessun file esistente per il web è stato riscritto, solo il pulsante LiDAR è
stato aggiunto (nascosto di default). Puoi continuare a usare il link Render
in parallelo ai test dell'app nativa.
