// Checks firestore.rules against the local emulator. Run with:
//   firebase emulators:exec --only firestore --project demo-comms "node rules-test/test.mjs"
import { readFileSync } from 'node:fs';
import { assertFails, assertSucceeds, initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, updateDoc, writeBatch, serverTimestamp, collection, query, where, getDocs, increment, limit, arrayRemove, arrayUnion } from 'firebase/firestore';

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
  for (const uid of ['alice', 'bob', 'eve', 'carol']) await setDoc(doc(db, 'users', uid), { uid, name: uid, email: `${uid}@x.com` });
  await setDoc(doc(db, 'users', 'alice', 'private', 'data'), { contacts: ['bob'], fcmToken: 'tok-alice' });
  await setDoc(doc(db, 'chatRooms', 'g1'), { id: 'g1', type: 'group', participants: ['alice', 'bob', 'carol'], adminId: 'alice', groupName: 'Team', lastMessageTime: 0 });
  await setDoc(doc(db, 'chatRooms', 'r1'), { id: 'r1', type: 'direct', participants: ['alice', 'bob'], lastMessageTime: 0 });
  await setDoc(doc(db, 'calls', 'c0'), { id: 'c0', callerId: 'alice', receiverId: 'bob', status: 'ended' });
});

const alice = env.authenticatedContext('alice').firestore();
const bob = env.authenticatedContext('bob').firestore();
const eve = env.authenticatedContext('eve').firestore();
const nobody = env.unauthenticatedContext().firestore();
const carol = env.authenticatedContext('carol').firestore();

// What an encrypted message looks like (contents don't matter to the rules).
const enc = { v: 1, f: 'A'.repeat(44), n: 'N'.repeat(16), c: 'scrambled', k: { alice: 'k1', bob: 'k2' } };
const LOCKED = '🔒 Update Comms to read this message';

