// Comms notification server (Cloudflare Worker).
//
// The app never holds any Google admin key. Instead it calls this worker with the
// signed-in user's Firebase ID token. The worker checks the token, reads what it needs
// from Firestore with its own service account, and sends the push notification.
//
// Secrets (set with `wrangler secret put NAME`):
//   FIREBASE_SERVICE_ACCOUNT  the service account JSON from Firebase console
//   METERED_USERNAME / METERED_PASSWORD  Metered TURN credential (for call relays)
//   METERED_API_KEY           alternative: Metered credentials API key
//   ADMIN_SECRET              protects the one-off /broadcast endpoint
// Vars (wrangler.toml): PROJECT_ID, METERED_DOMAIN

import { decodeDocument, verifyIdToken, serviceAccountToken } from './google.js';
import { sendWebPush } from './webpush.js';

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

// Comms in a browser lives here; only these pages may call the worker from a browser.
const WEB_ORIGINS = ['https://jp-comms.web.app', 'https://jp-comms.firebaseapp.com'];
const LOCAL_ORIGIN = /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/;

function corsHeaders(request) {
  const origin = request.headers.get('Origin') || '';
  if (!WEB_ORIGINS.includes(origin) && !LOCAL_ORIGIN.test(origin)) return null;
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Max-Age': '86400',
    Vary: 'Origin',
  };
}

export default {
  async fetch(request, env) {
    const cors = corsHeaders(request);
    if (request.method === 'OPTIONS') return new Response(null, { status: cors ? 204 : 403, headers: cors || {} });
    const res = await handle(request, env);
    if (!cors) return res;
    const out = new Response(res.body, res);
    for (const [k, v] of Object.entries(cors)) out.headers.set(k, v);
    return out;
  },
};

async function handle(request, env) {
    const url = new URL(request.url);
    try {
      if (request.method === 'POST' && url.pathname === '/broadcast') return await broadcast(request, env);
      if (request.method === 'GET' && url.pathname === '/version') return latestVersion(env);

      const uid = await authenticate(request, env);
      if (!uid) return json({ error: 'unauthorized' }, 401);

      if (request.method === 'GET' && url.pathname === '/ice') return await iceServers(env);
      if (request.method === 'GET' && url.pathname === '/media') return await media(url.searchParams.get('u'));
      if (request.method !== 'POST') return json({ error: 'not found' }, 404);

      const body = await request.json().catch(() => ({}));
      switch (url.pathname) {
        case '/notify/message':
          return await notifyMessage(env, uid, body);
        case '/notify/call':
          return await notifyCall(env, uid, body);
        case '/notify/call-update':
          return await notifyCallUpdate(env, uid, body);
        default:
          return json({ error: 'not found' }, 404);
      }
    } catch (error) {
      console.error(error.stack || error);
      return json({ error: 'server error' }, 500);
    }
}

// ---------------------------------------------------------------------------
// Media for the browser version
// ---------------------------------------------------------------------------

// tmpfiles.org lets web pages upload but not download, so Comms in a browser fetches
// photos, videos and voice notes through here. They are end-to-end encrypted, so
// this only ever passes along scrambled bytes. Only tmpfiles links are fetched, and
// only for signed-in Comms users, so this can't be used as an open proxy.
const SIGNED_PATH = /^\/dl\/\d+\.[0-9a-f]+\//;

