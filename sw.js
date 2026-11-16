/* CRM Mannare · service worker
   - Páginas (index.html): rede primeiro, cópia salva só como reserva sem internet.
   - Arquivos do app (ícones, manifest, biblioteca do Supabase, fontes): cache.
   - Dados (Supabase, Google): nunca passam pelo cache.
   - Notificações: recebe o push do Supabase e abre o CRM no item certo.
   Ao publicar uma versão nova do CRM, aumente o número de VERSAO. */
const VERSAO = 'mannare-v4';
const ESSENCIAIS = ['./', './index.html', './manifest.webmanifest', './icons/icon-192.png', './icons/icon-512.png', './icons/apple-touch-icon.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSAO).then(c => c.addAll(ESSENCIAIS)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== VERSAO).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

const NUNCA_CACHE = /supabase\.co|googleapis\.com\/(calendar|oauth)|accounts\.google\.com|script\.google\.com/;
const CACHE_LONGO = /cdn\.jsdelivr\.net|fonts\.googleapis\.com|fonts\.gstatic\.com/;

self.addEventListener('fetch', e => {
  const req = e.request; if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (NUNCA_CACHE.test(url.href)) return;                       // dados e login: direto na rede

  if (req.mode === 'navigate') {                                // página: rede primeiro
    e.respondWith(fetch(req).then(r => { const cp = r.clone(); caches.open(VERSAO).then(c => c.put('./index.html', cp)); return r; })
      .catch(() => caches.match('./index.html')));
    return;
  }
  if (url.origin === location.origin && /config\.js$/.test(url.pathname)) {   // config: rede primeiro
    e.respondWith(fetch(req).then(r => { const cp = r.clone(); caches.open(VERSAO).then(c => c.put(req, cp)); return r; }).catch(() => caches.match(req)));
    return;
  }
  if (url.origin === location.origin || CACHE_LONGO.test(url.href)) {        // estáticos: cache e atualiza por trás
    e.respondWith(caches.match(req).then(hit => {
      const rede = fetch(req).then(r => { if (r.ok || r.type === 'opaque') { const cp = r.clone(); caches.open(VERSAO).then(c => c.put(req, cp)); } return r; }).catch(() => hit);
      return hit || rede;
    }));
  }
});

/* ---------- Notificações (Web Push) ---------- */
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = {body: e.data ? e.data.text() : ''}; }
  const base = self.registration.scope;
  // sempre mostra (o navegador exige um aviso visível para cada push)
  e.waitUntil(Promise.resolve().then(() => {
    return self.registration.showNotification(d.title || 'CRM Mannare', {
      body: d.body || 'Você tem uma novidade no CRM.',
      icon: 'icons/icon-192.png', badge: 'icons/badge-96.png',
      tag: d.tag || undefined, renotify: false, timestamp: d.em ? Date.parse(d.em) : Date.now(),
      data: {url: base + (d.id ? '?n=' + encodeURIComponent(d.id) : ''), procId: d.procId || '', taskId: d.taskId || ''}
    });
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const o = e.notification.data || {}, url = o.url || self.registration.scope;
  e.waitUntil(self.clients.matchAll({type: 'window', includeUncontrolled: true}).then(cs => {
    const c = cs.find(x => x.url.startsWith(self.registration.scope));
    if (c) { c.postMessage({tipo: 'pm-abrir', procId: o.procId, taskId: o.taskId}); return c.focus(); }
    return self.clients.openWindow(url);
  }));
});
