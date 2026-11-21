const CACHE = "lifeboard-shell-v15";
const SHELL = ["/", "/app.css", "/app.js", "/sync.js", "/capture.js", "/task-groups.js", "/navigation.js", "/task-features.js", "/scheduling.js", "/manifest.webmanifest", "/icon-192.png", "/icon-512.png"];
self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", event => {
  event.waitUntil(Promise.all([caches.keys().then(keys => Promise.all(keys.filter(key => key !== CACHE).map(key => caches.delete(key)))), self.clients.claim()]));
});
self.addEventListener("fetch", event => {
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin || url.pathname.startsWith("/api/")) return;
  event.respondWith(fetch(event.request).then(response => {
    if (response.ok && event.request.method === "GET") {
      const copy = response.clone();
      caches.open(CACHE).then(cache => cache.put(event.request, copy));
    }
    return response;
  }).catch(async () => (await caches.match(event.request)) ||
    (event.request.mode === "navigate" ? (await caches.match("/")) || new Response("LifeBoard is offline. Reconnect once to finish setting up this device.", { status: 503 }) : new Response("Offline", { status: 503 }))));
});
