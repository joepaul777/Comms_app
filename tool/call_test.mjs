// End-to-end call tests for the web app, between real headless Chrome windows with
// fake cameras and microphones, against the local Firebase emulators.
//
//   1. firebase emulators:start --only auth,firestore --project demo-comms
//   2. flutter build web -t tool/call_test_main.dart -o build/web_calltest
//   3. serve build/web_calltest on http://127.0.0.1:8770 (any static server)
//   4. node tool/call_test.mjs
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const CHROME = process.env.CHROME || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const APP = process.env.APP || 'http://127.0.0.1:8770/';
const sleep = ms => new Promise(r => setTimeout(r, ms));
const browsers = [];
const devicesOpened = [];

async function openDevice(name, port, { noCamera = false, size = '1200,800', video } = {}) {
  const profile = mkdtempSync(join(tmpdir(), `comms-${name}-`));
  const proc = spawn(CHROME, [
    '--headless=new', '--no-first-run', '--no-default-browser-check', `--user-data-dir=${profile}`,
    `--remote-debugging-port=${port}`, `--window-size=${size}`,
    ...(video ? [`--use-file-for-fake-video-capture=${video}`] : []),
    '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
    '--autoplay-policy=no-user-gesture-required', '--disable-features=WebRtcHideLocalIpsWithMdns',
    'about:blank',
  ], { stdio: 'ignore' });
  browsers.push({ proc, profile });
  let target;
  for (let i = 0; i < 150 && !target; i++) {
    await sleep(200);
    try {
      target = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find(t => t.type === 'page');
    } catch {}
  }
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise(r => ws.addEventListener('open', r));
  let id = 0;
  const pending = new Map();
  const errors = [];
  ws.addEventListener('message', ev => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
    if (m.method === 'Log.entryAdded' && m.params.entry.level === 'error') errors.push(`${m.params.entry.text} ${m.params.entry.url ?? ''}`.slice(0, 300));
    if (m.method === 'Runtime.exceptionThrown') errors.push(m.params.exceptionDetails.exception?.description?.split('\n')[0]);
    if (m.method === 'Runtime.consoleAPICalled' && /fail|error/i.test(JSON.stringify(m.params.args))) {
      errors.push(m.params.args.map(a => a.value ?? '').join(' ').slice(0, 200));
    }
  });
  const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  await send('Runtime.enable');
  await send('Log.enable');
  await send('Page.enable');
  if (noCamera) {
    // Like a computer without a webcam: asking for the camera fails, the microphone works.
    await send('Page.addScriptToEvaluateOnNewDocument', { source: `
      const real = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
      navigator.mediaDevices.getUserMedia = c => c && c.video ? Promise.reject(new DOMException('Requested device not found', 'NotFoundError')) : real(c);` });
  }
  await send('Page.navigate', { url: APP });
  const run = async expression => {
    // Dart errors arrive boxed; unwrap them so the message is readable.
    const wrapped = `(async () => { try { return await (${expression}); } catch (e) { const x = e?.error ?? e; throw new Error(x?.message ?? x?.code ?? (typeof x === "object" ? JSON.stringify(x, Object.getOwnPropertyNames(x)) : String(x))); } })()`;
    const res = await send('Runtime.evaluate', { expression: wrapped, awaitPromise: true, returnByValue: true });
    if (res.result.exceptionDetails) throw new Error(`${name}: ${res.result.exceptionDetails.exception?.description ?? res.result.exceptionDetails.text}`);
    return res.result.result.value;
  };
  for (let i = 0; i < 450; i++) {
    if (await run('typeof window.commsSignIn === "function"').catch(() => false)) break;
    await sleep(200);
  }
  const device = {
    name, errors,
    run,
    async screenshot(file) {
      const shot = await send('Page.captureScreenshot', { format: 'png' });
      (await import('node:fs')).writeFileSync(file, Buffer.from(shot.result.result?.data ?? shot.result.data, 'base64'));
    },
    async drag(from, to) {
      const move = (type, [x, y]) => send('Input.dispatchMouseEvent', { type, x, y, button: 'left', buttons: type === 'mouseReleased' ? 0 : 1, clickCount: 1 });
      await move('mousePressed', from);
      for (let i = 1; i <= 10; i++) await move('mouseMoved', [from[0] + (to[0] - from[0]) * i / 10, from[1] + (to[1] - from[1]) * i / 10]);
      await move('mouseReleased', to);
    },
    state: async () => JSON.parse(await run('commsState()')),
    async signIn(uid) {
      const r = await run(`commsSignIn(${JSON.stringify(uid)})`);
      if (r.startsWith('error')) throw new Error(`${name} sign-in: ${r}`);
      return r;
    },
    call: (uid, video) => run(`commsCall(${JSON.stringify(uid)}, ${video})`),
    accept: () => run('commsAccept()'),
    decline: () => run('commsDecline()'),
    hangUp: () => run('commsHangUp()'),
    async waitFor(test, what, ms = 20000) {
      const until = Date.now() + ms;
      let s;
      while (Date.now() < until) {
        s = await this.state();
        if (test(s)) return s;
        await sleep(250);
      }
      throw new Error(`${name} never got to "${what}"; last state ${JSON.stringify(s)}`);
    },
  };
  device.close = () => proc.kill();
  devicesOpened.push(device);
  return device;
}