// Mirrors what the app does when it sends: message + room summary + own rate fields, in one batch.
let window = { start: null, count: 0 };
async function send(db, uid, roomId, id, { newWindow, extra = {} } = {}) {
  const batch = writeBatch(db);
  batch.set(doc(db, 'chatRooms', roomId, 'messages', id), { id, senderId: uid, senderName: uid, text: LOCKED, type: 'text', timestamp: Date.now(), enc, ...extra });
  batch.update(doc(db, 'chatRooms', roomId), { lastMessage: '🔒 Message', lastEnc: enc, lastMessageSenderId: uid, lastMessageTime: Date.now() });
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
await wait(800);
await check('a plain, unencrypted message is refused', () => assertFails(send(alice, 'alice', 'r1', 'plain', { extra: { text: 'hello there', enc: null } })));
await check('a message with a readable file link is refused', () => assertFails(send(alice, 'alice', 'r1', 'leak', { extra: { mediaUrl: 'https://tmpfiles.org/dl/1/a.jpg' } })));
await check('a message with readable words next to the lock is refused', () => assertFails(send(alice, 'alice', 'r1', 'leak2', { extra: { text: 'x'.repeat(200) } })));
await check('the other member can read messages', () => assertSucceeds(getDocs(collection(bob, 'chatRooms', 'r1', 'messages'))));
await check('a two-person chat cannot gain members', () => assertFails(updateDoc(doc(alice, 'chatRooms', 'r1'), { participants: ['alice', 'bob', 'eve'] })));

// Burst: 30 per minute. Two already sent in this window.
await wait(800);
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
const edited = { ...enc, c: 'scrambled-new' };
await check('the sender can edit a recent message', () => assertSucceeds(updateDoc(doc(alice, 'chatRooms', 'r1', 'messages', 'fresh'), { text: LOCKED, enc: edited, editedAt: Date.now() })));
await check('an edit must stay encrypted', () => assertFails(updateDoc(doc(alice, 'chatRooms', 'r1', 'messages', 'fresh'), { text: 'readable words here that are long enough to see clearly', editedAt: Date.now() })));
await check('someone else cannot edit it', () => assertFails(updateDoc(doc(bob, 'chatRooms', 'r1', 'messages', 'fresh'), { enc: edited, editedAt: Date.now() })));
await check('an old message cannot be edited', () => assertFails(updateDoc(doc(alice, 'chatRooms', 'r1', 'messages', 'old'), { enc: edited, editedAt: Date.now() })));
await check('a photo cannot be edited', () => assertFails(updateDoc(doc(alice, 'chatRooms', 'r1', 'messages', 'pic'), { enc: edited, editedAt: Date.now() })));
await check('editing cannot change who sent it', () => assertFails(updateDoc(doc(alice, 'chatRooms', 'r1', 'messages', 'fresh'), { enc: edited, senderId: 'bob' })));
await check('a member can mark the chat seen and show typing', () => assertSucceeds(updateDoc(doc(bob, 'chatRooms', 'r1'), { 'readUpTo.bob': Date.now(), 'readAt.bob': Date.now(), 'typing.bob': Date.now() })));
await check('nobody can fake someone else\'s read receipt', () => assertFails(updateDoc(doc(bob, 'chatRooms', 'r1'), { 'readUpTo.alice': Date.now() })));
await check('nobody can fake someone else typing', () => assertFails(updateDoc(doc(bob, 'chatRooms', 'r1'), { 'typing.alice': Date.now() })));

// View-once media
await env.withSecurityRulesDisabled(async ctx => {
  await setDoc(doc(ctx.firestore(), 'chatRooms', 'r1', 'messages', 'once'), { id: 'once', senderId: 'alice', text: '', type: 'image', timestamp: Date.now(), viewLimit: 1 });
  await setDoc(doc(ctx.firestore(), 'chatRooms', 'r1', 'messages', 'twice'), { id: 'twice', senderId: 'alice', text: '', type: 'video', timestamp: Date.now(), viewLimit: 2 });
});
await check('the receiver can open a view-once photo', () => assertSucceeds(updateDoc(doc(bob, 'chatRooms', 'r1', 'messages', 'once'), { 'viewedBy.bob': 1 })));
await check('but not a second time', () => assertFails(updateDoc(doc(bob, 'chatRooms', 'r1', 'messages', 'once'), { 'viewedBy.bob': 2 })));
await check('nor reset the count', () => assertFails(updateDoc(doc(bob, 'chatRooms', 'r1', 'messages', 'once'), { 'viewedBy.bob': 0 })));
await check('view twice allows exactly two', () => assertSucceeds((async () => {
  await updateDoc(doc(bob, 'chatRooms', 'r1', 'messages', 'twice'), { 'viewedBy.bob': 1 });
  await updateDoc(doc(bob, 'chatRooms', 'r1', 'messages', 'twice'), { 'viewedBy.bob': 2 });
})()));
await check('a third view of view-twice is refused', () => assertFails(updateDoc(doc(bob, 'chatRooms', 'r1', 'messages', 'twice'), { 'viewedBy.bob': 3 })));
await check('views cannot be skipped ahead', () => assertFails(updateDoc(doc(bob, 'chatRooms', 'r1', 'messages', 'twice'), { 'viewedBy.bob': 5 })));
await check('the sender cannot use up views themselves', () => assertFails(updateDoc(doc(alice, 'chatRooms', 'r1', 'messages', 'once'), { 'viewedBy.alice': 1 })));
await check('nobody can change someone else\'s count', () => assertFails(updateDoc(doc(alice, 'chatRooms', 'r1', 'messages', 'once'), { 'viewedBy.bob': 0 })));
await check('a view limit must be 1 or 2', async () => {
  const batch = writeBatch(alice);
  batch.set(doc(alice, 'chatRooms', 'r1', 'messages', 'bad'), { id: 'bad', senderId: 'alice', text: LOCKED, type: 'image', viewLimit: 9, enc });
  batch.update(doc(alice, 'users', 'alice'), { lastMessageAt: serverTimestamp() });
  await assertFails(batch.commit());
});

// Private data and looking people up
await check('your own contacts are readable to you', () => assertSucceeds(getDoc(doc(alice, 'users', 'alice', 'private', 'data'))));
await check('nobody else can read your contacts', () => assertFails(getDoc(doc(eve, 'users', 'alice', 'private', 'data'))));
await check('nobody else can change your contacts', () => assertFails(setDoc(doc(eve, 'users', 'alice', 'private', 'data'), { contacts: [] })));
await check('you can add to your own contacts', () => assertSucceeds(setDoc(doc(bob, 'users', 'bob', 'private', 'data'), { contacts: arrayUnion('alice') }, { merge: true })));
await check('a few people can be looked up at once', () => assertSucceeds(getDocs(query(collection(eve, 'users'), where('uid', 'in', ['alice', 'bob']), limit(30)))));
await check('the whole user list cannot be downloaded', () => assertFails(getDocs(collection(eve, 'users'))));
await check('nor in very large pages', () => assertFails(getDocs(query(collection(eve, 'users'), limit(500)))));

// Groups
await check('a member cannot rename the group', () => assertFails(updateDoc(doc(bob, 'chatRooms', 'g1'), { groupName: 'Mine now' })));
await check('a member cannot add people', () => assertFails(updateDoc(doc(bob, 'chatRooms', 'g1'), { participants: arrayUnion('eve') })));
await check('a member cannot remove someone else', () => assertFails(updateDoc(doc(bob, 'chatRooms', 'g1'), { participants: arrayRemove('carol') })));
await check('a member cannot make themselves admin', () => assertFails(updateDoc(doc(bob, 'chatRooms', 'g1'), { adminId: 'bob' })));
await check('the admin can rename and add people', () => assertSucceeds(updateDoc(doc(alice, 'chatRooms', 'g1'), { groupName: 'Team 2', participants: arrayUnion('eve') })));
await check('anyone can leave', () => assertSucceeds(updateDoc(doc(carol, 'chatRooms', 'g1'), { participants: arrayRemove('carol') })));
await check('a new group cannot name someone else as admin', () => assertFails(setDoc(doc(eve, 'chatRooms', 'g2'), { id: 'g2', type: 'group', participants: ['eve', 'bob'], adminId: 'bob' })));
await check('a new group with yourself as admin is fine', () => assertSucceeds(setDoc(doc(eve, 'chatRooms', 'g3'), { id: 'g3', type: 'group', participants: ['eve', 'bob'], adminId: 'eve' })));
await check('"created the group" notes can be plain', async () => {
  await wait(800);
  const batch = writeBatch(eve);
  batch.set(doc(eve, 'chatRooms', 'g3', 'messages', 's1'), { id: 's1', senderId: 'eve', text: 'eve created "Team"', type: 'system', timestamp: Date.now() });
  batch.update(doc(eve, 'users', 'eve'), { lastMessageAt: serverTimestamp(), msgWindowStart: serverTimestamp(), msgWindowCount: 1 });
  await assertSucceeds(batch.commit());
});
await check('but cannot be used to send a long plain message', async () => {
  await wait(800);
  const batch = writeBatch(eve);
  batch.set(doc(eve, 'chatRooms', 'g3', 'messages', 's2'), { id: 's2', senderId: 'eve', text: 'x'.repeat(1000), type: 'system', timestamp: Date.now() });
  batch.update(doc(eve, 'users', 'eve'), { lastMessageAt: serverTimestamp(), msgWindowCount: increment(1) });
  await assertFails(batch.commit());
});

await env.cleanup();
for (const [status, name] of results) console.log(`${status.padEnd(4)} ${name}`);
const failed = results.filter(r => r[0] !== 'ok').length;
console.log(`\n${results.length - failed} of ${results.length} passed`);
process.exit(failed ? 1 : 0);
