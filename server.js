const express = require('express');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const { creaDb } = require('./db');

const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const UPLOAD_DIR = process.env.UPLOAD_DIR || path.join(__dirname, 'uploads');

for (const dir of [DATA_DIR, UPLOAD_DIR]) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

const db = creaDb(DATA_DIR);

const app = express();
app.use(express.json());
app.use('/uploads', express.static(UPLOAD_DIR));
app.use(express.static(path.join(__dirname, 'public')));

const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, UPLOAD_DIR),
  filename: (req, file, cb) => {
    const ext = path.extname(file.originalname) || '.jpg';
    cb(null, `foto_${Date.now()}_${Math.round(Math.random() * 1e6)}${ext}`);
  },
});
const upload = multer({
  storage,
  limits: { fileSize: 8 * 1024 * 1024 },
  fileFilter: (req, file, cb) => {
    if (!file.mimetype.startsWith('image/')) {
      return cb(new Error('Sono ammesse solo immagini'));
    }
    cb(null, true);
  },
});

// --- API: Sopralluoghi ---

app.get('/api/sopralluoghi', (req, res) => {
  res.json(db.listSopralluoghi());
});

app.get('/api/sopralluoghi/:id', (req, res) => {
  const sopralluogo = db.getSopralluogo(req.params.id);
  if (!sopralluogo) return res.status(404).json({ error: 'Sopralluogo non trovato' });
  const serramenti = db.listSerramenti(req.params.id);
  res.json({ ...sopralluogo, serramenti });
});

app.post('/api/sopralluoghi', (req, res) => {
  const { modalita, titolo, nome_cantiere, cliente_nome, indirizzo, telefono, email, rilevatori, data_sopralluogo, note, pellicola_percento } = req.body;
  if (!cliente_nome || !indirizzo || !data_sopralluogo) {
    return res.status(400).json({ error: 'cliente_nome, indirizzo e data_sopralluogo sono obbligatori' });
  }
  if (!db.MODALITA_VALIDE.includes(modalita)) {
    return res.status(400).json({ error: `modalita obbligatoria: una tra ${db.MODALITA_VALIDE.join(', ')}` });
  }
  const creato = db.createSopralluogo({ modalita, titolo, nome_cantiere, cliente_nome, indirizzo, telefono, email, rilevatori, data_sopralluogo, note, pellicola_percento });
  res.status(201).json(creato);
});

// Aggiornamento parziale (usato per il salvataggio automatico dei campi).
app.patch('/api/sopralluoghi/:id', (req, res) => {
  const aggiornato = db.updateSopralluogo(req.params.id, req.body);
  if (!aggiornato) return res.status(404).json({ error: 'Sopralluogo non trovato' });
  res.json(aggiornato);
});

app.delete('/api/sopralluoghi/:id', (req, res) => {
  const sopralluogo = db.getSopralluogo(req.params.id);
  if (!sopralluogo) return res.status(404).json({ error: 'Sopralluogo non trovato' });
  const rimossi = db.deleteSopralluogo(req.params.id);
  for (const w of rimossi) {
    if (w.foto_path) {
      const p = path.join(UPLOAD_DIR, path.basename(w.foto_path));
      if (fs.existsSync(p)) fs.unlinkSync(p);
    }
  }
  res.status(204).end();
});

// --- API: Foto delle sezioni "Dati generali" ---

app.post('/api/sopralluoghi/:id/sezioni/:sezioneId/foto', upload.single('foto'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'Nessuna foto ricevuta' });
  const foto_path = `/uploads/${req.file.filename}`;
  const foto = db.aggiungiFotoSezione(req.params.id, req.params.sezioneId, foto_path);
  if (!foto) return res.status(404).json({ error: 'Sopralluogo non trovato' });
  res.status(201).json(foto);
});

app.delete('/api/sopralluoghi/:id/sezioni/:sezioneId/foto/:fotoId', (req, res) => {
  const rimossa = db.rimuoviFotoSezione(req.params.id, req.params.sezioneId, req.params.fotoId);
  if (rimossa && rimossa.path) {
    const p = path.join(UPLOAD_DIR, path.basename(rimossa.path));
    if (fs.existsSync(p)) fs.unlinkSync(p);
  }
  res.status(204).end();
});

// --- API: Serramenti (con foto) ---

app.post('/api/sopralluoghi/:id/serramenti', upload.single('foto'), (req, res) => {
  const sopralluogo = db.getSopralluogo(req.params.id);
  if (!sopralluogo) return res.status(404).json({ error: 'Sopralluogo non trovato' });

  const { ambiente, tipo } = req.body;
  if (!ambiente || !tipo) {
    return res.status(400).json({ error: 'ambiente e tipo sono obbligatori' });
  }

  const foto_path = req.file ? `/uploads/${req.file.filename}` : null;
  const creato = db.createSerramento(req.params.id, { ...req.body, foto_path });
  res.status(201).json(creato);
});

app.patch('/api/serramenti/:id', upload.single('foto'), (req, res) => {
  const dati = { ...req.body };
  if (req.file) dati.foto_path = `/uploads/${req.file.filename}`;
  const aggiornato = db.updateSerramento(req.params.id, dati);
  if (!aggiornato) return res.status(404).json({ error: 'Serramento non trovato' });
  res.json(aggiornato);
});

app.delete('/api/serramenti/:id', (req, res) => {
  const rimosso = db.deleteSerramento(req.params.id);
  if (rimosso && rimosso.foto_path) {
    const p = path.join(UPLOAD_DIR, path.basename(rimosso.foto_path));
    if (fs.existsSync(p)) fs.unlinkSync(p);
  }
  res.status(204).end();
});

app.get('/api/health', (req, res) => res.json({ ok: true }));

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Server avviato su http://localhost:${PORT}`);
});