async function media(raw) {
  let target;
  try {
    target = new URL(raw || '');
  } catch {
    return json({ error: 'bad link' }, 400);
  }
  if (target.protocol !== 'https:' || target.hostname !== 'tmpfiles.org' || target.port) return json({ error: 'bad link' }, 400);
  if (!SIGNED_PATH.test(target.pathname)) {
    // A page link (or an old /dl/ link): the file's own link is on its page.
    const parts = target.pathname.split('/').filter(Boolean);
    if (parts[0] === 'dl') parts.shift();
    const page = await fetch(`https://tmpfiles.org/${parts.join('/')}`);
    if (page.status !== 200) return json({ error: 'gone' }, 410);
    const found = (await page.text()).match(/href="(https:\/\/tmpfiles\.org\/dl\/[^"]+)"/);
    if (!found) return json({ error: 'gone' }, 410);
    target = new URL(found[1].replace(/&amp;/g, '&'));
    if (target.hostname !== 'tmpfiles.org' || !SIGNED_PATH.test(target.pathname)) return json({ error: 'gone' }, 410);
  }
  const file = await fetch(target.toString());
  // An expired link answers with a web page instead of the file.
  if (file.status !== 200 || (file.headers.get('content-type') || '').includes('text/html')) return json({ error: 'gone' }, 410);
  const headers = { 'Content-Type': 'application/octet-stream', 'Cache-Control': 'private, max-age=3600' };
  const length = file.headers.get('content-length');
  if (length) headers['Content-Length'] = length;
  return new Response(file.body, { status: 200, headers });
}

async function authenticate(request, env) {
  const header = request.headers.get('Authorization') || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : '';
  if (!token) return null;
  const claims = await verifyIdToken(token, env.PROJECT_ID);
  return claims ? claims.sub : null;
}

// ---------------------------------------------------------------------------
// Firestore and FCM helpers
// ---------------------------------------------------------------------------

async function googleToken(env) {
  return serviceAccountToken(JSON.parse(env.FIREBASE_SERVICE_ACCOUNT));
}

function docUrl(env, path) {
  return `https://firestore.googleapis.com/v1/projects/${env.PROJECT_ID}/databases/(default)/documents/${path}`;
}

async function getDoc(env, path) {
  const res = await fetch(docUrl(env, path), { headers: { Authorization: `Bearer ${await googleToken(env)}` } });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`firestore ${res.status} for ${path}`);
  return decodeDocument(await res.json());
}

async function batchGet(env, paths) {
  if (!paths.length) return new Map();
  const base = `projects/${env.PROJECT_ID}/databases/(default)/documents/`;
  const res = await fetch(
    `https://firestore.googleapis.com/v1/projects/${env.PROJECT_ID}/databases/(default)/documents:batchGet`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${await googleToken(env)}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ documents: paths.map(p => base + p) }),
    },
  );
  if (!res.ok) throw new Error(`firestore batchGet ${res.status}`);
  const rows = await res.json();
  const found = new Map();
  for (const row of rows) {
    if (row.found) found.set(row.found.name.split('/documents/')[1], decodeDocument(row.found));
  }
  return found;
}

/**
 * Each person's notification address. It lives in their private document
 * (users/{uid}/private/data), which other people can't read; versions before 2.1
 * kept it on the public profile.
 */
async function getTokens(env, uids) {
  return (await getAddresses(env, uids)).tokens;
}

/**
 * Where to reach each person: their phone (FCM token) and any browsers with Comms
 * Web notifications on (web push subscriptions, kept in the same private document).
 */
async function getAddresses(env, uids) {
  const docs = await batchGet(env, uids.flatMap(uid => [`users/${uid}`, `users/${uid}/private/data`]));
  const tokens = new Map();
  const browsers = new Map();
  for (const uid of uids) {
    const priv = docs.get(`users/${uid}/private/data`);
    const token = priv?.fcmToken || docs.get(`users/${uid}`)?.fcmToken;
    if (token) tokens.set(uid, token);
    const subs = Object.entries(priv?.webPush || {})
      .filter(([, sub]) => sub && typeof sub.endpoint === 'string' && sub.endpoint.startsWith('https://') && sub.p256dh && sub.auth)
      .map(([id, sub]) => ({ id, endpoint: sub.endpoint, p256dh: sub.p256dh, auth: sub.auth }));
    if (subs.length) browsers.set(uid, subs);
  }
  return { tokens, browsers };
}

