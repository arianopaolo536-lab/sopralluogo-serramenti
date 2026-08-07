# Fase 1 — Analisi architettura esistente e fattibilità evoluzione AR/AI

Data: 2026-08-07

## 0. Stato reale del codice attuale

Verificato direttamente nel repository:

- **Stack**: Node.js + Express, frontend in HTML/CSS/JS vanilla (nessun framework, nessun bundler).
- **Database**: file JSON piatto (`data/db.json`), nessun SQL/NoSQL vero.
- **Foto**: upload via Multer, salvate su disco (`/uploads` o disco persistente Render).
- **Dettatura vocale**: Web Speech API (`SpeechRecognition`), funzionante, lato browser.
- **Fotocamera**: `getUserMedia`, funzionante, lato browser.
- **Distribuzione**: sito web pubblicato su Render (URL browser), **non è un'app nativa, non è nemmeno una PWA installabile** — non esiste `manifest.json` né service worker nel progetto.
- **Accesso**: l'utente apre l'app da Safari (iPhone) o Chrome (Android/desktop) tramite URL.

Questo ultimo punto è la premessa più importante per tutta l'analisi che segue: oggi l'app **gira interamente nel browser mobile**, non come app installata da App Store/Play Store.

## 1. Cosa è realmente fattibile / non fattibile

**Fattibile subito, dentro il browser attuale, gratis:**
Foto, dettatura vocale (già fatto), gate iniziale A/B/C, schema dati esteso (commessa, edificio, ambiente, tracciabilità misure, indicatore di attendibilità), riconoscimento oggetti/tipologia via modelli ML che girano nel browser (TensorFlow.js / MediaPipe), rilevamento contorni assistito (OpenCV.js) per aiutare l'operatore a posizionare i 4 vertici del serramento su una foto, misura "a riferimento" (oggetto di dimensione nota o distanza inserita) con calcolo di L/H/superficie su canvas.

**Non fattibile da browser puro, su nessuna piattaforma:**
Accesso a LiDAR/Scene Depth di iPhone. Apple non espone queste API a Safari o a nessun altro browser: ARKit/RealityKit/Core ML "hardware-level" sono disponibili **solo dentro un'app nativa Swift o un contenitore ibrido nativo** (es. Capacitor/React Native con plugin nativo custom), installata da App Store o TestFlight. Non esiste scorciatoia web per questo.

**Parzialmente fattibile solo su Android via browser:**
Chrome su Android supporta WebXR Device API con hit-test (rilevamento piani tramite ARCore) e, su alcuni dispositivi, moduli sperimentali di depth via web — ma è incompleto, non uniforme tra i device, e non paragonabile a un vero accesso nativo ARCore/Depth API.

## 2. Cosa può funzionare su iPhone con LiDAR

Solo tramite app nativa o wrapper ibrido nativo pubblicato (non da Safari): ARKit + Scene Depth per plane detection ad alta precisione, misura assistita con errore tipico 5–15 mm in condizioni buone. Richiede sviluppo Swift (o plugin nativo Capacitor), Apple Developer Program (99$/anno) e review App Store/TestFlight.

## 3. Cosa può funzionare su iPhone senza LiDAR

Anche senza LiDAR, ARKit standard (plane detection via camera + gyroscope) resta accessibile solo da app nativa/ibrida, con precisione inferiore (tipicamente 15–30 mm). Da browser puro (Safari), l'unica misura possibile è quella "a riferimento" descritta sopra, con margine di errore maggiore (20–50 mm+, molto dipendente da angolazione e distanza) — da segnalare sempre come indicativa.

## 4. Cosa può funzionare su Android

Dipende fortemente dal device (frammentazione hardware, non tutti supportano ARCore Depth API). Con app nativa/ibrida su device compatibili: precisione paragonabile a iPhone senza LiDAR (10–30 mm). Da browser puro: stessa misura "a riferimento" di iOS, con l'aggiunta di un possibile hit-test WebXR su Chrome dove disponibile, ma non affidabile come base per misure di produzione.

## 5. Precisione realisticamente ottenibile (riassunto)

| Metodo | Piattaforma | Contenitore richiesto | Errore tipico |
|---|---|---|---|
| LiDAR/ARKit | iPhone Pro | App nativa/ibrida | 5–15 mm |
| ARKit senza LiDAR | iPhone standard | App nativa/ibrida | 15–30 mm |
| ARCore + Depth | Android compatibile | App nativa/ibrida | 10–30 mm |
| Misura a riferimento | iOS/Android | Browser (attuale sito) | 20–50 mm+ |

In tutti i casi, per il rilievo esecutivo (produzione), nessuna misura automatica deve mai sostituire la conferma manuale — coerente con quanto richiesto nel documento.

## 6. Cosa può essere gratis / on-device

