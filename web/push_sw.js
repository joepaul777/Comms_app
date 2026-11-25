// Comms Web notifications while Comms is closed (including iPhones with Comms on the
// Home Screen). The Comms server sends a small encrypted note: who wrote, or who is
// calling. Messages themselves are end-to-end encrypted and only unlocked in the app.

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));

// An iPhone or Mac must show something for every push it gets, or it stops them.
const mustAlwaysShow = /iPhone|iPad|Macintosh/.test(self.navigator.userAgent) && !/Chrome|Chromium|Edg|Firefox/.test(self.navigator.userAgent);

self.addEventListener('push', event => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (_) {}
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const lookingAtComms = windows.some(w => w.focused && w.visibilityState === 'visible');
    // The open app already rings and shows its own notifications.
    if (lookingAtComms && !mustAlwaysShow) return;
    const isCall = data.type === 'call';
    await self.registration.showNotification(data.title || 'Comms', {
      body: data.body || 'New message',
      tag: data.tag || undefined,
      renotify: Boolean(data.tag),
      icon: 'icons/Icon-192.png',
      badge: 'icons/Icon-192.png',
      requireInteraction: isCall,
      vibrate: isCall ? [400, 200, 400, 200, 400] : [120],
      data: { open: data.type === 'missed' ? 'calls|' + (data.id || '') : (data.type || 'chat') + '|' + (data.id || '') },
    });
  })());
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const open = (event.notification.data && event.notification.data.open) || '';
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of windows) {
      if ('focus' in w) {
        await w.focus();
        w.postMessage({ commsOpen: open });
        return;
      }
    }
    await self.clients.openWindow('./?open=' + encodeURIComponent(open));
  })());
});