function vapidKeys(env) {
  if (!env.VAPID_PUBLIC_KEY || !env.VAPID_PRIVATE_KEY) return null;
  return { publicKey: env.VAPID_PUBLIC_KEY, privateKey: env.VAPID_PRIVATE_KEY, subject: 'https://jp-comms.web.app' };
}

/** Sends a notification to each of [uid]'s browsers, forgetting ones that unsubscribed. */
async function notifyBrowsers(env, uid, subs, data, options) {
  const vapid = vapidKeys(env);
  if (!vapid || !subs?.length) return 0;
  let sent = 0;
  await Promise.all(subs.map(async sub => {
    const result = await sendWebPush(sub, data, vapid, options);
    if (result === 'sent') sent++;
    if (result === 'gone') await forgetBrowser(env, uid, sub.id).catch(e => console.warn('forget browser', e.message));
  }));
  return sent;
}

async function forgetBrowser(env, uid, id) {
  if (!/^w[0-9a-f]{1,32}$/.test(id)) return;
  await fetch(`${docUrl(env, `users/${uid}/private/data`)}?updateMask.fieldPaths=webPush.${id}`, {
    method: 'PATCH',
    headers: { Authorization: `Bearer ${await googleToken(env)}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ fields: {} }),
  });
}

/** Sends one FCM message. Returns false when the device token is no longer valid. */
async function sendFcm(env, message) {
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${env.PROJECT_ID}/messages:send`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${await googleToken(env)}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ message }),
  });
  if (res.ok) return true;
  const text = await res.text();
  if (res.status === 404 || text.includes('UNREGISTERED')) return false;
  console.warn('fcm', res.status, text.slice(0, 300));
  return true;
}

// Everything goes as a data message so the app decides how to show it (and can save media).
function dataMessage(token, data, ttlSeconds) {
  const stringData = Object.fromEntries(Object.entries(data).map(([k, v]) => [k, v == null ? '' : String(v)]));
  return {
    token,
    data: stringData,
    android: { priority: 'HIGH', ttl: `${ttlSeconds}s` },
    apns: { headers: { 'apns-priority': '10' }, payload: { aps: { 'content-available': 1 } } },
  };
}

// ---------------------------------------------------------------------------
// Endpoints
// ---------------------------------------------------------------------------

const PREVIEW = { image: '📷 Photo', video: '🎥 Video', audio: '🎤 Voice message', gif: 'GIF' };

async function notifyMessage(env, uid, { chatRoomId, messageId }) {
  if (!chatRoomId || !messageId) return json({ error: 'missing fields' }, 400);
  const [room, message] = await Promise.all([
    getDoc(env, `chatRooms/${chatRoomId}`),
    getDoc(env, `chatRooms/${chatRoomId}/messages/${messageId}`),
  ]);
  if (!room || !message) return json({ error: 'not found' }, 404);
  if (message.senderId !== uid || !(room.participants || []).includes(uid)) return json({ error: 'forbidden' }, 403);
  // Only fresh messages, so an old message cannot be used to spam notifications.
  if (Date.now() - Number(message.timestamp || 0) > 2 * 60 * 1000) return json({ sent: 0 });

  const recipients = (room.participants || []).filter(id => id !== uid);
  const { tokens, browsers } = await getAddresses(env, recipients);
  const isGroup = room.type === 'group';
  const enc = message.enc && typeof message.enc === 'object' ? message.enc : null;
  // Encrypted messages: this server can't read the words, so it only says what kind of
  // message it is; the phone unlocks the real text itself.
  const preview = message.viewLimit
    ? (message.type === 'video' ? '🎥 View-once video' : '📷 View-once photo')
    : PREVIEW[message.type] || (enc ? '🔒 New message' : String(message.text || '').slice(0, 300));
  let sent = 0;
  await Promise.all([...tokens].map(async ([recipient, token]) => {
    const data = {
      type: 'chat',
      id: chatRoomId,
      messageId,
      senderId: uid,
      senderName: message.senderName || '',
      isGroup: String(isGroup),
      title: isGroup ? room.groupName || 'Group' : message.senderName || 'New message',
      body: isGroup ? `${message.senderName}: ${preview}` : preview,
      mediaType: message.type,
    };
    if (enc) {
      // Only this person's copy of the message key, so the push stays small.
      const wrapped = enc.k && enc.k[recipient];
      if (wrapped && String(enc.c || '').length <= 2800) {
        Object.assign(data, { to: recipient, f: enc.f, n: enc.n, c: enc.c, k: wrapped });
      }
    } else {
      Object.assign(data, { mediaUrl: message.mediaUrl || '', mediaName: message.mediaName || '' });
    }
    await sendFcm(env, dataMessage(token, data, 3600));
    sent++;
  }));
  // Browsers: the words are end-to-end encrypted and a browser's background worker
  // can't unlock them, so the notification says who wrote and what kind of message.
  const title = isGroup ? room.groupName || 'Group' : message.senderName || 'New message';
  const body = isGroup ? `${message.senderName}: ${preview}` : preview;
  await Promise.all([...browsers].map(async ([recipient, subs]) => {
    sent += await notifyBrowsers(env, recipient, subs, { type: 'chat', id: chatRoomId, title, body, tag: `chat:${chatRoomId}` });
  }));
  return json({ sent });
}

