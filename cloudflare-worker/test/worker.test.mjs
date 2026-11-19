// Runs the worker against fake Google services. `node test/worker.test.mjs`
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';

const PROJECT = 'jp-comms';
const enc = new TextEncoder();
const b64url = bytes => Buffer.from(bytes).toString('base64url');

// Keys: one acting as Google's token signer, one as an attacker, one as the service account.
const algo = { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' };
const google = await webcrypto.subtle.generateKey(algo, true, ['sign', 'verify']);
const attacker = await webcrypto.subtle.generateKey(algo, true, ['sign', 'verify']);
const sa = await webcrypto.subtle.generateKey(algo, true, ['sign', 'verify']);
const googleJwk = { ...(await webcrypto.subtle.exportKey('jwk', google.publicKey)), kid: 'k1', alg: 'RS256', use: 'sig' };
const saPem = `-----BEGIN PRIVATE KEY-----\n${Buffer.from(await webcrypto.subtle.exportKey('pkcs8', sa.privateKey)).toString('base64')}\n-----END PRIVATE KEY-----\n`;

async function idToken(uid, { key = google.privateKey, exp = Date.now() / 1000 + 3600, aud = PROJECT } = {}) {
  const header = b64url(enc.encode(JSON.stringify({ alg: 'RS256', kid: 'k1', typ: 'JWT' })));
  const now = Math.floor(Date.now() / 1000);
  const body = b64url(enc.encode(JSON.stringify({ aud, iss: `https://securetoken.google.com/${aud}`, sub: uid, iat: now, exp: Math.floor(exp) })));
  const sig = await webcrypto.subtle.sign('RSASSA-PKCS1-v1_5', key, enc.encode(`${header}.${body}`));
  return `${header}.${body}.${b64url(sig)}`;
}

// Fake Firestore data
const value = v => Array.isArray(v) ? { arrayValue: { values: v.map(value) } }
  : typeof v === 'number' ? { integerValue: String(v) }
    : v && typeof v === 'object' ? { mapValue: { fields: fields(v) } } : { stringValue: v };
const fields = obj => Object.fromEntries(Object.entries(obj).map(([k, v]) => [k, value(v)]));
const db = {
  'users/alice': { uid: 'alice', name: 'Alice', fcmToken: 'tok-alice' },
  'users/bob': { uid: 'bob', name: 'Bob', fcmToken: 'tok-bob' },
  'users/eve': { uid: 'eve', name: 'Eve' },
  // Version 2.1 keeps the notification address in a private document.
  'users/carol': { uid: 'carol', name: 'Carol' },
  'users/carol/private/data': { fcmToken: 'tok-carol' },
  'chatRooms/r2': { id: 'r2', type: 'direct', participants: ['alice', 'carol'] },
  'chatRooms/r2/messages/sec': {
    id: 'sec', senderId: 'alice', senderName: 'Alice', text: '🔒 Update Comms to read this message', type: 'text', timestamp: Date.now(),
    enc: { v: 1, f: 'PUB-ALICE', n: 'NONCE', c: 'SCRAMBLED', k: { alice: 'KEY-FOR-ALICE', carol: 'KEY-FOR-CAROL' } },
  },
  'chatRooms/r1': { id: 'r1', type: 'direct', participants: ['alice', 'bob'] },
  'chatRooms/r1/messages/m1': { id: 'm1', senderId: 'alice', senderName: 'Alice', text: 'hello', type: 'text', timestamp: Date.now() },
  'chatRooms/r1/messages/old': { id: 'old', senderId: 'alice', senderName: 'Alice', text: 'old', type: 'text', timestamp: Date.now() - 3600_000 },
  'chatRooms/r1/messages/pic': { id: 'pic', senderId: 'alice', senderName: 'Alice', text: '', type: 'image', mediaUrl: 'https://tmpfiles.org/dl/1/a.jpg', mediaName: 'a.jpg', timestamp: Date.now() },
  'calls/c1': { id: 'c1', callerId: 'alice', callerName: 'Alice', receiverId: 'bob', status: 'ringing', type: 'video' },
  'calls/c2': { id: 'c2', callerId: 'alice', callerName: 'Alice', receiverId: 'bob', status: 'rejected', endReason: 'declined', type: 'audio' },
};

const sentFcm = [];
let oauthCalls = 0;
globalThis.fetch = async (input, init = {}) => {
  const url = String(input);
  if (url.startsWith('https://www.googleapis.com/service_accounts/v1/jwk/')) {
    return new Response(JSON.stringify({ keys: [googleJwk] }), { headers: { 'cache-control': 'max-age=600' } });
  }
  if (url === 'https://oauth2.googleapis.com/token') {
    oauthCalls++;
    const assertion = new URLSearchParams(init.body).get('assertion');
    const [h, p, s] = assertion.split('.');
    const ok = await webcrypto.subtle.verify('RSASSA-PKCS1-v1_5', sa.publicKey, Buffer.from(s, 'base64url'), enc.encode(`${h}.${p}`));
    assert.ok(ok, 'service account JWT must be signed with the service account key');
    return new Response(JSON.stringify({ access_token: 'access-1', expires_in: 3600 }));
  }
  const docPrefix = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/`;
  if (url.endsWith(':batchGet')) {
    const { documents } = JSON.parse(init.body);
    return new Response(JSON.stringify(documents.map(name => {
      const path = name.split('/documents/')[1];
      return db[path] ? { found: { name, fields: fields(db[path]) } } : { missing: name };
    })));
  }
  if (url.startsWith(docPrefix)) {
    const path = decodeURIComponent(url.slice(docPrefix.length).split('?')[0]);
    if (path === 'users') {
      const docs = Object.entries(db).filter(([k]) => /^users\/[^/]+$/.test(k)).map(([k, v]) => ({ name: k, fields: fields(v) }));
      return new Response(JSON.stringify({ documents: docs }));
    }
    return db[path] ? new Response(JSON.stringify({ fields: fields(db[path]) })) : new Response('{}', { status: 404 });
  }
  if (url.includes('fcm.googleapis.com')) {
    assert.equal(init.headers.Authorization, 'Bearer access-1');
    sentFcm.push(JSON.parse(init.body).message);
    return new Response('{}');
  }
  if (url.startsWith('https://example.metered.live/')) {
    return new Response(JSON.stringify([{ urls: 'turn:relay.example:80', username: 'u', credential: 'c' }]));
  }
  throw new Error(`unexpected fetch ${url}`);
};

const { default: worker } = await import('../src/index.js');
const env = { PROJECT_ID: PROJECT, FIREBASE_SERVICE_ACCOUNT: JSON.stringify({ client_email: 'sa@x', private_key: saPem }), ADMIN_SECRET: 's3cret' };
const call = async (path, { token, body, method = 'POST', envOverride = {}, headers = {} } = {}) => {
  const res = await worker.fetch(new Request(`https://w.dev${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers },
    body: method === 'POST' ? JSON.stringify(body || {}) : undefined,
  }), { ...env, ...envOverride });
  return { status: res.status, body: await res.json() };
};

