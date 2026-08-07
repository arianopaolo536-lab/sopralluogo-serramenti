# Fase 2 — Proposta architettura: PWA offline-first, Capacitor, modulo "Misura con LiDAR"

Data: 2026-08-07
Stato: **solo proposta, nessun codice nativo/PWA/Capacitor ancora scritto** — in attesa di approvazione.

## Aggiornamento sullo stato attuale (punti 1-2, già implementati)

Completati e testati (POST/PATCH via curl):

- Gate iniziale obbligatorio alla creazione del sopralluogo: `preventivazione` / `esecutivo` / `posa_collaudo`, validato lato server (400 se mancante), mostrato come badge colorato in elenco e nella testata del sopralluogo.
- Schema `serramento` esteso con: `metodo_misurazione` (default `"manuale"`), `attendibilita` (default `"alta"`), `dispositivo_misurazione`, `misura_confermata` (default `true` per l'inserimento manuale attuale), `storico_misure` (array di correzioni con valore precedente/nuovo, tipo, operatore, timestamp — popolato automaticamente quando larghezza/altezza cambiano).
- Record esistenti (creati prima di questa modifica) vengono normalizzati in lettura, nessuna migrazione manuale necessaria.
- Questi campi sono già sufficienti a ricevere, in futuro, l'oggetto restituito dal modulo LiDAR (vedi punto D più sotto) senza ulteriori modifiche allo schema.

## 3. PWA / offline-first — analisi e proposta

**Aggiunte previste (additive, nessun file esistente riscritto):**

- `public/manifest.json`: nome app, icone (dal logo QID), `display: standalone`, colori tema.
- `public/sw.js` (service worker): cache-first per gli asset statici (html/css/js/immagini), con un numero di versione da incrementare a ogni deploy per invalidare la cache vecchia; network-first con fallback su cache per le chiamate `GET /api/...`, così l'ultimo sopralluogo aperto resta consultabile anche offline.
- Per le scritture offline (nuove foto, nuovi serramenti, modifiche campi): coda locale in IndexedDB delle richieste non ancora inviate, che si riprova automaticamente al ritorno della connessione (evento `online` + retry, oppure Background Sync API dove supportata).
- Poche righe additive in `index.html`/`app.js` per registrare il service worker — nessuna modifica alla logica esistente di foto, dettatura, schede, stampa.

**Limiti reali da comunicare, non da nascondere:**

- La dettatura vocale su Chrome/Android si appoggia a un servizio cloud di Google: **non funzionerà offline**. Su Safari/iOS il comportamento può variare (in alcuni casi è on-device) — da verificare sul campo, non da promettere come garantito.
- Le foto scattate offline vanno tenute temporaneamente come Blob in IndexedDB prima dell'upload, poi sincronizzate quando torna la rete.
- Scenario di due dispositivi che modificano lo stesso sopralluogo offline in parallelo non è nell'ambito attuale (un operatore per sopralluogo): da tenere presente ma non bloccante ora.

## 4. Trasformazione ibrida con Capacitor — analisi

Capacitor incapsula il sito web esistente (la cartella `public/` con HTML/CSS/JS) dentro un contenitore nativo iOS/Android, senza richiedere di riscrivere l'interfaccia. In più, espone un bridge JS↔nativo che permette di aggiungere plugin custom (necessari per ARKit/LiDAR e in futuro ARCore).

Cosa cambia concretamente:

- Il backend Express e tutto il frontend attuale **restano quasi identici**.
- Si aggiungono, senza toccare l'esistente: `capacitor.config.json` e una cartella `ios/` (progetto Xcode generato da Capacitor) — per compilarla serve un Mac con Xcode e un account Apple Developer (99$/anno; necessario comunque per usare ARKit/LiDAR fuori da un browser).
- I plugin nativi (Swift per iOS) si dichiarano con un bridge che li rende chiamabili da `app.js` come `Capacitor.Plugins.NomePlugin.metodo()`, con Promise — quindi il frontend esistente si modifica solo per aggiungere la chiamata al nuovo plugin, non per essere riscritto.
- Il resto dell'app (commesse, foto, note, dettatura, stampa, riepilogo) resta HTML/CSS/JS invariato.

## 5. Architettura del modulo "Misura con LiDAR" (punti A–F richiesti)

**A. Architettura proposta.**
App nativa iOS via Capacitor che carica gli asset web esistenti. Un plugin nativo custom in Swift usa ARKit + Scene Depth (LiDAR) **solo** in una schermata dedicata a schermo intero, aperta come vista nativa (non dentro la webview: ARKit richiede un `ARSCNView`/RealityKit nativo, non renderizzabile in HTML). Flusso: l'operatore tocca "Misura con LiDAR" nella pagina web esistente della scheda serramento → si apre la schermata nativa per la sessione ARKit (individuazione piano/vano, 4 punti, correzione manuale, calcolo L/H/superficie, conferma) → al termine si torna alla webview con il risultato.

**B. File del progetto esistente da aggiungere/modificare.**
Nuovi, senza toccare nulla di esistente: `capacitor.config.json`, cartella `ios/` generata da Capacitor, `ios/App/App/MisuraLidarPlugin.swift`. Modifiche minime e additive: in `public/app.js` una funzione `avviaMisuraLidar()` che chiama il plugin solo se `window.Capacitor?.Plugins?.MisuraLidar` esiste (cioè siamo dentro l'app nativa) — altrimenti il pulsante resta nascosto; in `public/index.html` un pulsante "📐 Misura con LiDAR" nella scheda serramento, visibile solo quando il plugin è disponibile. **Nessuna modifica a `db.js`/`server.js`** per questo passo: il salvataggio userà il `PATCH /api/serramenti/:id` già esistente.

**C. Comunicazione plugin iOS ↔ JavaScript esistente.**
Capacitor genera automaticamente il bridge: dal JS si chiama `Capacitor.Plugins.MisuraLidar.misura()` (Promise-based); il codice Swift esegue la sessione ARKit e, alla conferma dell'operatore, la Promise lato JS si risolve con l'oggetto risultato. Non servono postMessage manuali o eventi custom, lo gestisce il framework.

**D. Oggetto restituito alla scheda serramento** (come richiesto):

```
{
  larghezza,            // stessa unità già in uso nell'app (cm)
  altezza,
  superficie,            // larghezza × altezza
  metodoMisura,          // "ar_lidar"
  dispositivo,           // es. "iPhone 15 Pro" (da UIDevice)
  attendibilita,          // qualitativa: "alta" | "media" | "bassa" — mai un numero inventato
  confermataOperatore     // true solo dopo lo schermo di conferma esplicita nativo
}
```

Questo oggetto verrà mappato dalla funzione `avviaMisuraLidar()` sui campi già pronti nello schema (`larghezza_cm`, `altezza_cm`, `metodo_misurazione`, `dispositivo_misurazione`, `attendibilita`, `misura_confermata`) e inviato con lo stesso `PATCH /api/serramenti/:id` già in uso oggi — nessun nuovo endpoint necessario per questo.

**E. Modifiche a Render/backend vs cosa resta solo sul dispositivo.**
Sul backend Render/Express: nessuna modifica necessaria per il modulo in sé, riceve solo più campi nello stesso PATCH esistente. Un'eventuale futura estensione (non richiesta ora) potrebbe essere un endpoint per aggregare i "log di test precisione" (LiDAR vs metro laser vs distanza operatore) se si vorrà costruire la statistica su più dispositivi/operatori — per ora questi dati possono restare nello stesso `storico_misure` già presente, che è un array libero e accetta nuovi campi senza migrazioni. Tutto ciò che riguarda ARKit/Scene Depth/UI nativa resta esclusivamente sul dispositivo, non tocca mai il server.

**F. Convivenza con la versione browser attuale.**
Il sito su Render continua a funzionare identico da Safari/Chrome per chi non ha l'app nativa: il pulsante "Misura con LiDAR" semplicemente non compare (o appare disabilitato) quando `window.Capacitor` non è presente. Zero regressioni per l'uso via link web.

## Nota sulla precisione — nessun valore promesso

Come richiesto, non vengono assunti valori teorici di precisione. Quando il modulo verrà scritto, ogni misura di test dovrà registrare: valore LiDAR, valore corretto manualmente, valore reale da metro laser (quando inserito), differenza in mm, distanza approssimativa dell'operatore, dispositivo usato — lo schema `storico_misure` già predisposto può accogliere questi campi senza bisogno di modifiche strutturali quando si arriverà a implementarlo.

## Percorso di test consigliato

Per il test sul campo, TestFlight (distribuzione Apple per test interni) evita i tempi di review dell'App Store e permette iterazioni rapide sul dispositivo reale — richiede comunque Mac + Xcode + account Apple Developer, ma nessuna pubblicazione pubblica per questa fase.

## Prossimo passo

In attesa della tua approvazione su questa architettura prima di iniziare qualunque implementazione nativa/PWA/Capacitor.
