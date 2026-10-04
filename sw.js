const CACHE_NAME = 'agora-capital-shell-v29';
const SDK_CACHE = 'agora-supabase-sdk-v1';
const APP_SHELL = [
  '/602-bank/',
  '/602-bank/index.html',
  '/602-bank/manifest.json',
  '/602-bank/icon.svg'
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(
        keys.filter(key => key !== CACHE_NAME)
            .map(key => caches.delete(key))
      )
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);

  // Supabase SDK는 처음 온라인으로 불러온 뒤 PWA에서도 재사용할 수 있게 캐시합니다.
  if (
    url.hostname === 'cdn.jsdelivr.net' &&
    url.pathname.includes('/@supabase/supabase-js/')
  ) {
    event.respondWith(
      caches.open(SDK_CACHE).then(async cache => {
        try {
          const response = await fetch(event.request);
          if (response && response.ok) cache.put(event.request, response.clone());
          return response;
        } catch (e) {
          const cached = await cache.match(event.request);
          if (cached) return cached;
          throw e;
        }
      })
    );
    return;
  }

  if (
    url.hostname === 'unpkg.com' &&
    url.pathname.includes('/@supabase/supabase-js')
  ) {
    event.respondWith(
      caches.open(SDK_CACHE).then(async cache => {
        try {
          const response = await fetch(event.request);
          if (response && response.ok) cache.put(event.request, response.clone());
          return response;
        } catch (e) {
          const cached = await cache.match(event.request);
          if (cached) return cached;
          throw e;
        }
      })
    );
    return;
  }

  // 아고라 페이지는 최신 버전을 먼저 가져오고, 네트워크가 끊겼을 때만 캐시를 사용합니다.
  if (url.origin !== self.location.origin) return;

  event.respondWith(
    fetch(event.request).catch(() => caches.match(event.request))
  );
});