const results = [];
async function test(name, body) {
  if (process.env.ONLY && !process.env.ONLY.split("|").some(o => name.includes(o))) return;
  const start = Date.now();
  try {
    await body();
    results.push(`ok   ${name} (${((Date.now() - start) / 1000).toFixed(1)}s)`);
  } catch (e) {
    results.push(`FAIL ${name}: ${e.message}`);
  }
  console.log(results.at(-1));
}

const phase = p => s => s.phase === p;
const idle = s => s.phase === 'idle';
const connectedWith = kinds => s => s.phase === 'connected' && kinds.every(k => (s.remote || []).includes(k));

try {
  // Start from an empty database and no accounts, so nothing from an earlier run (like
  // someone still marked as on a call) gets in the way.
  await fetch('http://127.0.0.1:8080/emulator/v1/projects/demo-comms/databases/(default)/documents', { method: 'DELETE' });
  await fetch('http://127.0.0.1:9099/emulator/v1/projects/demo-comms/accounts', { method: 'DELETE' });
  // Tests run in stages with only the browsers each needs open: a laptop with little
  // free memory otherwise starves them and calls time out for no real reason.
  const alice = await openDevice('alice', 9401);
  const bob = await openDevice('bob', 9402);
  const all = [alice, bob];
  // The sign-in emulator makes up each account's id, so calls use the ids it hands back.
  const uid = { alice: await alice.signIn('alice'), bob: await bob.signIn('bob') };
  await sleep(6000); // home screens load and start listening for calls

  await test('voice call: rings, is answered, both hear each other, hang-up reaches the other side', async () => {
    { const r = await alice.call(uid.bob, false); if (r !== 'ok') throw new Error('could not start: ' + r); }
    await bob.waitFor(phase('incoming'), 'ringing');
    await bob.accept();
    await alice.waitFor(connectedWith(['audio']), 'connected with audio');
    await bob.waitFor(connectedWith(['audio']), 'connected with audio');
    await sleep(3000);
    await alice.waitFor(phase('connected'), 'still connected');
    // Mid-call: another microphone, noise reduction off and on, another speaker.
    const devices = JSON.parse(await alice.run('commsDevices()'));
    const before = await alice.state();
    const other = devices.mics.find(id => id !== before.mic && id !== 'default' && id !== 'communications');
    if (!other) throw new Error(`only one microphone to choose from: ${JSON.stringify(devices.mics)}`);
    await alice.run(`commsSelectMic(${JSON.stringify(other)})`);
    const switched = await alice.waitFor(s => s.mic === other, 'using the other microphone', 8000);
    if (switched.phase !== 'connected' || !(switched.local || []).includes('audio')) throw new Error(`call broke after switching microphone: ${JSON.stringify(switched)}`);
    await alice.run('commsNoise(false)');
    await alice.run('commsNoise(true)');
    if (devices.speakers.length) await alice.run(`commsSelectSpeaker(${JSON.stringify(devices.speakers.at(-1))})`);
    await sleep(2000);
    await alice.waitFor(connectedWith(['audio']), 'still connected after the device changes', 3000);
    await bob.waitFor(connectedWith(['audio']), 'still hearing alice', 3000);
    await alice.hangUp();
    const b = await bob.waitFor(s => s.phase === 'ended' || idle(s), 'call ended');
    if (b.phase === 'ended' && b.message !== 'Call ended') throw new Error(`bob saw "${b.message}"`);
    await bob.waitFor(idle, 'closed');
    await alice.waitFor(idle, 'closed');
  });

  await test('video call: both sides get the other person\'s video and sound', async () => {
    await sleep(11000); // calls are spaced out (spam limit)
    { const r = await bob.call(uid.alice, true); if (r !== 'ok') throw new Error('could not start: ' + r); }
    await alice.waitFor(phase('incoming'), 'ringing');
    await alice.accept();
    await alice.waitFor(connectedWith(['audio', 'video']), 'connected with video');
    await bob.waitFor(connectedWith(['audio', 'video']), 'connected with video');
    await bob.hangUp();
    await alice.waitFor(idle, 'closed');
    await bob.waitFor(idle, 'closed');
  });

  await test('declining shows "Declined" to the caller', async () => {
    await sleep(11000);
    await alice.call(uid.bob, true);
    await bob.waitFor(phase('incoming'), 'ringing');
    await bob.decline();
    const a = await alice.waitFor(s => s.phase === 'ended', 'ended');
    if (a.message !== 'Declined') throw new Error(`alice saw "${a.message}"`);
    await alice.waitFor(idle, 'closed');
  });

  await test('caller cancels: the other side stops ringing', async () => {
    await sleep(11000);
    await bob.call(uid.alice, false);
    await alice.waitFor(phase('incoming'), 'ringing');
    await bob.hangUp();
    const a = await alice.waitFor(s => s.phase === 'ended' || idle(s), 'stopped ringing');
    if (a.phase === 'ended' && a.message !== 'Missed call') throw new Error(`alice saw "${a.message}"`);
  });

  bob.close();
  const carolPhone = await openDevice('carol-1', 9403);
  const carolPc = await openDevice('carol-2', 9404);
  all.push(carolPhone, carolPc);
  uid.carol = await carolPhone.signIn('carol');
  if ((await carolPc.signIn('carol')) !== uid.carol) throw new Error('carol got two different accounts');
  await sleep(6000);

  await test('same account on two devices: both ring, answering on one stops the other, and the call survives', async () => {
    await sleep(11000);
    await alice.call(uid.carol, false);
    await carolPhone.waitFor(phase('incoming'), 'ringing (device 1)');
    await carolPc.waitFor(phase('incoming'), 'ringing (device 2)');
    await carolPhone.accept();
    const other = await carolPc.waitFor(s => s.phase === 'ended' || idle(s), 'stop ringing');
    if (other.phase === 'ended' && other.message !== 'Answered on another device') throw new Error(`device 2 saw "${other.message}"`);
    await alice.waitFor(connectedWith(['audio']), 'connected');
    await carolPhone.waitFor(connectedWith(['audio']), 'connected');
    // Past the ring timeout: nothing on device 2 may end the call.
    await sleep(46000);
    await alice.waitFor(phase('connected'), 'still connected after the ring timeout', 2000);
    await carolPhone.waitFor(phase('connected'), 'still connected after the ring timeout', 2000);
    await carolPhone.hangUp();
    await alice.waitFor(idle, 'closed');
  });

  await test('same account on two devices: declining on one stops both and the caller sees "Declined"', async () => {
    await sleep(11000);
    await alice.call(uid.carol, true);
    await carolPhone.waitFor(phase('incoming'), 'ringing (device 1)');
    await carolPc.waitFor(phase('incoming'), 'ringing (device 2)');
    await carolPc.decline();
    const first = await carolPhone.waitFor(s => s.phase === 'ended' || idle(s), 'stop ringing');
    if (first.phase === 'ended' && first.message !== 'Declined') throw new Error(`device 1 saw "${first.message}"`);
    const b = await alice.waitFor(s => s.phase === 'ended', 'ended');
    if (b.message !== 'Declined') throw new Error(`alice saw "${b.message}"`);
  });

  alice.close();
  carolPhone.close();
  carolPc.close();
  const dave = await openDevice('dave', 9405, { noCamera: true });
  // Chrome's fake test camera can only be opened once per browser, so the no-camera
  // test talks to someone whose camera hasn't been used yet. (Real cameras are fine.)
  const erin = await openDevice('erin', 9406);
  all.push(dave, erin);
  uid.dave = await dave.signIn('dave');
  uid.erin = await erin.signIn('erin');
  await sleep(6000);

  await test('no camera: a video call still connects, with voice one way and video the other', async () => {
    { const r = await dave.call(uid.erin, true); if (r !== 'ok') throw new Error('could not start: ' + r); }
    await erin.waitFor(phase('incoming'), 'ringing');
    await erin.accept();
    try {
      await dave.waitFor(connectedWith(['audio', 'video']), 'seeing and hearing erin');
    } catch (e) {
      throw new Error(`${e.message}; erin was ${JSON.stringify(await erin.state())}`);
    }
    const a = await erin.waitFor(connectedWith(['audio']), 'hearing dave');
    if ((a.remote || []).includes('video')) throw new Error('erin got video from a device without a camera');
    const d = await dave.state();
    if (!(d.local || []).includes('audio') || (d.local || []).includes('video')) throw new Error(`dave sent ${JSON.stringify(d.local)}`);
    await dave.hangUp();
    await erin.waitFor(idle, 'closed');
  });

  // How a video call looks: an upright phone picture on a wide computer screen, the
  // camera switched off, and your own picture snapping to a corner. Saves screenshots
  // to $SHOTS when VIDEO (an upright .y4m clip for the "phone" camera) is set.
  if (process.env.VIDEO && process.env.SHOTS) {
    await test('video call layout between a phone and a computer', async () => {
      const shots = process.env.SHOTS;
      dave.close();
      erin.close();
      const phone = await openDevice('phone', 9407, { size: '400,860', video: process.env.VIDEO });
      const pc = await openDevice('pc', 9408, { size: '1280,800', video: process.env.PC_VIDEO });
      all.push(phone, pc);
      const phoneId = await phone.signIn('phone');
      await pc.signIn('pc');
      await sleep(6000);
      { const r = await pc.call(phoneId, true); if (r !== 'ok') throw new Error('could not start: ' + r); }
      await phone.waitFor(phase('incoming'), 'ringing');
      await phone.accept();
      await pc.waitFor(connectedWith(['audio', 'video']), 'connected');
      await phone.waitFor(connectedWith(['audio', 'video']), 'connected');
      await sleep(4000);
      console.log('pc state', JSON.stringify(await pc.state()));
      console.log('phone state', JSON.stringify(await phone.state()));
      console.log('pc camera', await pc.run(`(async () => (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === 'videoinput').map(d => d.label).join(',') || 'none')()`));
      await pc.screenshot(`${shots}/1-pc-sees-phone.png`);
      // The pop-out button (top left, next to call settings).
      await pc.drag([88, 34], [88, 34]);
      await sleep(1500);
      console.log('pop-out', await pc.run(`JSON.stringify({ supported: document.pictureInPictureEnabled, open: !!document.pictureInPictureElement, size: document.pictureInPictureElement ? document.pictureInPictureElement.videoWidth + 'x' + document.pictureInPictureElement.videoHeight : null })`));
      await pc.run(`document.pictureInPictureElement ? document.exitPictureInPicture().then(() => 'closed') : 'none'`);
      await phone.screenshot(`${shots}/2-phone-sees-pc.png`);
      // Drag the computer's own picture from the top right towards the bottom left.
      await pc.drag([1100, 120], [300, 600]);
      await sleep(1200);
      await pc.screenshot(`${shots}/3-pc-self-view-moved.png`);
      // The call settings sheet (button at the top left).
      await pc.drag([36, 36], [36, 36]);
      await sleep(1500);
      await pc.screenshot(`${shots}/3b-pc-call-settings.png`);
      await pc.run(`(() => { document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })); return 'ok'; })()`);
      await pc.drag([640, 60], [640, 60]);
      await sleep(800);
      await phone.run('commsToggleCamera()');
      await sleep(3000);
      await pc.screenshot(`${shots}/4-pc-when-phone-camera-off.png`);
      await phone.screenshot(`${shots}/5-phone-own-camera-off.png`);
      await pc.hangUp();
    });
  }

  const errors = all.flatMap(d => d.errors.map(e => `${d.name}: ${e}`));
  if (errors.length) console.log('\nconsole errors:\n' + [...new Set(errors)].join('\n'));
} catch (e) {
  for (const d of devicesOpened) for (const err of d.errors) console.log(`${d.name}: ${err}`);
  results.push(`FAIL setup: ${e.message}`);
  console.log(results.at(-1));
} finally {
  for (const b of browsers) {
    b.proc.kill();
  }
  await sleep(1000);
  for (const b of browsers) {
    try { rmSync(b.profile, { recursive: true, force: true }); } catch {}
  }
  const failed = results.filter(r => r.startsWith('FAIL')).length;
  console.log(`\n${results.length - failed} of ${results.length} passed`);
  process.exit(failed ? 1 : 0);
}
