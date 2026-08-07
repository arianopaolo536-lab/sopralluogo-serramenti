// ---------- Stato applicazione ----------
let sopralluogoCorrenteId = null;

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
      el.innerHTML = `
        <div class="riga-titolo">
          <span>${escapeHtml(s.cliente_nome)}</span>
          <span>${formattaData(s.data_sopralluogo)}</span>
        </div>
        <div class="meta">${escapeHtml(s.indirizzo)} · ${s.num_serramenti} serrament${s.num_serramenti === 1 ? 'o' : 'i'}</div>
      `;
      el.addEventListener('click', () => apriDettaglio(s.id));
      lista.appendChild(el);
    }
  } catch (e) {
    lista.innerHTML = `<p class="vuoto">Errore nel caricamento: ${escapeHtml(e.message)}</p>`;
  }
}

function escapeHtml(str = '') {
  return String(str).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c]));
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
  mostraVista('view-elenco');
  caricaElenco();
});

async function apriDettaglio(id) {
  sopralluogoCorrenteId = id;
  mostraVista('view-dettaglio');
  await caricaDettaglio();
}

async function caricaDettaglio() {
  const info = $('#dettaglio-info');
  const lista = $('#lista-serramenti');
  info.innerHTML = 'Caricamento...';
  try {
    const s = await api(`/sopralluoghi/${sopralluogoCorrenteId}`);
    info.innerHTML = `
      <div class="riga-titolo"><span>${escapeHtml(s.cliente_nome)}</span><span>${formattaData(s.data_sopralluogo)}</span></div>
      <div class="meta">${escapeHtml(s.indirizzo)}</div>
      ${s.telefono ? `<div class="meta">📞 ${escapeHtml(s.telefono)}</div>` : ''}
      ${s.email ? `<div class="meta">✉️ ${escapeHtml(s.email)}</div>` : ''}
      ${s.note ? `<div class="meta">📝 ${escapeHtml(s.note)}</div>` : ''}
    `;
    lista.innerHTML = '';
    if (s.serramenti.length === 0) {
      lista.innerHTML = '<p class="vuoto">Nessun serramento ancora inserito.</p>';
    }
    for (const w of s.serramenti) {
      const el = document.createElement('div');
      el.className = 'item-serramento';
      el.innerHTML = `
        ${w.foto_path ? `<img src="${w.foto_path}" alt="Foto serramento">` : '<div style="width:84px;height:84px;border-radius:8px;background:#eee;flex-shrink:0;"></div>'}
        <div class="info">
          <div class="titolo">${escapeHtml(w.tipo)} — ${escapeHtml(w.ambiente)}</div>
          <div class="misure">${[
            w.larghezza_cm ? `${w.larghezza_cm}×${w.altezza_cm || '?'} cm` : null,
            w.spessore_muro_cm ? `muro ${w.spessore_muro_cm} cm` : null,
            w.tipo_apertura,
            w.materiale_attuale,
          ].filter(Boolean).join(' · ')}</div>
          ${w.stato ? `<span class="stato-badge">${escapeHtml(w.stato)}</span>` : ''}
          ${w.note ? `<div class="misure">${escapeHtml(w.note)}</div>` : ''}
          <div><button class="btn btn-danger" data-id="${w.id}">Elimina</button></div>
        </div>
      `;
      el.querySelector('.btn-danger').addEventListener('click', async (ev) => {
        ev.stopPropagation();
        if (!confirm('Eliminare questo serramento?')) return;
        await api(`/serramenti/${w.id}`, { method: 'DELETE' });
        caricaDettaglio();
      });
      lista.appendChild(el);
    }
  } catch (e) {
    info.innerHTML = `<p class="vuoto">Errore: ${escapeHtml(e.message)}</p>`;
  }
}

$('#form-serramento').addEventListener('submit', async (e) => {
  e.preventDefault();
  const fd = new FormData(e.target);
  try {
    await api(`/sopralluoghi/${sopralluogoCorrenteId}/serramenti`, {
      method: 'POST',
      body: fd,
    });
    mostraToast('Serramento aggiunto');
    e.target.reset();
    $('#anteprima-foto').hidden = true;
    caricaDettaglio();
  } catch (e) {
    mostraToast(e.message);
  }
});

