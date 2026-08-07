// ---------- Configurazione sezioni "Dati generali" ----------
const SEZIONI_DATI_GENERALI = [
  {
    id: 'accesso', numero: 1,
    titolo: 'Identificazione e accesso mezzi',
    sottotitolo: 'Referenti, portone, scarico e autorizzazioni',
    campi: [
      { chiave: 'referente', etichetta: 'Referente in loco' },
      { chiave: 'accesso_mezzi', etichetta: 'Modalità di accesso mezzi' },
      { chiave: 'punto_scarico', etichetta: 'Punto di scarico materiali' },
      { chiave: 'autorizzazioni', etichetta: 'Autorizzazioni necessarie' },
    ],
  },
  {
    id: 'scale', numero: 2,
    titolo: 'Scale, pianerottoli e trasporto',
    sottotitolo: 'Misura sempre il passaggio più stretto',
    campi: [
      { chiave: 'larghezza_vano', etichetta: 'Larghezza vano scala / ascensore' },
      { chiave: 'montacarichi', etichetta: 'Presenza ascensore o montacarichi' },
      { chiave: 'curve_strette', etichetta: 'Pianerottoli e curve strette' },
      { chiave: 'note_trasporto', etichetta: 'Note trasporto materiali' },
    ],
  },
  {
    id: 'deposito', numero: 3,
    titolo: 'Deposito e smaltimento',
    sottotitolo: 'Aree di deposito, smaltimento macerie e materiali di risulta',
    campi: [
      { chiave: 'area_deposito', etichetta: 'Area di deposito materiali nuovi' },
      { chiave: 'smaltimento_macerie', etichetta: 'Modalità smaltimento macerie/vecchi infissi' },
      { chiave: 'accesso_cassone', etichetta: 'Accesso per cassone/container' },
      { chiave: 'note_deposito', etichetta: 'Note deposito e smaltimento' },
    ],
  },
  {
    id: 'vecchi_infissi', numero: 4,
    titolo: 'Vecchi infissi e sollevamento',
    sottotitolo: 'Materiali, smontaggio, piattaforma e ostacoli',
    campi: [
      { chiave: 'materiale_prevalente', etichetta: 'Materiale prevalente vecchi infissi' },
      { chiave: 'vetro_prevalente', etichetta: 'Vetro prevalente / vetri lesionati' },
      { chiave: 'controtelai', etichetta: 'Controtelai, imbotti e davanzali' },
      { chiave: 'oscuranti_grate', etichetta: 'Oscuranti / grate' },
    ],
  },
  {
    id: 'sicurezza', numero: 5,
    titolo: 'Sicurezza e organizzazione',
    sottotitolo: 'DPI, delimitazioni e organizzazione del cantiere',
    campi: [
      { chiave: 'dpi_necessari', etichetta: 'DPI necessari' },
      { chiave: 'delimitazione_area', etichetta: 'Delimitazione area cantiere' },
      { chiave: 'orari_lavori', etichetta: 'Orari consentiti per i lavori' },
      { chiave: 'note_sicurezza', etichetta: 'Note sicurezza' },
    ],
  },
];

// ---------- Stato applicazione ----------
let sopralluogoCorrenteId = null;
let sopralluogoCorrente = null;
let serramentoInModifica = null;
let permessoCameraConfermatoInSessione = false;

// ---------- Helper generici ----------
function $(sel, root = document) { return root.querySelector(sel); }
function $all(sel, root = document) { return [...root.querySelectorAll(sel)]; }

function mostraVista(id) {
  $all('.view').forEach(v => v.hidden = true);
  $(`#${id}`).hidden = false;
}

function mostraToast(msg) {
  const toast = $('#toast');
  toast.textContent = msg;
  toast.hidden = false;
  clearTimeout(mostraToast._t);
  mostraToast._t = setTimeout(() => { toast.hidden = true; }, 2600);
}

function formattaData(iso) {
  const d = new Date(iso + 'T00:00:00');
  if (isNaN(d)) return iso;
  return d.toLocaleDateString('it-IT', { day: '2-digit', month: '2-digit', year: 'numeric' });
}

