// Checks the web push encryption against the worked example in RFC 8291 (Appendix A),
// and that the VAPID signature verifies. `node test/webpush.test.mjs`
import assert from 'node:assert/strict';
import { b64urlToBytes, bytesToB64url, encryptForBrowser, importEcKey, vapidAuthorization } from '../src/webpush.js';

const results = [];
const test = async (name, fn) => {
  try {
    await fn();
    results.push(`ok   ${name}`);
  } catch (e) {
    results.push(`FAIL ${name}: ${e.message}`);
  }
};

// RFC 8291, Appendix A
const rfc = {
  plaintext: 'V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24',
  asPublic: 'BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8',
  asPrivate: 'yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw',
  uaPublic: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
  auth: 'BTBZMqHH6r4Tts7J_aSIgg',
  salt: 'DGv6ra1nlYgDCS1FRnbzlw',
  header: 'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8',
  ciphertext: '8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ',
};

await test('encryption matches the RFC 8291 example byte for byte', async () => {
  const asPublicRaw = b64urlToBytes(rfc.asPublic);
  const serverKeys = {
    publicKey: await crypto.subtle.importKey('raw', asPublicRaw, { name: 'ECDH', namedCurve: 'P-256' }, true, []),
    privateKey: await importEcKey(asPublicRaw, rfc.asPrivate, 'derive'),
  };
  const body = await encryptForBrowser(b64urlToBytes(rfc.plaintext), { p256dh: rfc.uaPublic, auth: rfc.auth }, { salt: b64urlToBytes(rfc.salt), serverKeys });
  const expected = new Uint8Array([...b64urlToBytes(rfc.header), ...b64urlToBytes(rfc.ciphertext)]);
  assert.equal(bytesToB64url(body), bytesToB64url(expected));
});

await test('every message is encrypted differently', async () => {
  const sub = { p256dh: rfc.uaPublic, auth: rfc.auth };
  const a = await encryptForBrowser(new TextEncoder().encode('hi'), sub);
  const b = await encryptForBrowser(new TextEncoder().encode('hi'), sub);
  assert.notEqual(bytesToB64url(a), bytesToB64url(b));
});

await test('the VAPID signature verifies with the public key, for the push service it is sent to', async () => {
  const keys = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const publicRaw = new Uint8Array(await crypto.subtle.exportKey('raw', keys.publicKey));
  const jwk = await crypto.subtle.exportKey('jwk', keys.privateKey);
  const header = await vapidAuthorization('https://web.push.apple.com/abc123', { publicKey: bytesToB64url(publicRaw), privateKey: jwk.d, subject: 'https://jp-comms.web.app' });
  const [, token, k] = header.match(/^vapid t=([^,]+), k=(.+)$/);
  assert.equal(k, bytesToB64url(publicRaw));
  const [h, c, s] = token.split('.');
  const claims = JSON.parse(new TextDecoder().decode(b64urlToBytes(c)));
  assert.equal(claims.aud, 'https://web.push.apple.com');
  assert.equal(claims.sub, 'https://jp-comms.web.app');
  assert.ok(claims.exp > Date.now() / 1000);
  const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, keys.publicKey, b64urlToBytes(s), new TextEncoder().encode(`${h}.${c}`));
  assert.ok(ok, 'signature must verify');
});

console.log(results.join('\n'));
const failed = results.filter(r => r.startsWith('FAIL')).length;
console.log(`\n${results.length - failed} of ${results.length} passed`);
process.exit(failed ? 1 : 0);
