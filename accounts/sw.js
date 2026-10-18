// Online app: never store accounts, courses, tokens, API responses, or photos in CacheStorage.
// A public offline page replaces failed navigations; it contains no signed-in content.
const offline = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#214bd7"><title>colTRAIN · You're offline</title><style>body{margin:0;padding:32px;background:#f6f8fc;color:#182744;font-family:Arial,Helvetica,sans-serif}main{max-width:440px;margin:12vh auto;padding:28px;border:1px solid #e3e9f2;border-radius:18px;background:white}h1{font-size:28px}p{line-height:1.8}a{display:inline-block;background:#214bd7;color:white;border-radius:9px;padding:14px 20px;text-decoration:none}</style></head><body><main><p><strong>colTRAIN</strong></p><h1>You're offline.</h1><p>Connect to the internet to open your courses and team updates.</p><a href="/accounts/">Try again</a></main></body></html>`;
self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (event.request.mode !== 'navigate' || url.origin !== self.location.origin || !url.pathname.startsWith('/accounts/')) return;
  event.respondWith(fetch(new Request(event.request, {cache:'no-store'})).catch(() => new Response(offline, {
    status:503, headers:{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}
  })));
});
