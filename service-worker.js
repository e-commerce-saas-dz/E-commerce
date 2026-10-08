/* =============================================================================
   SERVICE WORKER (PWA)
   - Met en cache UNIQUEMENT les fichiers statiques de l'application.
   - Ne touche JAMAIS aux requêtes Supabase (données, connexion, images) :
     aucune donnée d'une boutique ne peut être servie depuis le cache.
   - Pages HTML : réseau d'abord, cache si hors ligne.
   Changer CACHE_VERSION à chaque mise en ligne pour forcer la mise à jour.
   ============================================================================= */
const CACHE_VERSION = "v1";
const CACHE_NAME = "app-shell-" + CACHE_VERSION;

const APP_SHELL = [
  "./", "index.html", "login.html", "register.html", "pending.html",
  "dashboard.html", "admin.html", "shop.html", "manifest.json",
  "assets/app.css", "assets/app.js",
  "assets/icons/icon-192.png", "assets/icons/icon-512.png",
];

// Bibliothèques CDN (versions figées) autorisées en cache.
const CDN_ALLOWED = [
  "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.0/",
  "https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/",
];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  const sameOrigin = url.origin === self.location.origin;
  const isCdn = CDN_ALLOWED.some((p) => req.url.startsWith(p));
  if (!sameOrigin && !isCdn) return;   // Supabase et tout le reste : jamais intercepté

  // Pages : réseau d'abord (contenu toujours à jour), cache en secours.
  if (req.mode === "navigate") {
    event.respondWith(
      fetch(req)
        .then((res) => { const copy = res.clone(); caches.open(CACHE_NAME).then((c) => c.put(url.pathname, copy)); return res; })
        .catch(() => caches.match(url.pathname).then((r) => r || caches.match("index.html")))
    );
    return;
  }

  // Fichiers statiques : cache immédiat + mise à jour en arrière-plan.
  event.respondWith(
    caches.match(req).then((cached) => {
      const network = fetch(req).then((res) => {
        if (res && res.ok) { const copy = res.clone(); caches.open(CACHE_NAME).then((c) => c.put(req, copy)); }
        return res;
      }).catch(() => cached);
      return cached || network;
    })
  );
});
