// Google auth helpers that run on Cloudflare Workers (Web Crypto only).

const encoder = new TextEncoder();

function base64UrlToBytes(value) {
  const base64 = value.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(value.length / 4) * 4, '=');
  const binary = atob(base64);
  return Uint8Array.from(binary, c => c.charCodeAt(0));
}

function bytesToBase64Url(bytes) {
  let binary = '';
  for (const b of new Uint8Array(bytes)) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

const jsonToBase64Url = value => bytesToBase64Url(encoder.encode(JSON.stringify(value)));

// ---------------------------------------------------------------------------
// Firebase ID token verification
// ---------------------------------------------------------------------------

const JWKS_URL = 'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';
let keyCache = { keys: new Map(), until: 0 };

async function signingKey(kid, fetchImpl) {
  if (Date.now() > keyCache.until || !keyCache.keys.has(kid)) {
    const res = await fetchImpl(JWKS_URL);
    if (!res.ok) throw new Error(`jwks ${res.status}`);
    const { keys } = await res.json();
    const map = new Map();
    for (const jwk of keys) {
      map.set(jwk.kid, await crypto.subtle.importKey('jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']));
    }
    const maxAge = Number((res.headers.get('cache-control') || '').match(/max-age=(\d+)/)?.[1] || 3600);
    keyCache = { keys: map, until: Date.now() + maxAge * 1000 };
  }
  return keyCache.keys.get(kid) || null;
}

/** Returns the token's claims if it is a valid, unexpired Firebase ID token for this project. */
export async function verifyIdToken(token, projectId, { fetchImpl = fetch, now = Date.now() } = {}) {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  let header;
  let claims;
  try {
    header = JSON.parse(new TextDecoder().decode(base64UrlToBytes(parts[0])));
    claims = JSON.parse(new TextDecoder().decode(base64UrlToBytes(parts[1])));
  } catch {
    return null;
  }
  if (header.alg !== 'RS256' || !header.kid) return null;
  const seconds = Math.floor(now / 1000);
  if (claims.aud !== projectId) return null;
  if (claims.iss !== `https://securetoken.google.com/${projectId}`) return null;
  if (typeof claims.sub !== 'string' || !claims.sub) return null;
  if (!(claims.exp > seconds - 60) || !(claims.iat <= seconds + 60)) return null;

  const key = await signingKey(header.kid, fetchImpl);
  if (!key) return null;
  const valid = await crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5',
    key,
    base64UrlToBytes(parts[2]),
    encoder.encode(`${parts[0]}.${parts[1]}`),
  );
  return valid ? claims : null;
}

// ---------------------------------------------------------------------------
// Service account access token (for Firestore and FCM)
// ---------------------------------------------------------------------------

let accessCache = { token: '', until: 0 };
let pendingToken = null;

function pemToPkcs8(pem) {
  const body = pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  return Uint8Array.from(atob(body), c => c.charCodeAt(0));
}

export async function serviceAccountToken(account, options = {}) {
  const now = options.now ?? Date.now();
  if (accessCache.token && now < accessCache.until) return accessCache.token;
  // Requests made at the same moment share one sign-in.
  pendingToken ??= fetchServiceAccountToken(account, { fetchImpl: options.fetchImpl ?? fetch, now })
    .finally(() => { pendingToken = null; });
  return pendingToken;
}

async function fetchServiceAccountToken(account, { fetchImpl, now }) {
  const seconds = Math.floor(now / 1000);
  const header = { alg: 'RS256', typ: 'JWT' };
  const claims = {
    iss: account.client_email,
    scope: 'https://www.googleapis.com/auth/datastore https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: seconds,
    exp: seconds + 3600,
  };
  const unsigned = `${jsonToBase64Url(header)}.${jsonToBase64Url(claims)}`;
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToPkcs8(account.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, encoder.encode(unsigned));
  const res = await fetchImpl('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${unsigned}.${bytesToBase64Url(signature)}`,
    }),
  });
  if (!res.ok) throw new Error(`oauth ${res.status}: ${await res.text()}`);
  const { access_token: token, expires_in: expiresIn } = await res.json();
  accessCache = { token, until: now + (Number(expiresIn) - 120) * 1000 };
  return token;
}

// ---------------------------------------------------------------------------
// Firestore REST values -> plain objects
// ---------------------------------------------------------------------------

function decodeValue(value) {
  if ('stringValue' in value) return value.stringValue;
  if ('integerValue' in value) return Number(value.integerValue);
  if ('doubleValue' in value) return value.doubleValue;
  if ('booleanValue' in value) return value.booleanValue;
  if ('timestampValue' in value) return value.timestampValue;
  if ('nullValue' in value) return null;
  if ('arrayValue' in value) return (value.arrayValue.values || []).map(decodeValue);
  if ('mapValue' in value) return decodeFields(value.mapValue.fields || {});
  return null;
}

function decodeFields(fields) {
  return Object.fromEntries(Object.entries(fields).map(([k, v]) => [k, decodeValue(v)]));
}

export function decodeDocument(document) {
  return decodeFields(document.fields || {});
}
