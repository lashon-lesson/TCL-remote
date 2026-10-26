// סימן — service worker: works offline, picks up new versions automatically
const CACHE = 'siman-v66';
const ASSETS = ['./', './index.html', './manifest.webmanifest', './pdf.min.js', './pdf.worker.min.js',
  './pdf-lib.min.js', './fontkit.umd.min.js', './icon-192.png', './icon-512.png', './icon-maskable-512.png', './jszip.min.js', './pptxgen.min.js', './office.js', './office-edit.js', './word-editor.js', './excel-editor.js', './docx-preview.min.js', './html2canvas.min.js', './xlsx.mini.min.js', './font-secular-he.woff2', './font-secular-lat.woff2', './send.js', './siman-plus.js', './ppt-editor.js', './office-ai.js', './office-translate.js', './a11y.js', './admin-panel.js', './font-rubik-400.ttf', './font-rubik-700.ttf', './siman-phone.css', './siman-phone.js', './siman-voice.js', './siman-asr-worker.js', './transformers.min.js', './siman-back.js'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  // only the app's own old versions are removed: the transcription engine (transformers-cache, ~165MB) stays
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => /^siman-v\d+$/.test(k) && k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const req = e.request;
  // a file shared to סימן from another app (Android share sheet: WhatsApp voice messages, call recordings, PDFs):
  // it is kept for a moment in a cache and the app opens and picks it up (siman-voice.js)
  if (req.method === 'POST' && /\/share-target\/?$/.test(new URL(req.url).pathname)) {
    e.respondWith((async () => {
      try {
        const form = await req.formData();
        const files = form.getAll('files').filter(f => f && typeof f === 'object' && f.size);
        const c = await caches.open('siman-share');
        let n = 0;
        for (const f of files) {
          await c.put('./__shared/' + Date.now() + '-' + (n++), new Response(f, { headers: { 'content-type': f.type || 'application/octet-stream', 'x-name': encodeURIComponent(f.name || 'קובץ') } }));
        }
      } catch (_) {}
      return Response.redirect('./?voice=shared', 303);
    })());
    return;
  }
  if (req.method !== 'GET' || new URL(req.url).origin !== location.origin) return; // APIs go straight to the network
  const path = new URL(req.url).pathname;
  const isPage = req.mode === 'navigate' || /\/(index\.html)?$/.test(path);
  // the app's own code: always the newest version when online, so an upload shows up on the next refresh
  const isAppCode = /\/(office|office-edit|word-editor|excel-editor|siman-register|send|siman-plus|ppt-editor|a11y|office-ai|office-translate|siman-voice|siman-asr-worker)\.js$/.test(path) || /\/siman-phone\.(css|js)$/.test(path);
  if (isAppCode) {
    e.respondWith(fetch(req, { cache: 'no-cache' }).then(r => { if (r.ok) { const copy = r.clone(); caches.open(CACHE).then(c => c.put(req, copy)); } return r; })
      .catch(() => caches.match(req)));
    return;
  }
  if (isPage) {
    // newest page when online, cached page when offline. Only the app itself is kept as the app page:
    // other pages (like sign.html, opened from a link) are kept under their own address
    const isApp = /\/(index\.html)?$/.test(path);
    e.respondWith(fetch(req).then(r => { if (r.ok) { const copy = r.clone(); caches.open(CACHE).then(c => c.put(isApp ? './index.html' : req, copy)); } return r; })
      .catch(() => isApp ? caches.match('./index.html') : caches.match(req)));
    return;
  }
  e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(r => {
    if (r.ok) { const copy = r.clone(); caches.open(CACHE).then(c => c.put(req, copy)); }
    return r;
  })));
});
