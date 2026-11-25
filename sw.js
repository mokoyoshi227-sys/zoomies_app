// Zoomies service worker: app shell works offline; fonts are cached the first time they load.
const CACHE = 'zoomies-v8';
const SHELL = [
  './', 'index.html', 'manifest.webmanifest', 'products.json', 'privacy.html',
  'icons/icon-192.png', 'icons/icon-512.png', 'icons/icon-180.png',
  'welcome-dog.jpg', 'home-dog.webp', 'home-cat.webp',
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
  // the admin panel is never cached: always the live page, and it must never replace the app's offline copy
  if (url.origin === location.origin && url.pathname.includes('/admin/')) return;
  // also: the pinned Supabase library and pet / catalog photos on Supabase (they never change at the same address).
  // Supabase API and login calls (/rest, /auth, private files) are never cached.
  const cacheable = url.origin === location.origin || url.host === 'fonts.googleapis.com' || url.host === 'fonts.gstatic.com'
    || (url.host === 'cdn.jsdelivr.net' && url.pathname.startsWith('/npm/@supabase/supabase-js@'))
    || (url.host === 'cdnjs.cloudflare.com' && url.pathname.startsWith('/ajax/libs/qrcode-generator/'))
    || (url.host.endsWith('.supabase.co') && /^\/storage\/v1\/object\/public\/(pet-photos|catalog)\//.test(url.pathname));
  if (!cacheable) return;
  // server pet photos: always fetched and stored in CORS mode, so the same cached copy serves both <img> tags
  // and the share-card canvas (an opaque copy would break the canvas)
  if (url.host.endsWith('.supabase.co')) {
    e.respondWith(caches.match(url.href).then(hit => hit || fetch(url.href, { mode:'cors', credentials:'omit' }).then(r => {
      if (r.ok) { const copy = r.clone(); caches.open(CACHE).then(c => c.put(url.href, copy)); }
      return r;
    })));
    return;
  }
  // product list, photos and the privacy policy: network first so edits on GitHub show up, cache as offline fallback
  if (url.origin === location.origin && (url.pathname.endsWith('/products.json') || url.pathname.endsWith('/privacy.html') || url.pathname.includes('/photos/'))) {
    e.respondWith(fetch(req).then(r => { if (r.ok) { const copy = r.clone(); caches.open(CACHE).then(c => c.put(req, copy)); } return r; })
      .catch(() => caches.match(req, { ignoreSearch:true })));
    return;
  }
  // pages: network first so updates show up, cache as fallback offline
  // only the app itself is kept as the offline page; other pages (privacy.html…) are cached under their own address
  if (req.mode === 'navigate') {
    const isApp = /\/(index\.html)?$/.test(url.pathname);
    e.respondWith(fetch(req).then(r => {
      if (r.ok) { const copy = r.clone(); caches.open(CACHE).then(c => c.put(isApp ? 'index.html' : req, copy)); }
      return r;
    }).catch(() => caches.match(isApp ? 'index.html' : req)));
    return;
  }
  e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(r => {
    if (r.ok || r.type === 'opaque') { const copy = r.clone(); caches.open(CACHE).then(c => c.put(req, copy)); }
    return r;
  })));
});
