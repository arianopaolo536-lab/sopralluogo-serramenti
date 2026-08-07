// Archivio dati semplice basato su file JSON (nessuna dipendenza nativa,
// funziona ovunque senza bisogno di compilazione).
const fs = require('fs');
const path = require('path');

function datiGeneraliVuoti() {
  return {
    note_generali: '',
    dati_fabbricato: '',
    sezioni: {}, // { [sezioneId]: { campi: { [chiave]: valore }, foto: [{id, path}] } }
  };
}

function creaDb(dataDir) {
  if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
  const dbPath = path.join(dataDir, 'db.json');

  let stato = {
    sopralluoghi: [], serramenti: [],
    nextSopralluogoId: 1, nextSerramentoId: 1, nextFotoSezioneId: 1,
  };
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

  function sezione(sopralluogo, sezioneId) {
    if (!sopralluogo.dati_generali) sopralluogo.dati_generali = datiGeneraliVuoti();
    if (!sopralluogo.dati_generali.sezioni[sezioneId]) {
      sopralluogo.dati_generali.sezioni[sezioneId] = { campi: {}, foto: [] };
    }
    return sopralluogo.dati_generali.sezioni[sezioneId];
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
        titolo: data.titolo || null,
        nome_cantiere: data.nome_cantiere || null,
        cliente_nome: data.cliente_nome,
        indirizzo: data.indirizzo,
        telefono: data.telefono || null,
        email: data.email || null,
        rilevatori: data.rilevatori || null,
        data_sopralluogo: data.data_sopralluogo,
        note: data.note || null,
        pellicola_percento: data.pellicola_percento != null ? Number(data.pellicola_percento) : 92,
        dati_generali: datiGeneraliVuoti(),
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      };
      stato.sopralluoghi.push(nuovo);
      salva();
      return nuovo;
    },
    updateSopralluogo(id, data) {
      const s = this.getSopralluogo(id);
      if (!s) return null;
      const campiConsentiti = ['titolo', 'nome_cantiere', 'cliente_nome', 'indirizzo', 'telefono', 'email', 'rilevatori', 'data_sopralluogo', 'note', 'pellicola_percento'];
      for (const campo of campiConsentiti) {
        if (Object.prototype.hasOwnProperty.call(data, campo) && data[campo] !== undefined) {
          s[campo] = campo === 'pellicola_percento' && data[campo] !== null ? Number(data[campo]) : data[campo];
        }
      }
      if (data.dati_generali) {
        s.dati_generali = s.dati_generali || datiGeneraliVuoti();
        if (data.dati_generali.note_generali !== undefined) s.dati_generali.note_generali = data.dati_generali.note_generali;
        if (data.dati_generali.dati_fabbricato !== undefined) s.dati_generali.dati_fabbricato = data.dati_generali.dati_fabbricato;
        if (data.dati_generali.sezioni) {
          for (const [sezioneId, val] of Object.entries(data.dati_generali.sezioni)) {
            const sez = sezione(s, sezioneId);
            if (val.campi) Object.assign(sez.campi, val.campi);
          }
        }
      }
      s.updated_at = new Date().toISOString();
      salva();
      return s;
    },
    deleteSopralluogo(id) {
      id = Number(id);
      const daRimuovere = stato.serramenti.filter(w => w.sopralluogo_id === id);
      stato.serramenti = stato.serramenti.filter(w => w.sopralluogo_id !== id);
      stato.sopralluoghi = stato.sopralluoghi.filter(s => s.id !== id);
      salva();
      return daRimuovere;
    },

    // --- Foto delle sezioni "Dati generali" ---
    aggiungiFotoSezione(sopralluogoId, sezioneId, fotoPath) {
      const s = this.getSopralluogo(sopralluogoId);
      if (!s) return null;
      const sez = sezione(s, sezioneId);
      const foto = { id: stato.nextFotoSezioneId++, path: fotoPath };
      sez.foto.push(foto);
      s.updated_at = new Date().toISOString();
      salva();
      return foto;
    },
    rimuoviFotoSezione(sopralluogoId, sezioneId, fotoId) {
      const s = this.getSopralluogo(sopralluogoId);
      if (!s) return null;
      const sez = sezione(s, sezioneId);
      const rimossa = sez.foto.find(f => f.id === Number(fotoId)) || null;
      sez.foto = sez.foto.filter(f => f.id !== Number(fotoId));
      s.updated_at = new Date().toISOString();
      salva();
      return rimossa;
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
        codice: data.codice || null,
        piano: data.piano || null,
        interno: data.interno || null,
        ambiente: data.ambiente,
        tipo: data.tipo,
        larghezza_cm: data.larghezza_cm ? Number(data.larghezza_cm) : null,
        altezza_cm: data.altezza_cm ? Number(data.altezza_cm) : null,
        spessore_muro_cm: data.spessore_muro_cm ? Number(data.spessore_muro_cm) : null,
        tipo_apertura: data.tipo_apertura || null,
        materiale_attuale: data.materiale_attuale || null,
        cassonetto: data.cassonetto === true || data.cassonetto === 'true' || data.cassonetto === 'on',
        stato: data.stato || null,
        note: data.note || null,
        foto_path: data.foto_path || null,
        created_at: new Date().toISOString(),
      };
      stato.serramenti.push(nuovo);
      salva();
      return nuovo;
    },
    updateSerramento(id, data) {
      const w = this.getSerramento(id);
      if (!w) return null;
      const campiTesto = ['codice', 'piano', 'interno', 'ambiente', 'tipo', 'tipo_apertura', 'materiale_attuale', 'stato', 'note'];
      for (const campo of campiTesto) {
        if (Object.prototype.hasOwnProperty.call(data, campo) && data[campo] !== undefined) {
          w[campo] = data[campo] || null;
        }
      }
      for (const campo of ['larghezza_cm', 'altezza_cm', 'spessore_muro_cm']) {
        if (Object.prototype.hasOwnProperty.call(data, campo) && data[campo] !== undefined) {
          w[campo] = data[campo] ? Number(data[campo]) : null;
        }
      }
      if (Object.prototype.hasOwnProperty.call(data, 'cassonetto')) {
        w.cassonetto = data.cassonetto === true || data.cassonetto === 'true' || data.cassonetto === 'on';
      }
      if (data.foto_path) w.foto_path = data.foto_path;
      salva();
      return w;
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