async function notifyCall(env, uid, { callId }) {
  if (!callId) return json({ error: 'missing fields' }, 400);
  const call = await getDoc(env, `calls/${callId}`);
  if (!call) return json({ error: 'not found' }, 404);
  if (call.callerId !== uid) return json({ error: 'forbidden' }, 403);
  if (call.status !== 'ringing') return json({ sent: 0 });

  const { tokens, browsers } = await getAddresses(env, [call.receiverId]);
  const token = tokens.get(call.receiverId);
  let sent = 0;
  if (token) {
    await sendFcm(env, dataMessage(token, {
      type: 'call',
      id: callId,
      callerName: call.callerName,
      callerId: call.callerId,
      isVideo: call.type === 'video',
      sentAt: Date.now(),
    }, 40));
    sent++;
  }
  sent += await notifyBrowsers(env, call.receiverId, browsers.get(call.receiverId), {
    type: 'call',
    id: callId,
    title: call.callerName || 'Someone',
    body: call.type === 'video' ? 'Incoming video call' : 'Incoming voice call',
    tag: `call:${callId}`,
  }, { ttl: 40 });
  return json({ sent });
}

// Tells the other person's phone that a call was declined, cancelled or ended,
// so a ringing notification disappears even when the app is closed.
async function notifyCallUpdate(env, uid, { callId }) {
  if (!callId) return json({ error: 'missing fields' }, 400);
  const call = await getDoc(env, `calls/${callId}`);
  if (!call) return json({ error: 'not found' }, 404);
  if (uid !== call.callerId && uid !== call.receiverId) return json({ error: 'forbidden' }, 403);

  const otherId = uid === call.callerId ? call.receiverId : call.callerId;
  const { tokens, browsers } = await getAddresses(env, [otherId]);
  const token = tokens.get(otherId);
  const missed = uid === call.callerId && call.status === 'missed';
  let browserSent = 0;
  if (missed) {
    browserSent = await notifyBrowsers(env, otherId, browsers.get(otherId), {
      type: 'missed',
      id: callId,
      title: `Missed ${call.type === 'video' ? 'video' : 'voice'} call`,
      body: call.callerName || 'Someone',
      tag: `call:${callId}`,
    }, { ttl: 3600, urgency: 'normal' });
  }
  if (!token) return json({ sent: browserSent });
  await sendFcm(env, dataMessage(token, {
    type: 'call_update',
    id: callId,
    status: call.status,
    endReason: call.endReason || '',
    callerName: call.callerName,
    callerId: call.callerId,
    isVideo: call.type === 'video',
    missed,
  }, 600));
  return json({ sent: 1 + browserSent });
}