Dettatura vocale (già in uso), riconoscimento tipologia/materiale/accessori tramite modelli leggeri TensorFlow.js o MediaPipe eseguiti nel browser (scaricati una volta, poi utilizzabili anche offline), rilevamento contorni con OpenCV.js, misura a riferimento. Nessuno di questi richiede servizi esterni a pagamento né invio di immagini a server terzi.

## 7. Cosa richiederebbe servizi esterni a pagamento

Riconoscimento AI più sofisticato (es. Claude Vision, GPT-4 Vision, Google Vision API) per classificazioni più accurate in scenari complessi: costo per richiesta, immagini inviate a server esterno (implicazioni privacy/GDPR da valutare se compaiono dati di clienti/cantieri in foto), ma possibilità di girare anche offline nulla — richiede sempre connessione. Non lo introdurrei nella prima fase: i modelli on-device coprono già la maggior parte dei casi utili per "proporre, non decidere".

## 8. Modifiche necessarie all'architettura esistente

Il **core attuale** (Express + JSON/DB + gestione commesse/clienti/serramenti/foto/note + report) può restare quasi identico: è già ben strutturato per essere il backend comune multipiattaforma richiesto nel punto 20 del documento.

Per l'evoluzione servono due aggiunte, senza toccare ciò che già funziona:

1. **Modulo "misura a riferimento" via web** — realizzabile subito nel sito esistente, stessa esperienza su iOS/Android, nessuna dipendenza nativa.
2. **Contenitore ibrido installabile** (es. Capacitor) che impacchetta l'attuale sito in un'app iOS/Android vera, con plugin nativi custom per ARKit (iOS) e ARCore (Android) che dialogano con il JS esistente tramite bridge. Questo permette di riusare praticamente tutto il codice attuale e aggiungere solo il modulo di misura nativo dove serve la precisione da produzione.

In parallelo, aggiungere manifest + service worker (PWA) darebbe da subito un'esperienza "app-like" offline-first per tutto il resto (form, foto, dettatura, note), indipendentemente dal LiDAR.

## 9. Rischi tecnici

Frammentazione hardware Android (Depth API non uniforme); limite strutturale Apple sul web (nessuna via di fuga per LiDAR da browser); tempi/costi di pubblicazione app nativa (review Apple, account sviluppatore); precisione ottica in generale non ancora al livello di un metro laser professionale, quindi il controllo umano resta necessario per la produzione; complessità di mantenere sincronizzati un core web e moduli nativi; progettazione offline-first (spazio locale per foto, gestione conflitti di sync) da fare con attenzione.

## 10. Proposta di fasi (confermo l'impostazione del documento, con un adattamento)

- **Fase 1 — Analisi**: questa relazione.
- **Fase 2 — Architettura**: disegno del flusso completo e separazione netta core web / moduli nativi, schema dati esteso (gate A/B/C, tracciabilità, attendibilità).
- **Fase 3 — Prototipo di misurazione**: propongo di partire dalla **misura a riferimento via web**, realizzabile subito nell'app esistente, a rischio/costo zero, per validare il flusso UX (inquadra → posiziona punti → L/H/superficie → foto quotata) prima di investire nello sviluppo nativo. Il modulo LiDAR/ARKit nativo diventa una Fase 3-bis successiva, una volta validata l'esperienza e presa la decisione di investire in un'app nativa/ibrida.
- **Fase 4 — AI riconoscimento** (tipologia, ante, accessori, materiale) on-device, gratuita.
- **Fase 5 — Integrazione** nella scheda serramento esistente.
- **Fase 6 — Rilievo esecutivo** con controlli e coerenza dati.
- **Fase 7 — Posa/collaudo**.

## 11. Primo prototipo minimo consigliato

Dato che oggi l'app è **al 100% web**, il prototipo a rischio zero e a costo zero è: **"Misura assistita a riferimento"** dentro la scheda serramento esistente. L'operatore fotografa il serramento (riusando la fotocamera già presente), il sistema mostra la foto su un canvas, l'operatore posiziona/aggiusta 4 punti sui vertici, si inserisce un riferimento di scala (es. un foglio A4 visibile nella foto, oppure la larghezza di un elemento noto), il sistema calcola L/H/superficie e genera la foto quotata con il badge "MISURA INDICATIVA — DA VERIFICARE PRIMA DELLA PRODUZIONE". Questo pone anche le basi dati (metodo di misurazione, attendibilità, dato automatico vs confermato) che serviranno identiche quando in futuro arriverà il modulo LiDAR nativo.

## 12. Nota sul gate iniziale e sullo schema dati

Il gate A/B/C (Preventivazione / Esecutivo / Posa-Collaudo) e lo schema dati esteso (tracciabilità, attendibilità, distinzione dato automatico/confermato) sono interamente realizzabili nell'app web esistente, senza alcuna dipendenza nativa, e possono partire in parallelo o subito prima del prototipo di misura.
