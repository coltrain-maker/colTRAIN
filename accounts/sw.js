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

// Encrypted Web Push contains only an unread count. No tokens or private message text.
self.addEventListener('push',event=>{
 event.waitUntil((async()=>{
  let data={};try{data=event.data?.json()||{};}catch{}
  const count=Number.isSafeInteger(data.count)&&data.count>0?Math.min(data.count,9999):1;
  try{await self.navigator.setAppBadge?.(count);}catch{}
  await self.registration.showNotification('colTRAIN',{
   body:`You have ${count} unread update${count===1?'':'s'}. Sign in to view them.`,
   icon:'/accounts/icons/icon-192.png',badge:'/accounts/icons/icon-192.png',tag:'coltrain-unread',
   data:{url:'/accounts/?notifications=1'},renotify:false
  });
 })());
});
self.addEventListener('notificationclick',event=>{
 event.notification.close();
 event.waitUntil((async()=>{
  const url=new URL('/accounts/?notifications=1',self.location.origin).href;
  const windows=await self.clients.matchAll({type:'window',includeUncontrolled:true});
  const existing=windows.find(c=>new URL(c.url).origin===self.location.origin&&new URL(c.url).pathname.startsWith('/accounts/'));
  // Navigate to a fixed same-origin inbox; authentication and recipient checks remain in-app.
  if(existing){await existing.navigate(url);await existing.focus();}else await self.clients.openWindow(url);
 })());
});

self.addEventListener('message',event=>{
 if(event.data?.type!=='coltrain-signout')return;
 event.waitUntil((async()=>{
  try{await self.navigator.clearAppBadge?.();}catch{}
  const alerts=await self.registration.getNotifications();alerts.forEach(alert=>alert.close());
  const subscription=await self.registration.pushManager.getSubscription();
  if(subscription)await subscription.unsubscribe();
 })());
});
