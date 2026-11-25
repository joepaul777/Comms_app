// Web Push: notifications for Comms in a browser (including iPhones with Comms added
// to the Home Screen), sent straight to each browser's push service.
//
// RFC 8291 encrypts the notification for the one browser it is meant for; RFC 8292
// (VAPID) proves it comes from Comms. Nothing here needs a paid service.

const enc = new TextEncoder();

export function b64urlToBytes(value) {
  const base64 = value.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(value.length / 4) * 4, '=');
  return Uint8Array.from(atob(base64), c => c.charCodeAt(0));
}

export function bytesToB64url(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

async function hkdf(salt, ikm, info, length) {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, length * 8));
}

/** A P-256 key from its raw public point and private scalar (as in the RFC examples). */
export async function importEcKey(publicRaw, privateB64url, usage) {
  const jwk = {
    kty: 'EC',
    crv: 'P-256',
    x: bytesToB64url(publicRaw.slice(1, 33)),
    y: bytesToB64url(publicRaw.slice(33, 65)),
    d: privateB64url,
    ext: true,
  };
  return crypto.subtle.importKey('jwk', jwk, usage === 'sign' ? { name: 'ECDSA', namedCurve: 'P-256' } : { name: 'ECDH', namedCurve: 'P-256' }, false, usage === 'sign' ? ['sign'] : ['deriveBits']);
}

/**
 * Encrypts [plaintext] for one browser (RFC 8291, aes128gcm, a single record).
 * [salt] and [serverKeys] are only passed in tests; normally both are fresh each time.
 */
export async function encryptForBrowser(plaintext, { p256dh, auth }, { salt, serverKeys } = {}) {
  const uaPublic = b64urlToBytes(p256dh);
  const authSecret = b64urlToBytes(auth);
  const keys = serverKeys ?? (await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']));
  const asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', keys.publicKey));
  const uaKey = await crypto.subtle.importKey('raw', uaPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, keys.privateKey, 256));

  const ikm = await hkdf(authSecret, shared, concat(enc.encode('WebPush: info\0'), uaPublic, asPublic), 32);
  const recordSalt = salt ?? crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(recordSalt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(recordSalt, ikm, enc.encode('Content-Encoding: nonce\0'), 12);

  const aes = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  // One record: the message, then the 0x02 "last record" delimiter.
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, aes, concat(plaintext, new Uint8Array([2]))));
  const recordSize = new Uint8Array([0, 0, 16, 0]); // 4096
  return concat(recordSalt, recordSize, new Uint8Array([asPublic.length]), asPublic, cipher);
}

/** The VAPID header proving the push comes from Comms (RFC 8292). */
export async function vapidAuthorization(endpoint, { publicKey, privateKey, subject }, now = Date.now()) {
  const header = bytesToB64url(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const claims = bytesToB64url(enc.encode(JSON.stringify({
    aud: new URL(endpoint).origin,
    exp: Math.floor(now / 1000) + 12 * 3600,
    sub: subject,
  })));
  const key = await importEcKey(b64urlToBytes(publicKey), privateKey, 'sign');
  const signature = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(`${header}.${claims}`)));
  return `vapid t=${header}.${claims}.${bytesToB64url(signature)}, k=${publicKey}`;
}

/**
 * Sends [data] to one browser. Returns 'sent', 'gone' (the browser unsubscribed, so
 * forget it) or 'failed'.
 */
export async function sendWebPush(subscription, data, vapid, { ttl = 3600, urgency = 'high' } = {}) {
  try {
    const body = await encryptForBrowser(enc.encode(JSON.stringify(data)), subscription);
    const res = await fetch(subscription.endpoint, {
      method: 'POST',
      headers: {
        Authorization: await vapidAuthorization(subscription.endpoint, vapid),
        'Content-Encoding': 'aes128gcm',
        'Content-Type': 'application/octet-stream',
        TTL: String(ttl),
        Urgency: urgency,
      },
      body,
    });
    if (res.status === 404 || res.status === 410) return 'gone';
    if (!res.ok) {
      console.warn('web push', res.status, (await res.text()).slice(0, 200));
      return 'failed';
    }
    return 'sent';
  } catch (e) {
    console.warn('web push error', e?.message ?? e);
    return 'failed';
  }
}