// ---------- Dettatura vocale ----------
const SpeechRecognitionCtor = window.SpeechRecognition || window.webkitSpeechRecognition;

function estraiNumero(testo) {
  const m = testo.replace(',', '.').match(/-?\d+(\.\d+)?/);
  return m ? m[0] : testo;
}

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

  if (!SpeechRecognitionCtor) {
    btn.disabled = true;
    btn.title = 'Dettatura non supportata da questo browser';
    return;
  }

  let riconoscimento = null;
  let inAscolto = false;

  btn.addEventListener('click', () => {
    if (inAscolto) {
      riconoscimento && riconoscimento.stop();
      return;
    }
    riconoscimento = new SpeechRecognitionCtor();
    riconoscimento.lang = 'it-IT';
    riconoscimento.interimResults = false;
    riconoscimento.maxAlternatives = 1;

    riconoscimento.onstart = () => { inAscolto = true; btn.classList.add('ascolto'); };
    riconoscimento.onend = () => { inAscolto = false; btn.classList.remove('ascolto'); };
    riconoscimento.onerror = (ev) => {
      inAscolto = false;
      btn.classList.remove('ascolto');
      if (ev.error !== 'aborted' && ev.error !== 'no-speech') {
        mostraToast('Dettatura non riuscita: ' + ev.error);
      }
    };
    riconoscimento.onresult = (ev) => {
      const testo = ev.results[0][0].transcript.trim();
      const valore = campo.type === 'number' ? estraiNumero(testo) : testo;
      if (campo.tagName === 'SELECT') {
        const opz = [...campo.options].find(o => o.textContent.toLowerCase().includes(valore.toLowerCase()));
        if (opz) campo.value = opz.value;
      } else {
        campo.value = valore;
      }
      campo.dispatchEvent(new Event('input', { bubbles: true }));
    };
    riconoscimento.start();
  });
}

function abilitaVoceSuForm(form) {
  if (!SpeechRecognitionCtor) {
    $('#avviso-voce').hidden = false;
  }
  $all('input[type=text], input[type=tel], input[type=email], input[type=number], textarea, select', form)
    .forEach(abilitaVoceSuCampo);
}

abilitaVoceSuForm($('#form-nuovo'));
abilitaVoceSuForm($('#form-serramento'));

// ---------- Fotocamera ----------
const inputFoto = $('#input-foto');
const anteprimaFoto = $('#anteprima-foto');
const modaleCamera = $('#modale-camera');
const videoCamera = $('#video-camera');
const canvasCamera = $('#canvas-camera');
let streamCamera = null;

inputFoto.addEventListener('change', () => {
  if (inputFoto.files && inputFoto.files[0]) {
    anteprimaFoto.src = URL.createObjectURL(inputFoto.files[0]);
    anteprimaFoto.hidden = false;
  }
});

$('#btn-scatta-foto').addEventListener('click', async () => {
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
    mostraToast('Fotocamera non disponibile: usa il pulsante di selezione file.');
    inputFoto.click();
    return;
  }
  try {
    streamCamera = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: 'environment' },
      audio: false,
    });
    videoCamera.srcObject = streamCamera;
    modaleCamera.hidden = false;
  } catch (e) {
    mostraToast('Impossibile accedere alla fotocamera: ' + e.message);
  }
});

function chiudiCamera() {
  if (streamCamera) {
    streamCamera.getTracks().forEach(t => t.stop());
    streamCamera = null;
  }
  modaleCamera.hidden = true;
}

$('#btn-annulla-camera').addEventListener('click', chiudiCamera);

$('#btn-cattura-camera').addEventListener('click', () => {
  const w = videoCamera.videoWidth;
  const h = videoCamera.videoHeight;
  canvasCamera.width = w;
  canvasCamera.height = h;
  canvasCamera.getContext('2d').drawImage(videoCamera, 0, 0, w, h);
  canvasCamera.toBlob((blob) => {
    const file = new File([blob], `foto_${Date.now()}.jpg`, { type: 'image/jpeg' });
    const dt = new DataTransfer();
    dt.items.add(file);
    inputFoto.files = dt.files;
    anteprimaFoto.src = URL.createObjectURL(file);
    anteprimaFoto.hidden = false;
    chiudiCamera();
    mostraToast('Foto acquisita');
  }, 'image/jpeg', 0.9);
});

// ---------- Avvio ----------
caricaElenco();
