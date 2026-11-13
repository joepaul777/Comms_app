// Checks firestore.rules against the local emulator. Run with:
//   firebase emulators:exec --only firestore --project demo-comms "node rules-test/test.mjs"
import { readFileSync } from 'node:fs';
import { assertFails, assertSucceeds, initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, updateDoc, writeBatch, serverTimestamp, collection, query, where, getDocs, increment } from 'firebase/firestore';

const env = await initializeTestEnvironment({
  projectId: 'demo-comms',
  firestore: { rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8'), host: '127.0.0.1', port: 8080 },
});

const results = [];
async function check(name, fn) {
  try {
    await fn();
    results.push(['ok', name]);
  } catch (e) {
    results.push(['FAIL', `${name}: ${e.message.split('\n')[0]}`]);
  }
}
const wait = ms => new Promise(r => setTimeout(r, ms));

await env.withSecurityRulesDisabled(async ctx => {
  const db = ctx.firestore();
  for (const uid of ['alice', 'bob', 'eve']) await setDoc(doc(db, 'users', uid), { uid, name: uid, email: `${uid}@x.com` });
  await setDoc(doc(db, 'chatRooms', 'r1'), { id: 'r1', type: 'direct', participants: ['alice', 'bob'], lastMessageTime: 0 });
  await setDoc(doc(db, 'calls', 'c0'), { id: 'c0', callerId: 'alice', receiverId: 'bob', status: 'ended' });
});

const alice = env.authenticatedContext('alice').firestore();
const bob = env.authenticatedContext('bob').firestore();
const eve = env.authenticatedContext('eve').firestore();
const nobody = env.unauthenticatedContext().firestore();

// Mirrors what the app does when it sends: message + room summary + own rate fields, in one batch.
let window = { start: null, count: 0 };
async function send(db, uid, roomId, id, { newWindow } = {}) {
  const batch = writeBatch(db);
  batch.set(doc(db, 'chatRooms', roomId, 'messages', id), { id, senderId: uid, senderName: uid, text: 'hi', type: 'text', timestamp: Date.now() });
  batch.update(doc(db, 'chatRooms', roomId), { lastMessage: 'hi', lastMessageSenderId: uid, lastMessageTime: Date.now() });
  const fields = { lastMessageAt: serverTimestamp() };
  if (newWindow) Object.assign(fields, { msgWindowStart: serverTimestamp(), msgWindowCount: 1 });
  else fields.msgWindowCount = increment(1);
  batch.update(doc(db, 'users', uid), fields);
  return batch.commit();
}

await check('signed-out people cannot read anything', () => assertFails(getDoc(doc(nobody, 'users', 'alice'))));
await check('signed-in people can look up users', () => assertSucceeds(getDoc(doc(eve, 'users', 'alice'))));
await check('nobody can edit someone else\'s profile', () => assertFails(updateDoc(doc(eve, 'users', 'alice'), { name: 'x' })));
await check('people can edit their own profile', () => assertSucceeds(updateDoc(doc(alice, 'users', 'alice'), { isOnline: true })));
await check('a chat member can read the chat', () => assertSucceeds(getDoc(doc(alice, 'chatRooms', 'r1'))));
await check('an outsider cannot read the chat', () => assertFails(getDoc(doc(eve, 'chatRooms', 'r1'))));
await check('chat list query works for members', () => assertSucceeds(getDocs(query(collection(alice, 'chatRooms'), where('participants', 'array-contains', 'alice')))));
await check('an outsider cannot post into the chat', () => assertFails(send(eve, 'eve', 'r1', 'e1', { newWindow: true })));
await check('a message without the rate update is refused', () => assertFails(setDoc(doc(alice, 'chatRooms', 'r1', 'messages', 'm0'), { id: 'm0', senderId: 'alice', text: 'x', type: 'text' })));
await check('first message goes through', () => assertSucceeds(send(alice, 'alice', 'r1', 'm1', { newWindow: true })));
await check('a second message straight away is refused', () => assertFails(send(alice, 'alice', 'r1', 'm2')));
await wait(800);
await check('after 0.8 s the next message goes through', () => assertSucceeds(send(alice, 'alice', 'r1', 'm3')));
await check('cannot pretend to be someone else', () => assertFails((async () => {
  const batch = writeBatch(bob);
  batch.set(doc(bob, 'chatRooms', 'r1', 'messages', 'fake'), { id: 'fake', senderId: 'alice', text: 'x', type: 'text' });
  batch.update(doc(bob, 'users', 'bob'), { lastMessageAt: serverTimestamp(), msgWindowStart: serverTimestamp(), msgWindowCount: 1 });
  await batch.commit();
})()));
await check('the other member can read messages', () => assertSucceeds(getDocs(collection(bob, 'chatRooms', 'r1', 'messages'))));
await check('a two-person chat cannot gain members', () => assertFails(updateDoc(doc(alice, 'chatRooms', 'r1'), { participants: ['alice', 'bob', 'eve'] })));

// Burst: 30 per minute. Two already sent in this window.
let burstFailedAt = null;
for (let i = 3; i <= 31; i++) {
  await wait(720);
  try {
    await send(alice, 'alice', 'r1', `b${i}`);
  } catch {
    burstFailedAt = i;
    break;
  }
}
await check('the 31st message inside a minute is refused', async () => {
  if (burstFailedAt !== 31) throw new Error(`stopped at ${burstFailedAt}`);
});

// Calls
async function call(db, uid, to, id, { newWindow } = {}) {
  const batch = writeBatch(db);
  batch.set(doc(db, 'calls', id), { id, callerId: uid, receiverId: to, status: 'ringing', type: 'audio', timestamp: Date.now() });
  const fields = { lastCallAt: serverTimestamp() };
  if (newWindow) Object.assign(fields, { callWindowStart: serverTimestamp(), callWindowCount: 1 });
  else fields.callWindowCount = increment(1);
  batch.update(doc(db, 'users', uid), fields);
  return batch.commit();
}
await check('a call goes through', () => assertSucceeds(call(bob, 'bob', 'alice', 'k1', { newWindow: true })));
await check('calling again straight away is refused', () => assertFails(call(bob, 'bob', 'alice', 'k2')));
await check('the person called can see the call', () => assertSucceeds(getDoc(doc(alice, 'calls', 'k1'))));
await check('an outsider cannot see the call', () => assertFails(getDoc(doc(eve, 'calls', 'k1'))));
await check('the person called can decline', () => assertSucceeds(updateDoc(doc(alice, 'calls', 'k1'), { status: 'rejected', endReason: 'declined', endedBy: 'alice' })));
await check('an outsider cannot end the call', () => assertFails(updateDoc(doc(eve, 'calls', 'k1'), { status: 'ended' })));
await check('call setup data can be exchanged', () => assertSucceeds(setDoc(doc(alice, 'calls', 'k1', 'receiverCandidates', 'x'), { candidate: 'c' })));
await check('incoming-call query works', () => assertSucceeds(getDocs(query(collection(alice, 'calls'), where('receiverId', '==', 'alice'), where('status', '==', 'ringing')))));
await check('cannot place a call as someone else', () => assertFails(call(eve, 'bob', 'alice', 'k3', { newWindow: true })));
await check('cannot set the limit time by hand', () => assertFails(updateDoc(doc(eve, 'users', 'eve'), { lastCallAt: new Date(0) })));

// Clearing a chat
const { deleteDoc } = await import('firebase/firestore');
await check('in a two-person chat, either person can clear messages', () => assertSucceeds(deleteDoc(doc(bob, 'chatRooms', 'r1', 'messages', 'm1'))));
await check('an outsider cannot delete messages', () => assertFails(deleteDoc(doc(eve, 'chatRooms', 'r1', 'messages', 'm3'))));

// Reactions, editing, receipts and typing
await env.withSecurityRulesDisabled(async ctx => {
  const db = ctx.firestore();
  await setDoc(doc(db, 'chatRooms', 'r1', 'messages', 'fresh'), { id: 'fresh', senderId: 'alice', text: 'hi', type: 'text', timestamp: Date.now() });
  await setDoc(doc(db, 'chatRooms', 'r1', 'messages', 'old'), { id: 'old', senderId: 'alice', text: 'hi', type: 'text', timestamp: Date.now() - 20 * 60 * 1000 });
  await setDoc(doc(db, 'chatRooms', 'r1', 'messages', 'pic'), { id: 'pic', senderId: 'alice', text: '', type: 'image', timestamp: Date.now() });
});
await check('a member can react', () => assertSucceeds(updateDoc(doc(bob, 'chatRooms', 'r1', 'messages', 'fresh'), { 'reactions.bob': '👍' })));
await check('a member can change their reaction', () => assertSucceeds(updateDoc(doc(bob, 'chatRooms', 'r1', 'messages', 'fresh'), { 'reactions.bob': '😂' })));
await check('nobody can set someone else\'s reaction', () => assertFails(updateDoc(doc(bob, 'chatRooms', 'r1', 'messages', 'fresh'), { 'reactions.alice': '👍' })));
await check('reactions must be short', () => assertFails(updateDoc(doc(bob, 'chatRooms', 'r1', 'messages', 'fresh'), { 'reactions.bob': 'x'.repeat(40) })));
await check('an outsider cannot react', () => assertFails(updateDoc(doc(eve, 'chatRooms', 'r1', 'messages', 'fresh'), { 'reactions.eve': '👍' })));
await check('the sender can edit a recent message', () => assertSucceeds(updateDoc(doc(alice, 'chatRooms', 'r1', 'messages', 'fresh'), { text: 'hello', editedAt: Date.now() })));
await check('someone else cannot edit it', () => assertFails(updateDoc(doc(bob, 'chatRooms', 'r1', 'messages', 'fresh'), { text: 'x', editedAt: Date.now() })));
await check('an old message cannot be edited', () => assertFails(updateDoc(doc(alice, 'chatRooms', 'r1', 'messages', 'old'), { text: 'x', editedAt: Date.now() })));
await check('a photo cannot be edited', () => assertFails(updateDoc(doc(alice, 'chatRooms', 'r1', 'messages', 'pic'), { text: 'x', editedAt: Date.now() })));
await check('editing cannot change who sent it', () => assertFails(updateDoc(doc(alice, 'chatRooms', 'r1', 'messages', 'fresh'), { text: 'x', senderId: 'bob' })));
await check('a member can mark the chat seen and show typing', () => assertSucceeds(updateDoc(doc(bob, 'chatRooms', 'r1'), { 'readUpTo.bob': Date.now(), 'readAt.bob': Date.now(), 'typing.bob': Date.now() })));

await env.cleanup();
for (const [status, name] of results) console.log(`${status.padEnd(4)} ${name}`);
const failed = results.filter(r => r[0] !== 'ok').length;
console.log(`\n${results.length - failed} of ${results.length} passed`);
process.exit(failed ? 1 : 0);
