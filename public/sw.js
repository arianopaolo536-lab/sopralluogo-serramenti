// Service worker per uso offline-first.
// Incrementare CACHE_VERSION ad ogni deploy che tocca gli asset statici,
// così i client scaricano la nuova versione invece di restare bloccati sulla cache vecchia.
const CACHE_VERSION = 'v3';
const CACHE_SHELL = `sopralluogo-shell-${CACHE_VERSION}`;
const CACHE_API = `sopralluogo-api-${CACHE_VERSION}`;

const ASSET_SHELL = [
  '/',
  '/index.html',
  '/style.css',
  '/app.js',
  '/manifest.json',
  '/assets/logo-qid.png',
  '/assets/icon-192.png',
  '/assets/icon-512.png',
  '/assets/sfondo-serramenti.jpg',
  '/assets/finestra-dettaglio.jpg',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_SHELL).then((cache) => cache.addAll(ASSET_SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((nomi) =>
      Promise.all(
        nomi
          .filter((n) => n !== CACHE_SHELL && n !== CACHE_API)
          .map((n) => caches.delete(n))
      )
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  const url = new URL(req.url);

  // Solo stesso dominio: non intercettare richieste esterne.
  if (url.origin !== self.location.origin) return;

  // Le scritture (POST/PATCH/PUT/DELETE) non vengono mai gestite dal service worker:
  // la coda offline per queste richieste è gestita lato app.js (IndexedDB), non qui,
  // perché deve poter mostrare stato/UI e gestire FormData con foto in modo affidabile.
  if (req.method !== 'GET') return;

  // Chiamate API: network-first, con fallback alla cache se offline.
  if (url.pathname.startsWith('/api/')) {
    event.respondWith(
      fetch(req)
        .then((res) => {
          const copia = res.clone();
          caches.open(CACHE_API).then((cache) => cache.put(req, copia));
          return res;
        })
        .catch(() => caches.match(req))
    );
    return;
  }

  // Foto caricate (/uploads/...) e asset statici: cache-first, poi rete.
  event.respondWith(
    caches.match(req).then((cached) => {
      if (cached) return cached;
      return fetch(req).then((res) => {
        if (res.ok) {
          const copia = res.clone();
          caches.open(CACHE_SHELL).then((cache) => cache.put(req, copia));
        }
        return res;
      }).catch(() => {
        // Ultima risorsa per la navigazione offline senza cache: mostra la shell.
        if (req.mode === 'navigate') return caches.match('/index.html');
        return new Response('', { status: 504 });
      });
    })
  );
});
