// Archivio dati semplice basato su file JSON (nessuna dipendenza nativa,
// funziona ovunque senza bisogno di compilazione).
const fs = require('fs');
const path = require('path');

function creaDb(dataDir) {
  if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
  const dbPath = path.join(dataDir, 'db.json');

  let stato = { sopralluoghi: [], serramenti: [], nextSopralluogoId: 1, nextSerramentoId: 1 };
  if (fs.existsSync(dbPath)) {
    try {
      stato = { ...stato, ...JSON.parse(fs.readFileSync(dbPath, 'utf8')) };
    } catch (e) {
      console.error('Impossibile leggere il database, riparto da vuoto:', e.message);
    }
  }

  function salva() {
    fs.writeFileSync(dbPath, JSON.stringify(stato, null, 2));
  }

  return {
    // --- Sopralluoghi ---
    listSopralluoghi() {
      return [...stato.sopralluoghi]
        .sort((a, b) => (b.data_sopralluogo || '').localeCompare(a.data_sopralluogo || '') || b.id - a.id)
        .map(s => ({
          ...s,
          num_serramenti: stato.serramenti.filter(w => w.sopralluogo_id === s.id).length,
        }));
    },
    getSopralluogo(id) {
      return stato.sopralluoghi.find(s => s.id === Number(id)) || null;
    },
    createSopralluogo(data) {
      const nuovo = {
        id: stato.nextSopralluogoId++,
        cliente_nome: data.cliente_nome,
        indirizzo: data.indirizzo,
        telefono: data.telefono || null,
        email: data.email || null,
        data_sopralluogo: data.data_sopralluogo,
        note: data.note || null,
        created_at: new Date().toISOString(),
      };
      stato.sopralluoghi.push(nuovo);
      salva();
      return nuovo;
    },
    deleteSopralluogo(id) {
      id = Number(id);
      const daRimuovere = stato.serramenti.filter(w => w.sopralluogo_id === id);
      stato.serramenti = stato.serramenti.filter(w => w.sopralluogo_id !== id);
      stato.sopralluoghi = stato.sopralluoghi.filter(s => s.id !== id);
      salva();
      return daRimuovere;
    },

    // --- Serramenti ---
    listSerramenti(sopralluogoId) {
      return stato.serramenti
        .filter(w => w.sopralluogo_id === Number(sopralluogoId))
        .sort((a, b) => a.id - b.id);
    },
    getSerramento(id) {
      return stato.serramenti.find(w => w.id === Number(id)) || null;
    },
    createSerramento(sopralluogoId, data) {
      const nuovo = {
        id: stato.nextSerramentoId++,
        sopralluogo_id: Number(sopralluogoId),
        ambiente: data.ambiente,
        tipo: data.tipo,
        larghezza_cm: data.larghezza_cm ? Number(data.larghezza_cm) : null,
        altezza_cm: data.altezza_cm ? Number(data.altezza_cm) : null,
        spessore_muro_cm: data.spessore_muro_cm ? Number(data.spessore_muro_cm) : null,
        tipo_apertura: data.tipo_apertura || null,
        materiale_attuale: data.materiale_attuale || null,
        stato: data.stato || null,
        note: data.note || null,
        foto_path: data.foto_path || null,
        created_at: new Date().toISOString(),
      };
      stato.serramenti.push(nuovo);
      salva();
      return nuovo;
    },
    deleteSerramento(id) {
      id = Number(id);
      const rimosso = stato.serramenti.find(w => w.id === id) || null;
      stato.serramenti = stato.serramenti.filter(w => w.id !== id);
      salva();
      return rimosso;
    },
  };
}

module.exports = { creaDb };