async function api(path, opts = {}) {
  const res = await fetch(`/api${path}`, opts);
  if (!res.ok) {
    let msg = 'Errore di rete';
    try { msg = (await res.json()).error || msg; } catch {}
    throw new Error(msg);
  }
  if (res.status === 204) return null;
  return res.json();
}

function escapeHtml(str = '') {
  return String(str).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c]));
}

function mergeProfondo(a, b) {
  const risultato = { ...a };
  for (const [k, v] of Object.entries(b)) {
    if (v && typeof v === 'object' && !Array.isArray(v) && risultato[k] && typeof risultato[k] === 'object') {
      risultato[k] = mergeProfondo(risultato[k], v);
    } else {
      risultato[k] = v;
    }
  }
  return risultato;
}

// ---------- Elenco sopralluoghi ----------
async function caricaElenco() {
  const lista = $('#lista-sopralluoghi');
  lista.innerHTML = '<p class="vuoto">Caricamento...</p>';
  try {
    const dati = await api('/sopralluoghi');
    lista.innerHTML = '';
    $('#elenco-vuoto').hidden = dati.length !== 0;
    for (const s of dati) {
      const el = document.createElement('div');
      el.className = 'item-sopralluogo';
      const titoloVisivo = s.titolo || s.nome_cantiere || s.cliente_nome;
      el.innerHTML = `
        <div class="riga-titolo">
          <span>${escapeHtml(titoloVisivo)}</span>
          <span>${formattaData(s.data_sopralluogo)}</span>
        </div>
        <div class="meta">${escapeHtml(s.cliente_nome)} · ${escapeHtml(s.indirizzo)} · ${s.num_serramenti} serrament${s.num_serramenti === 1 ? 'o' : 'i'}</div>
      `;
      el.addEventListener('click', () => apriDettaglio(s.id));
      lista.appendChild(el);
    }
  } catch (e) {
    lista.innerHTML = `<p class="vuoto">Errore nel caricamento: ${escapeHtml(e.message)}</p>`;
  }
}

// ---------- Nuovo sopralluogo ----------
$('#btn-nuovo').addEventListener('click', () => {
  $('#form-nuovo').reset();
  $('#form-nuovo').querySelector('[name=data_sopralluogo]').value = new Date().toISOString().slice(0, 10);
  mostraVista('view-nuovo');
});

$('#btn-annulla-nuovo').addEventListener('click', () => mostraVista('view-elenco'));

