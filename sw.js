// Zoomies service worker: app shell works offline; fonts are cached the first time they load.
const CACHE = 'zoomies-v2';
const SHELL = [
  './', 'index.html', 'manifest.webmanifest', 'products.json',
  'icons/icon-192.png', 'icons/icon-512.png', 'icons/icon-180.png',
  'pets.jpg', 'home-dog.webp', 'home-cat.webp',
  'dog.png', 'cat2.webp', 'bird.webp', 'fish.webp', 'rabbit.webp', 'hamster.png'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  const cacheable = url.origin === location.origin || url.host === 'fonts.googleapis.com' || url.host === 'fonts.gstatic.com';
  if (!cacheable) return;
  // product list and photos: network first so edits on GitHub show up, cache as offline fallback
  if (url.origin === location.origin && (url.pathname.endsWith('/products.json') || url.pathname.includes('/photos/'))) {
    e.respondWith(fetch(req).then(r => { if (r.ok) { const copy = r.clone(); caches.open(CACHE).then(c => c.put(req, copy)); } return r; })
      .catch(() => caches.match(req, { ignoreSearch:true })));
    return;
  }
  // pages: network first so updates show up, cache as fallback offline
  if (req.mode === 'navigate') {
    e.respondWith(fetch(req).then(r => { caches.open(CACHE).then(c => c.put('index.html', r.clone())); return r; })
      .catch(() => caches.match('index.html')));
    return;
  }
  e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(r => {
    if (r.ok || r.type === 'opaque') { const copy = r.clone(); caches.open(CACHE).then(c => c.put(req, copy)); }
    return r;
  })));
});
