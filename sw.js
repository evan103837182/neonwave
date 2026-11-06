// NEONWAVE service worker: keeps the app shell cached so it opens instantly.
const V = 'neonwave-v1';
const SHELL = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './icon-512.png', './apple-touch-icon.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(V).then(c => c.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request, u = new URL(req.url);
  if (req.method !== 'GET' || u.origin !== location.origin) return; // never touch Spotify API calls
  if (req.mode === 'navigate') {
    // network first so updates show up, cached copy when offline
    e.respondWith(
      fetch(req).then(r => {
        const cp = r.clone();
        caches.open(V).then(c => c.put('./index.html', cp));
        return r;
      }).catch(() => caches.match('./index.html'))
    );
    return;
  }
  e.respondWith(caches.match(req, { ignoreSearch: true }).then(h => h || fetch(req)));
});