const results = [];
const test = async (name, fn) => {
  try {
    sentFcm.length = 0;
    await fn();
    results.push(`ok   ${name}`);
  } catch (e) {
    results.push(`FAIL ${name}: ${e.message}`);
  }
};

const alice = await idToken('alice');
const bob = await idToken('bob');
const eve = await idToken('eve');

await test('no token is rejected', async () => assert.equal((await call('/notify/message', { body: {} })).status, 401));
await test('a token signed by someone else is rejected', async () => assert.equal((await call('/ice', { method: 'GET', token: await idToken('alice', { key: attacker.privateKey }) })).status, 401));
await test('an expired token is rejected', async () => assert.equal((await call('/ice', { method: 'GET', token: await idToken('alice', { exp: Date.now() / 1000 - 3600 }) })).status, 401));
await test('a token for another project is rejected', async () => assert.equal((await call('/ice', { method: 'GET', token: await idToken('alice', { aud: 'other' }) })).status, 401));
await test('a message notification reaches the other person', async () => {
  const r = await call('/notify/message', { token: alice, body: { chatRoomId: 'r1', messageId: 'm1' } });
  assert.equal(r.status, 200);
  assert.equal(sentFcm.length, 1);
  assert.equal(sentFcm[0].token, 'tok-bob');
  assert.equal(sentFcm[0].data.title, 'Alice');
  assert.equal(sentFcm[0].data.body, 'hello');
});
await test('photos announce themselves and carry the download link', async () => {
  await call('/notify/message', { token: alice, body: { chatRoomId: 'r1', messageId: 'pic' } });
  assert.equal(sentFcm[0].data.body, '📷 Photo');
  assert.equal(sentFcm[0].data.mediaUrl, 'https://tmpfiles.org/dl/1/a.jpg');
});
await test('encrypted messages carry only scrambled text, and only the recipient key', async () => {
  const r = await call('/notify/message', { token: alice, body: { chatRoomId: 'r2', messageId: 'sec' } });
  assert.equal(r.status, 200);
  assert.equal(sentFcm.length, 1);
  const { token, data } = sentFcm[0];
  assert.equal(token, 'tok-carol', 'uses the private notification address');
  assert.equal(data.body, '🔒 New message');
  assert.equal(data.c, 'SCRAMBLED');
  assert.equal(data.k, 'KEY-FOR-CAROL');
  assert.equal(data.to, 'carol');
  assert.ok(!JSON.stringify(data).includes('KEY-FOR-ALICE'));
  assert.ok(!('mediaUrl' in data));
});
await test('someone else cannot trigger a notification for Alice\'s message', async () => assert.equal((await call('/notify/message', { token: bob, body: { chatRoomId: 'r1', messageId: 'm1' } })).status, 403));
await test('an outsider cannot use the chat', async () => assert.equal((await call('/notify/message', { token: eve, body: { chatRoomId: 'r1', messageId: 'm1' } })).status, 403));
await test('old messages cannot be replayed as notifications', async () => {
  const r = await call('/notify/message', { token: alice, body: { chatRoomId: 'r1', messageId: 'old' } });
  assert.equal(r.body.sent, 0);
  assert.equal(sentFcm.length, 0);
});
await test('a ringing call alerts the person being called', async () => {
  await call('/notify/call', { token: alice, body: { callId: 'c1' } });
  assert.equal(sentFcm[0].token, 'tok-bob');
  assert.equal(sentFcm[0].data.type, 'call');
  assert.equal(sentFcm[0].data.isVideo, 'true');
  assert.equal(sentFcm[0].android.ttl, '40s');
});
await test('only the caller can make it ring', async () => assert.equal((await call('/notify/call', { token: bob, body: { callId: 'c1' } })).status, 403));
await test('a finished call does not ring', async () => assert.equal((await call('/notify/call', { token: alice, body: { callId: 'c2' } })).body.sent, 0));
await test('when Bob declines, Alice\'s phone is told', async () => {
  await call('/notify/call-update', { token: bob, body: { callId: 'c2' } });
  assert.equal(sentFcm[0].token, 'tok-alice');
  assert.equal(sentFcm[0].data.status, 'rejected');
  assert.equal(sentFcm[0].data.endReason, 'declined');
});
await test('outsiders cannot send call updates', async () => assert.equal((await call('/notify/call-update', { token: eve, body: { callId: 'c2' } })).status, 403));
await test('call relays fall back to direct servers without a Metered key', async () => {
  const r = await call('/ice', { method: 'GET', token: alice });
  assert.ok(r.body.iceServers.every(s => s.urls.startsWith('stun:')));
});
await test('call relays come from Metered when configured', async () => {
  const r = await call('/ice', { method: 'GET', token: alice, envOverride: { METERED_API_KEY: 'k', METERED_DOMAIN: 'example.metered.live' } });
  assert.equal(r.body.iceServers[0].urls, 'turn:relay.example:80');
});
await test('broadcast needs the admin secret', async () => assert.equal((await call('/broadcast', { body: { title: 't', body: 'b' } })).status, 401));
await test('broadcast reaches everyone with a device token', async () => {
  const r = await call('/broadcast', { headers: { 'X-Admin-Secret': 's3cret' }, body: { title: 'Comms 2.0', body: 'Update', url: 'https://x' } });
  assert.equal(r.body.sent, 3); // Alice and Bob (old style) and Carol (private document)
  assert.deepEqual(sentFcm.map(m => m.token).sort(), ['tok-alice', 'tok-bob', 'tok-carol']);
  assert.ok(sentFcm.every(m => m.notification.title === 'Comms 2.0'));
});
await test('the service account token is reused, not re-signed every time', async () => assert.equal(oauthCalls, 1));

console.log(results.join('\n'));
const failed = results.filter(r => r.startsWith('FAIL')).length;
console.log(`\n${results.length - failed} of ${results.length} passed`);
process.exit(failed ? 1 : 0);
