// Кэш для статических файлов, чтобы приложение открывалось быстрее.
const CACHE = "obd-v1";
const ASSETS = [
  "/",
  "/static/app.js",
  "/static/style.css",
  "/static/manifest.json",
  "/static/icon-192.png",
  "/static/icon-512.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))
        )
      )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);

  // API-запросы всегда идут в сеть — их не кэшируем
  if (url.pathname.startsWith("/api/")) {
    return;
  }

  // Сначала пробуем сеть, при обрыве отдаём кэш
  event.respondWith(
    fetch(event.request).catch(() => caches.match(event.request))
  );
});
