/* SEXY ONE M11 offline shell.
 *
 * The cache is intentionally small: it contains the executable shell and both
 * text languages, but not the 108 manual scans. Seen scans enter the runtime
 * cache on demand. Every core request is network-first so a normal online load
 * cannot combine an old worker's app.wasm with a new deployment's bundles;
 * the cache is strictly the connection-failure fallback.
 */
const CACHE_VERSION = "m13-v1";
const CORE_CACHE = `sxc1-core-${CACHE_VERSION}`;
const RUNTIME_CACHE = `sxc1-runtime-${CACHE_VERSION}`;
const CORE_RELATIVE_URLS = [
  "./",
  "./index.html",
  "./index.js",
  "./sample-lab.js",
  "./app.wasm",
  "./ghc_wasm_jsffi.js",
  "./manifest.webmanifest",
  "./app-icon.svg",
  "./qr-phone.svg",
  "./vendor/browser_wasi_shim/index.js",
  "./vendor/browser_wasi_shim/fs_mem.js",
  "./vendor/browser_wasi_shim/fs_opfs.js",
  "./vendor/browser_wasi_shim/wasi.js",
  "./vendor/browser_wasi_shim/strace.js",
  "./vendor/browser_wasi_shim/wasi_defs.js",
  "./vendor/browser_wasi_shim/fd.js",
  "./vendor/browser_wasi_shim/debug.js",
  "./content/content.en.txt",
  "./content/content.ja.txt",
  "./content/manuals.en.txt",
  "./content/manuals.ja.txt"
];

const scopedUrl = (relative) => new URL(relative, self.registration.scope).href;

self.addEventListener("install", (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CORE_CACHE);
    await cache.addAll(CORE_RELATIVE_URLS.map(scopedUrl));
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names
      .filter((name) => name.startsWith("sxc1-") && name !== CORE_CACHE && name !== RUNTIME_CACHE)
      .map((name) => caches.delete(name)));
    await self.clients.claim();
  })());
});

async function cachedFallback(request, fallbackRelative) {
  const direct = await caches.match(request);
  if (direct) return direct;
  if (fallbackRelative) return caches.match(scopedUrl(fallbackRelative));
  return undefined;
}

async function networkFirst(request, cacheName, fallbackRelative) {
  try {
    const response = await fetch(request);
    if (response && response.ok) {
      const cache = await caches.open(cacheName);
      await cache.put(request, response.clone());
    }
    return response;
  } catch (_) {
    const cached = await cachedFallback(request, fallbackRelative);
    if (cached) return cached;
    throw _;
  }
}

async function cacheFirst(request) {
  const cached = await caches.match(request);
  if (cached) return cached;
  const response = await fetch(request);
  if (response && response.ok) {
    const cache = await caches.open(RUNTIME_CACHE);
    await cache.put(request, response.clone());
  }
  return response;
}

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  if (request.mode === "navigate") {
    event.respondWith(networkFirst(request, CORE_CACHE, "./index.html"));
    return;
  }
  if (/\/pages\/[^/]+\/page-\d+\.webp$/.test(url.pathname)) {
    event.respondWith(cacheFirst(request));
    return;
  }
  event.respondWith(networkFirst(request, CORE_CACHE));
});

self.addEventListener("message", (event) => {
  if (event.data === "SXC1_STATUS" && event.source) {
    event.source.postMessage({ type: "SXC1_STATUS", cacheVersion: CACHE_VERSION });
  }
});
