# Sopralluogo Serramenti

App web per registrare i sopralluoghi per l'installazione di nuovi serramenti
(finestre, portefinestre, porte, scorrevoli...). Pensata per essere usata
direttamente in cantiere da smartphone, tablet o computer.

## Funzionalità

- Anagrafica cliente (nome, indirizzo, telefono, email) e data del sopralluogo.
- Elenco dei serramenti rilevati per ogni sopralluogo: ambiente, tipo,
  larghezza/altezza/spessore muro, tipo di apertura, materiale attuale, stato, note.
- Scatto foto direttamente dal browser (fotocamera del dispositivo) oppure
  caricamento di una foto esistente.
- **Dettatura vocale** (🎤) su tutti i campi di testo e numerici, per inserire
  dati e misure a voce mentre si è impegnati con metro e cacciavite.
  Richiede un browser con supporto al riconoscimento vocale (Chrome su
  Android/desktop funziona bene; Safari ha supporto parziale).
- Dati salvati su un piccolo database a file (nessun servizio esterno richiesto).

## Struttura del progetto

```
sopralluogo-serramenti/
├── server.js        # server Express + API REST
├── db.js            # archivio dati su file JSON (senza dipendenze native)
├── package.json
├── render.yaml       # blueprint per il deploy automatico su Render
├── public/            # frontend (HTML/CSS/JS)
│   ├── index.html
│   ├── style.css
│   └── app.js
├── data/               # (creata automaticamente) contiene db.json
└── uploads/            # (creata automaticamente) contiene le foto caricate
```

## Uso in locale

Richiede Node.js 18 o superiore.

```bash
npm install
npm start
```

L'app sarà disponibile su `http://localhost:3000`.

---

## Pubblicare su GitHub

Questi passaggi vanno eseguiti da te (per motivi di sicurezza non posso
inserire le tue credenziali GitHub al posto tuo).

1. Crea un nuovo repository vuoto su [github.com/new](https://github.com/new),
   ad esempio chiamato `sopralluogo-serramenti` (NON aggiungere README, licenza
   o .gitignore: sono già inclusi in questo progetto).
2. Nella cartella del progetto, apri il terminale ed esegui:

   ```bash
   git init
   git add .
   git commit -m "Prima versione app sopralluogo serramenti"
   git branch -M main
   git remote add origin https://github.com/<tuo-utente>/sopralluogo-serramenti.git
   git push -u origin main
   ```

   Sostituisci `<tuo-utente>` con il tuo nome utente GitHub. Al primo push
   ti verrà chiesto di autenticarti (consigliato: token di accesso personale
   invece della password, oppure GitHub CLI `gh auth login`).

## Deploy su Render

1. Vai su [dashboard.render.com](https://dashboard.render.com) e accedi
   (o crea un account).
2. Clicca **New +** → **Blueprint**, poi collega il repository GitHub
   appena creato. Render leggerà automaticamente il file `render.yaml`
   incluso nel progetto e configurerà il servizio.
   - In alternativa: **New +** → **Web Service**, seleziona il repository,
     imposta *Build Command* `npm install` e *Start Command* `npm start`.
3. **Persistenza dei dati:** il file `render.yaml` è già configurato con
   piano `starter` e un **disco persistente** montato su `/var/data`, dove
   vengono salvati sia il database (`db.json`) sia le foto caricate. Con un
   piano a pagamento i dati restano intatti tra un deploy e l'altro. Se hai
   un piano superiore (Standard, Pro...) puoi cambiare il valore `plan` nel
   file `render.yaml` prima di fare il deploy.
4. Clicca **Deploy**. Dopo qualche minuto l'app sarà online su un indirizzo
   tipo `https://sopralluogo-serramenti.onrender.com`.

## Note su fotocamera e dettatura vocale

Entrambe le funzioni richiedono che il sito sia servito in **HTTPS**
(Render lo fornisce automaticamente) oppure che venga aperto su
`localhost`: i browser bloccano l'accesso a fotocamera e microfono su
connessioni HTTP non sicure.