// The newest release, read by the app's "Update" button. Change these in wrangler.toml.
function latestVersion(env) {
  return new Response(JSON.stringify({
    version: env.LATEST_VERSION || '',
    build: Number(env.LATEST_BUILD || 0),
    url: env.DOWNLOAD_URL || '',
    notes: env.RELEASE_NOTES || '',
  }), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=300' } });
}

let iceCache = null;

async function iceServers(env) {
  const stun = [{ urls: 'stun:stun.l.google.com:19302' }, { urls: 'stun:stun.relay.metered.ca:80' }];
  // A fixed Metered credential (username + password from the dashboard).
  if (env.METERED_USERNAME && env.METERED_PASSWORD) {
    const auth = { username: env.METERED_USERNAME, credential: env.METERED_PASSWORD };
    return json({
      iceServers: [
        ...stun,
        { urls: 'turn:global.relay.metered.ca:80', ...auth },
        { urls: 'turn:global.relay.metered.ca:80?transport=tcp', ...auth },
        { urls: 'turn:global.relay.metered.ca:443', ...auth },
        { urls: 'turns:global.relay.metered.ca:443?transport=tcp', ...auth },
      ],
    });
  }
  if (!env.METERED_API_KEY || !env.METERED_DOMAIN) return json({ iceServers: stun });
  if (iceCache && iceCache.until > Date.now()) return json({ iceServers: iceCache.servers });
  const res = await fetch(`https://${env.METERED_DOMAIN}/api/v1/turn/credentials?apiKey=${encodeURIComponent(env.METERED_API_KEY)}`);
  if (!res.ok) return json({ iceServers: stun });
  const servers = await res.json();
  iceCache = { servers, until: Date.now() + 30 * 60 * 1000 };
  return json({ iceServers: servers });
}

// One-off announcement to every user (used to tell people on old versions about 2.0).
async function broadcast(request, env) {
  if (!env.ADMIN_SECRET || request.headers.get('X-Admin-Secret') !== env.ADMIN_SECRET) {
    return json({ error: 'unauthorized' }, 401);
  }
  const { title, body, url, pageToken, onlyOldVersions, dryRun } = await request.json();
  const listUrl = new URL(docUrl(env, 'users'));
  listUrl.searchParams.set('pageSize', '40');
  listUrl.searchParams.append('mask.fieldPaths', 'fcmToken');
  // Version 2 stamps these whenever someone sends a message or places a call; 1.x never does.
  listUrl.searchParams.append('mask.fieldPaths', 'lastMessageAt');
  listUrl.searchParams.append('mask.fieldPaths', 'lastCallAt');
  if (pageToken) listUrl.searchParams.set('pageToken', pageToken);
  const res = await fetch(listUrl, { headers: { Authorization: `Bearer ${await googleToken(env)}` } });
  if (!res.ok) throw new Error(`firestore list ${res.status}`);
  const page = await res.json();
  const users = (page.documents || []).map(d => ({ ...decodeDocument(d), uid: d.name.split('/').pop() }));
  const chosen = users.filter(u => !(onlyOldVersions && (u.lastMessageAt || u.lastCallAt)));
  const found = await getTokens(env, chosen.map(u => u.uid));
  const tokens = chosen.map(u => found.get(u.uid)).filter(Boolean);
  if (dryRun) {
    return json({ wouldSend: tokens.length, skipped: users.length - tokens.length, nextPageToken: page.nextPageToken || null });
  }
  let sent = 0;
  for (const token of tokens) {
    // A visible notification block, so even version 1.x shows it.
    const ok = await sendFcm(env, {
      token,
      notification: { title, body },
      data: { type: 'update', url: url || '' },
      android: { priority: 'HIGH', notification: { channel_id: 'comms_channel' } },
    });
    if (ok) sent++;
  }
  return json({ sent, nextPageToken: page.nextPageToken || null });
}