$('#form-nuovo').addEventListener('submit', async (e) => {
  e.preventDefault();
  const fd = new FormData(e.target);
  const payload = Object.fromEntries(fd.entries());
  try {
    const creato = await api('/sopralluoghi', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    mostraToast('Sopralluogo creato');
    apriDettaglio(creato.id);
  } catch (e) {
    mostraToast(e.message);
  }
});

// ---------- Dettaglio sopralluogo ----------
$('#btn-indietro').addEventListener('click', () => {
  sopralluogoCorrenteId = null;
  sopralluogoCorrente = null;
  mostraVista('view-elenco');
  caricaElenco();
});

async function apriDettaglio(id) {
  sopralluogoCorrenteId = id;
  mostraVista('view-dettaglio');
  await caricaDettaglio();
}

async function ricaricaSopralluogoCorrente() {
  sopralluogoCorrente = await api(`/sopralluoghi/${sopralluogoCorrenteId}`);
  renderSezioni();
  aggiornaStatistiche();
  renderRilievoMisure();
  renderTabellaRiepilogo();
}

async function caricaDettaglio() {
  try {
    sopralluogoCorrente = await api(`/sopralluoghi/${sopralluogoCorrenteId}`);
    const s = sopralluogoCorrente;
    $('#campo-titolo').value = s.titolo || `${s.cliente_nome} - ${s.indirizzo}`;
    ridimensionaTitolo();
    $('#campo-data').value = s.data_sopralluogo || '';
    $('#campo-rilevatori').value = s.rilevatori || '';
    $('#campo-note-generali').value = (s.dati_generali && s.dati_generali.note_generali) || '';
    $('#campo-dati-fabbricato').value = (s.dati_generali && s.dati_generali.dati_fabbricato) || '';
    impostaIndicatoreSalvato();
    renderSezioni();
    aggiornaStatistiche();
    renderRilievoMisure();
    renderTabellaRiepilogo();
    // Torna sempre al primo tab quando si apre un sopralluogo
    attivaTab('dati-generali');
  } catch (e) {
    mostraToast('Errore nel caricamento: ' + e.message);
  }
}

function ridimensionaTitolo() {
  const el = $('#campo-titolo');
  el.style.height = 'auto';
  el.style.height = el.scrollHeight + 'px';
}
$('#campo-titolo').addEventListener('input', ridimensionaTitolo);

// ---------- Salvataggio automatico ----------
let salvataggioPendente = {};
let timerSalvataggio = null;

function impostaIndicatoreSalvato() {
  const el = $('#indicatore-salvataggio');
  el.textContent = '● Salvato';
  el.classList.remove('salvataggio');
}

function segnaSalvataggio(parziale) {
  salvataggioPendente = mergeProfondo(salvataggioPendente, parziale);
  const el = $('#indicatore-salvataggio');
  el.textContent = 'Salvataggio...';
  el.classList.add('salvataggio');
  clearTimeout(timerSalvataggio);
  timerSalvataggio = setTimeout(async () => {
    const daInviare = salvataggioPendente;
    salvataggioPendente = {};
    try {
      const aggiornato = await api(`/sopralluoghi/${sopralluogoCorrenteId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(daInviare),
      });
      sopralluogoCorrente = aggiornato;
      impostaIndicatoreSalvato();
    } catch (e) {
      mostraToast('Errore salvataggio: ' + e.message);
    }
  }, 700);
}

$('#campo-titolo').addEventListener('input', (e) => segnaSalvataggio({ titolo: e.target.value }));
$('#campo-data').addEventListener('input', (e) => segnaSalvataggio({ data_sopralluogo: e.target.value }));
$('#campo-rilevatori').addEventListener('input', (e) => segnaSalvataggio({ rilevatori: e.target.value }));
$('#campo-note-generali').addEventListener('input', (e) => segnaSalvataggio({ dati_generali: { note_generali: e.target.value } }));
$('#campo-dati-fabbricato').addEventListener('input', (e) => segnaSalvataggio({ dati_generali: { dati_fabbricato: e.target.value } }));

$('#btn-toggle-fabbricato').addEventListener('click', () => {
  const blocco = $('#blocco-dati-fabbricato');
  blocco.hidden = !blocco.hidden;
});

$('#btn-stampa').addEventListener('click', () => window.print());

// ---------- Tab ----------
function attivaTab(nome) {
  $all('.tab-btn').forEach(b => b.classList.toggle('attivo', b.dataset.tab === nome));
  $all('.tab-panel').forEach(p => { p.hidden = p.id !== `tab-${nome}`; });
}
$all('.tab-btn').forEach(btn => btn.addEventListener('click', () => attivaTab(btn.dataset.tab)));

// ---------- Statistiche ----------
function calcolaStatistiche() {
  const elenco = (sopralluogoCorrente && sopralluogoCorrente.serramenti) || [];
  const numero = elenco.length;
  const mqTotali = elenco.reduce((tot, w) => tot + (((w.larghezza_cm || 0) * (w.altezza_cm || 0)) / 10000), 0);
  const cassonetti = elenco.filter(w => w.cassonetto).length;
  const percentualePellicola = (sopralluogoCorrente && sopralluogoCorrente.pellicola_percento != null) ? sopralluogoCorrente.pellicola_percento : 92;
  const mqPellicola = mqTotali * (percentualePellicola / 100);
  return { numero, mqTotali, cassonetti, mqPellicola, percentualePellicola };
}

function aggiornaStatistiche() {
  const s = calcolaStatistiche();
  $('#stat-serramenti').textContent = s.numero;
  $('#stat-mq').textContent = s.mqTotali.toFixed(1);
  $('#stat-cassonetti').textContent = s.cassonetti;
  $('#stat-pellicola').textContent = s.mqPellicola.toFixed(1);
  $('#stat-pellicola-etichetta').textContent = `m² pellicola ${s.percentualePellicola}%`;
  $('#rp-stat-serramenti').textContent = s.numero;
  $('#rp-stat-mq').textContent = s.mqTotali.toFixed(1);
  $('#rp-stat-cassonetti').textContent = s.cassonetti;
  $('#rp-stat-pellicola').textContent = s.mqPellicola.toFixed(1);
  $('#campo-pellicola').value = s.percentualePellicola;
}

$('#campo-pellicola').addEventListener('input', (e) => {
  segnaSalvataggio({ pellicola_percento: e.target.value ? Number(e.target.value) : 0 });
  if (sopralluogoCorrente) sopralluogoCorrente.pellicola_percento = e.target.value ? Number(e.target.value) : 0;
  aggiornaStatistiche();
});

// ---------- Sezioni "Dati generali" ----------
function renderSezioni() {
  const container = $('#sezioni-dati-generali');
  const apertaPrecedente = $all('.sezione-corpo', container).findIndex(c => !c.hidden);
  container.innerHTML = SEZIONI_DATI_GENERALI.map((sez, indice) => {
    const datiSezione = (sopralluogoCorrente.dati_generali && sopralluogoCorrente.dati_generali.sezioni && sopralluogoCorrente.dati_generali.sezioni[sez.id]) || { campi: {}, foto: [] };
    const aperta = apertaPrecedente === -1 ? indice === 0 : indice === apertaPrecedente;
    return `
      <div class="sezione-accordion">
        <button type="button" class="sezione-header">
          <span class="sezione-numero">${sez.numero}</span>
          <span class="sezione-titoli"><strong>${escapeHtml(sez.titolo)}</strong><small>${escapeHtml(sez.sottotitolo)}</small></span>
          <span class="sezione-toggle">${aperta ? '−' : '+'}</span>
        </button>
        <div class="sezione-corpo" data-sezione-corpo="${sez.id}" ${aperta ? '' : 'hidden'}>
          <div class="sezione-foto-blocco">
            <div class="sezione-foto-header">
              <div><strong>Fotografie</strong><p>Scatta panoramica e dettagli con il metro visibile.</p></div>
              <div>
                <button type="button" class="btn btn-primary btn-scatta-sezione" data-sezione="${sez.id}">📷 Scatta/aggiungi</button>
                <input type="file" accept="image/*" multiple class="input-foto-sezione" data-sezione="${sez.id}" hidden>
              </div>
            </div>
            <div class="griglia-foto" data-griglia="${sez.id}">
              ${(datiSezione.foto || []).map((f, i) => fotoItemHtml(sez.id, f, i)).join('')}
            </div>
          </div>
          <div class="sezione-campi">
            ${sez.campi.map(c => `
              <label class="campo-sezione">
                <div class="campo-con-detta">
                  <span>${escapeHtml(c.etichetta)}</span>
                  <button type="button" class="btn-detta" data-sezione="${sez.id}" data-chiave="${c.chiave}">🎙 Detta</button>
                </div>
                <textarea rows="2" data-sezione-campo="${sez.id}:${c.chiave}">${escapeHtml((datiSezione.campi || {})[c.chiave] || '')}</textarea>
              </label>
            `).join('')}
          </div>
        </div>
      </div>
    `;
  }).join('');
}

function fotoItemHtml(sezioneId, foto, indice) {
  return `
    <div class="foto-item">
      <img src="${foto.path}" alt="Foto ${indice + 1}">
      <div class="foto-item-azioni">
        <span>Foto ${indice + 1}</span>
        <button type="button" class="btn-elimina-foto-sezione" data-sezione="${sezioneId}" data-foto="${foto.id}">Elimina</button>
      </div>
    </div>
  `;
}

const containerSezioni = $('#sezioni-dati-generali');

containerSezioni.addEventListener('click', (e) => {
  const headerSezione = e.target.closest('.sezione-header');
  if (headerSezione) {
    const corpo = headerSezione.nextElementSibling;
    corpo.hidden = !corpo.hidden;
    headerSezione.querySelector('.sezione-toggle').textContent = corpo.hidden ? '+' : '−';
    return;
  }
  const bottoneScatta = e.target.closest('.btn-scatta-sezione');
  if (bottoneScatta) {
    apriCameraPerSezione(bottoneScatta.dataset.sezione);
    return;
  }
  const bottoneElimina = e.target.closest('.btn-elimina-foto-sezione');
  if (bottoneElimina) {
    eliminaFotoSezione(bottoneElimina.dataset.sezione, bottoneElimina.dataset.foto);
    return;
  }
});

containerSezioni.addEventListener('change', async (e) => {
  if (e.target.matches('.input-foto-sezione')) {
    const sezioneId = e.target.dataset.sezione;
    const file = e.target.files[0];
    e.target.value = '';
    if (file) await caricaFotoSezione(sezioneId, file);
  }
});

containerSezioni.addEventListener('input', (e) => {
  if (e.target.matches('[data-sezione-campo]')) {
    const [sezioneId, chiave] = e.target.dataset.sezioneCampo.split(':');
    segnaSalvataggio({ dati_generali: { sezioni: { [sezioneId]: { campi: { [chiave]: e.target.value } } } } });
  }
});

async function caricaFotoSezione(sezioneId, file) {
  const fd = new FormData();
  fd.append('foto', file);
  try {
    await api(`/sopralluoghi/${sopralluogoCorrenteId}/sezioni/${sezioneId}/foto`, { method: 'POST', body: fd });
    const s = await api(`/sopralluoghi/${sopralluogoCorrenteId}`);
    sopralluogoCorrente = s;
    renderSezioni();
    mostraToast('Foto aggiunta');
  } catch (e) {
    mostraToast('Errore: ' + e.message);
  }
}

async function eliminaFotoSezione(sezioneId, fotoId) {
  try {
    await api(`/sopralluoghi/${sopralluogoCorrenteId}/sezioni/${sezioneId}/foto/${fotoId}`, { method: 'DELETE' });
    const s = await api(`/sopralluoghi/${sopralluogoCorrenteId}`);
    sopralluogoCorrente = s;
    renderSezioni();
  } catch (e) {
    mostraToast('Errore: ' + e.message);
  }
}

// ---------- Dettatura vocale ----------
const SpeechRecognitionCtor = window.SpeechRecognition || window.webkitSpeechRecognition;
if (!SpeechRecognitionCtor) $('#avviso-voce').hidden = false;

let riconoscimentoAttivo = null;

function estraiNumero(testo) {
  const m = testo.replace(',', '.').match(/-?\d+(\.\d+)?/);
  return m ? m[0] : testo;
}

function avviaDettaturaSuCampo(bottone, campo) {
  if (!SpeechRecognitionCtor) {
    mostraToast('Dettatura non supportata da questo browser.');
    return;
  }
  if (riconoscimentoAttivo) {
    riconoscimentoAttivo.stop();
    return;
  }
  const r = new SpeechRecognitionCtor();
  r.lang = 'it-IT';
  r.interimResults = false;
  r.maxAlternatives = 1;
  riconoscimentoAttivo = r;

  r.onstart = () => bottone.classList.add('ascolto');
  r.onend = () => { bottone.classList.remove('ascolto'); riconoscimentoAttivo = null; };
  r.onerror = (ev) => {
    bottone.classList.remove('ascolto');
    riconoscimentoAttivo = null;
    if (ev.error !== 'aborted' && ev.error !== 'no-speech') {
      mostraToast('Dettatura non riuscita: ' + ev.error);
    }
  };
  r.onresult = (ev) => {
    const testo = ev.results[0][0].transcript.trim();
    const valore = campo.type === 'number' ? estraiNumero(testo) : testo;
    campo.value = campo.value ? `${campo.value} ${valore}` : valore;
    campo.dispatchEvent(new Event('input', { bubbles: true }));
  };
  r.start();
}

document.addEventListener('click', (e) => {
  const bottoneDetta = e.target.closest('.btn-detta');
  if (!bottoneDetta) return;
  let campo = null;
  if (bottoneDetta.dataset.target) {
    campo = document.getElementById(bottoneDetta.dataset.target);
  } else if (bottoneDetta.dataset.sezione && bottoneDetta.dataset.chiave) {
    campo = document.querySelector(`[data-sezione-campo="${bottoneDetta.dataset.sezione}:${bottoneDetta.dataset.chiave}"]`);
  }
  if (campo) avviaDettaturaSuCampo(bottoneDetta, campo);
});

// Dettatura per i campi semplici (form "Nuovo sopralluogo")
function abilitaVoceSuCampo(campo) {
  if (campo.dataset.voceAbilitata) return;
  campo.dataset.voceAbilitata = '1';
  const wrapper = document.createElement('div');
  wrapper.className = 'campo-voce';
  campo.parentNode.insertBefore(wrapper, campo);
  wrapper.appendChild(campo);
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'btn-mic';
  btn.title = 'Detta questo campo';
  btn.textContent = '🎤';
  wrapper.appendChild(btn);
  if (!SpeechRecognitionCtor) { btn.disabled = true; return; }
  btn.addEventListener('click', () => avviaDettaturaSuCampo(btn, campo));
}
$all('input[type=text], input[type=tel], input[type=email], textarea', $('#form-nuovo')).forEach(abilitaVoceSuCampo);

// ---------- Rilievo misure ----------
$('#campo-cerca-serramento').addEventListener('input', (e) => renderRilievoMisure(e.target.value));

function renderRilievoMisure(filtro = '') {
  const lista = $('#lista-serramenti');
  const tuttiSerramenti = (sopralluogoCorrente && sopralluogoCorrente.serramenti) || [];
  const f = filtro.trim().toLowerCase();
  const filtrati = f
    ? tuttiSerramenti.filter(w => [w.codice, w.piano, w.interno, w.ambiente].some(v => v && v.toLowerCase().includes(f)))
    : tuttiSerramenti;

  $('#rilievo-sottotitolo').textContent =
    `Da utilizzare in sede di rilievo esecutivo · ${tuttiSerramenti.length} sched${tuttiSerramenti.length === 1 ? 'a inserita' : 'e inserite'}`;

  lista.innerHTML = '';
  $('#rilievo-vuoto').hidden = tuttiSerramenti.length !== 0;

  for (const w of filtrati) {
    const el = document.createElement('div');
    el.className = 'item-serramento';
    const etichettaPos = [w.codice, w.piano, w.interno].filter(Boolean).join(' · ');
    el.innerHTML = `
      ${w.foto_path ? `<img src="${w.foto_path}" alt="Foto serramento">` : '<div style="width:84px;height:84px;border-radius:8px;background:#eee;flex-shrink:0;"></div>'}
      <div class="info">
        <div class="titolo">${escapeHtml(w.tipo)} — ${escapeHtml(w.ambiente)}</div>
        <div class="misure">${[
          etichettaPos || null,
          w.larghezza_cm ? `${w.larghezza_cm}×${w.altezza_cm || '?'} cm` : null,
          w.cassonetto ? 'cassonetto' : null,
        ].filter(Boolean).join(' · ')}</div>
        ${w.stato ? `<span class="stato-badge">${escapeHtml(w.stato)}</span>` : ''}
        <div><button class="btn btn-danger" data-id="${w.id}">Elimina</button></div>
      </div>
    `;
    el.addEventListener('click', (ev) => {
      if (ev.target.closest('.btn-danger')) return;
      apriModaleSerramento(w);
    });
    el.querySelector('.btn-danger').addEventListener('click', async (ev) => {
      ev.stopPropagation();
      if (!confirm('Eliminare questo serramento?')) return;
      await api(`/serramenti/${w.id}`, { method: 'DELETE' });
      await ricaricaSopralluogoCorrente();
    });
    lista.appendChild(el);
  }
}

$('#btn-aggiungi-serramento').addEventListener('click', () => apriModaleSerramento());
$('#btn-inserisci-primo').addEventListener('click', () => apriModaleSerramento());
$('#btn-chiudi-modale-serramento').addEventListener('click', chiudiModaleSerramento);

function chiudiModaleSerramento() {
  $('#modale-serramento').hidden = true;
  serramentoInModifica = null;
}

function apriModaleSerramento(w) {
  serramentoInModifica = w ? w.id : null;
  const form = $('#form-serramento');
  form.reset();
  $('#anteprima-foto').hidden = true;
  $('#titolo-modale-serramento').textContent = w ? 'Modifica serramento' : 'Aggiungi serramento';
  if (w) {
    for (const campo of ['codice', 'piano', 'interno', 'ambiente', 'tipo', 'larghezza_cm', 'altezza_cm', 'spessore_muro_cm', 'tipo_apertura', 'materiale_attuale', 'stato', 'note']) {
      if (form.elements[campo] && w[campo] != null) form.elements[campo].value = w[campo];
    }
    form.elements['cassonetto'].checked = !!w.cassonetto;
    if (w.foto_path) {
      $('#anteprima-foto').src = w.foto_path;
      $('#anteprima-foto').hidden = false;
    }
  }
  $('#modale-serramento').hidden = false;
}

$('#form-serramento').addEventListener('submit', async (e) => {
  e.preventDefault();
  const form = e.target;
  const fd = new FormData(form);
  fd.set('cassonetto', form.elements['cassonetto'].checked ? 'true' : 'false');
  try {
    if (serramentoInModifica) {
      await api(`/serramenti/${serramentoInModifica}`, { method: 'PATCH', body: fd });
      mostraToast('Serramento aggiornato');
    } else {
      await api(`/sopralluoghi/${sopralluogoCorrenteId}/serramenti`, { method: 'POST', body: fd });
      mostraToast('Serramento aggiunto');
    }
    chiudiModaleSerramento();
    await ricaricaSopralluogoCorrente();
  } catch (err) {
    mostraToast(err.message);
  }
});

// ---------- Riepilogo ----------
function renderTabellaRiepilogo() {
  const corpo = $('#corpo-tabella-riepilogo');
  const elenco = (sopralluogoCorrente && sopralluogoCorrente.serramenti) || [];
  $('#riepilogo-vuoto').hidden = elenco.length !== 0;
  corpo.innerHTML = elenco.map(w => `
    <tr>
      <td>${w.foto_path ? `<img src="${w.foto_path}" alt="" style="width:44px;height:44px;object-fit:cover;border-radius:6px;">` : '—'}</td>
      <td>${escapeHtml(w.codice || '—')}</td>
      <td>${escapeHtml(w.ambiente)}</td>
      <td>${escapeHtml(w.tipo)}</td>
      <td>${w.larghezza_cm || '—'}×${w.altezza_cm || '—'}</td>
      <td>${w.cassonetto ? 'Sì' : 'No'}</td>
      <td>${escapeHtml(w.stato || '—')}</td>
    </tr>
  `).join('');
}

// ---------- Fotocamera (riusabile) ----------
const inputFoto = $('#input-foto');
const anteprimaFoto = $('#anteprima-foto');
const modaleCamera = $('#modale-camera');
const videoCamera = $('#video-camera');
const canvasCamera = $('#canvas-camera');
const statoCamera = $('#stato-camera');
const schermataIntroCamera = $('#schermata-intro-camera');
const vistaCamera = $('#vista-camera');
let streamCamera = null;
let richiestaCameraAttiva = false;
let callbackFotoCatturata = null;
let modalitaMultiScatto = false;

inputFoto.addEventListener('change', () => {
  if (inputFoto.files && inputFoto.files[0]) {
    anteprimaFoto.src = URL.createObjectURL(inputFoto.files[0]);
    anteprimaFoto.hidden = false;
  }
});

function resetModaleCamera() {
  schermataIntroCamera.hidden = false;
  vistaCamera.hidden = true;
  statoCamera.hidden = true;
}

// Apre il flusso fotocamera. callback riceve il File scattato.
// multiScatto: se true, dopo lo scatto la fotocamera resta aperta per scatti successivi.
function apriFotocamera(callback, { multiScatto = false } = {}) {
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
    mostraToast('Fotocamera non disponibile su questo browser.');
    return;
  }
  callbackFotoCatturata = callback;
  modalitaMultiScatto = multiScatto;
  if (permessoCameraConfermatoInSessione) {
    // Salta la schermata di accoglienza: il permesso è già stato dato in questa sessione.
    schermataIntroCamera.hidden = true;
    vistaCamera.hidden = false;
    modaleCamera.hidden = false;
    avviaStreamCamera();
  } else {
    resetModaleCamera();
    modaleCamera.hidden = false;
  }
}

$('#btn-scatta-foto').addEventListener('click', () => {
  apriFotocamera((file) => {
    const dt = new DataTransfer();
    dt.items.add(file);
    inputFoto.files = dt.files;
    anteprimaFoto.src = URL.createObjectURL(file);
    anteprimaFoto.hidden = false;
  });
});

function apriCameraPerSezione(sezioneId) {
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
    const input = document.querySelector(`.input-foto-sezione[data-sezione="${sezioneId}"]`);
    if (input) input.click();
    return;
  }
  apriFotocamera((file) => caricaFotoSezione(sezioneId, file), { multiScatto: true });
}

$('#btn-annulla-intro-camera').addEventListener('click', () => {
  modaleCamera.hidden = true;
});

$('#btn-attiva-camera').addEventListener('click', async () => {
  schermataIntroCamera.hidden = true;
  vistaCamera.hidden = false;
  await avviaStreamCamera();
});

async function avviaStreamCamera() {
  richiestaCameraAttiva = true;
  statoCamera.textContent = 'Richiesta autorizzazione fotocamera... conferma nel popup del browser.';
  statoCamera.hidden = false;
  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: 'environment' },
      audio: false,
    });
    if (!richiestaCameraAttiva) {
      stream.getTracks().forEach(t => t.stop());
      return;
    }
    streamCamera = stream;
    videoCamera.srcObject = streamCamera;
    statoCamera.hidden = true;
    permessoCameraConfermatoInSessione = true;
  } catch (e) {
    modaleCamera.hidden = true;
    if (e.name === 'NotAllowedError') {
      mostraToast('Permesso fotocamera negato. Controlla le impostazioni del sito nel browser.');
    } else {
      mostraToast('Impossibile accedere alla fotocamera: ' + e.message);
    }
  }
}

videoCamera.addEventListener('playing', () => { statoCamera.hidden = true; });

function chiudiCamera() {
  richiestaCameraAttiva = false;
  if (streamCamera) {
    streamCamera.getTracks().forEach(t => t.stop());
    streamCamera = null;
  }
  videoCamera.srcObject = null;
  modaleCamera.hidden = true;
  callbackFotoCatturata = null;
  resetModaleCamera();
}

$('#btn-annulla-camera').addEventListener('click', chiudiCamera);

$('#btn-cattura-camera').addEventListener('click', () => {
  const w = videoCamera.videoWidth;
  const h = videoCamera.videoHeight;
  if (!w || !h) return;
  canvasCamera.width = w;
  canvasCamera.height = h;
  canvasCamera.getContext('2d').drawImage(videoCamera, 0, 0, w, h);
  canvasCamera.toBlob((blob) => {
    const file = new File([blob], `foto_${Date.now()}.jpg`, { type: 'image/jpeg' });
    if (callbackFotoCatturata) callbackFotoCatturata(file);
    mostraToast('Foto acquisita');
    if (modalitaMultiScatto) {
      // Resta pronta per lo scatto successivo (una mano sola, niente riavvii).
    } else {
      chiudiCamera();
    }
  }, 'image/jpeg', 0.9);
});

// ---------- Avvio ----------
caricaElenco();
