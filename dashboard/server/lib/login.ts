/**
 * Signing in to the console: Face ID / Touch ID (passkeys), or the admin
 * password from deploy/set-admin-password.sh. Either sets a session cookie.
 *
 * Passkeys are checked with node:crypto alone. The browser hands over the
 * public key itself (getPublicKey()) at registration, so there is no CBOR
 * attestation to parse; attestation is 'none' anyway, as there is no device
 * list to check it against.
 *
 * Kept in CONSOLE_STATE_DIR (a host folder, see k8s/dashboard.yaml):
 *   passkeys.json    the registered devices' public keys
 *   session.key      what session cookies are signed with
 *   password-login   "off" refuses the password; anything else, or no file,
 *                    allows it. Written by deploy/console-login.sh.
 */

import { createHash, createHmac, createPublicKey, randomBytes, timingSafeEqual, verify } from 'node:crypto';
import { readFile, rename, writeFile } from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { join } from 'node:path';

const STATE_DIR = process.env.CONSOLE_STATE_DIR ?? '/var/lib/pi-console';
const PASSKEYS = join(STATE_DIR, 'passkeys.json');
const KEY_FILE = join(STATE_DIR, 'session.key');
const MODE_FILE = join(STATE_DIR, 'password-login');

const PASSWORD = process.env.CONSOLE_PASSWORD ?? '';
const COOKIE = 'pi_session';
/** A day: Face ID once a day per device. */
const SESSION_MS = 24 * 60 * 60 * 1000;
const CHALLENGE_MS = 2 * 60 * 1000;

/** ES256, Ed25519, RS256: what Apple, Android, Windows and keys use. */
const ALGS = [-7, -8, -257];

interface Passkey {
  id: string;
  key: string;
  alg: number;
  added: string;
}

const b64u = (b: Buffer) => b.toString('base64url');
const fromB64u = (s: unknown) => Buffer.from(String(s ?? ''), 'base64url');
const sha256 = (b: Buffer | string) => createHash('sha256').update(b).digest();

// --- session ---------------------------------------------------------------

let sessionKey: Buffer | null = null;

/** Made once and kept, so a restart does not sign everyone out. If the folder
 *  is not writable, one per process: sessions then end with the pod. */
const signingKey = async (): Promise<Buffer> => {
  if (sessionKey) return sessionKey;
  try {
    sessionKey = await readFile(KEY_FILE);
    if (sessionKey.length >= 32) return sessionKey;
  } catch {
    /* first run */
  }
  sessionKey = randomBytes(32);
  await writeFile(KEY_FILE, sessionKey, { mode: 0o600 }).catch(() => {
    console.warn(`cannot write ${KEY_FILE}: sessions will not survive a restart`);
  });
  return sessionKey;
};

const sign = async (body: string) => createHmac('sha256', await signingKey()).update(body).digest('base64url');

const cookieOf = (req: IncomingMessage, name: string): string | null => {
  for (const part of String(req.headers.cookie ?? '').split(';')) {
    const [k, ...v] = part.trim().split('=');
    if (k === name) return v.join('=');
  }
  return null;
};

export const signedIn = async (req: IncomingMessage): Promise<boolean> => {
  const value = cookieOf(req, COOKIE);
  if (!value) return false;
  const [expires, mac] = value.split('.');
  if (!expires || !mac || Number(expires) < Date.now()) return false;
  const want = Buffer.from(await sign(expires));
  const got = Buffer.from(mac);
  return got.length === want.length && timingSafeEqual(got, want);
};

const startSession = async (res: ServerResponse) => {
  const expires = String(Date.now() + SESSION_MS);
  // Not Secure: the console is also served over plain http inside the tailnet,
  // which WireGuard already encrypts, and a Secure cookie would never come back
  // from there. HttpOnly keeps it from page scripts; Strict from other sites.
  res.setHeader(
    'Set-Cookie',
    `${COOKIE}=${expires}.${await sign(expires)}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${SESSION_MS / 1000}`,
  );
};

// --- stored state ----------------------------------------------------------

const loadPasskeys = async (): Promise<Passkey[]> => {
  try {
    return JSON.parse(await readFile(PASSKEYS, 'utf8')) as Passkey[];
  } catch {
    return [];
  }
};

const savePasskeys = async (keys: Passkey[]) => {
  // Through a temporary file, so a crash mid-write cannot leave half a list
  // and lock everyone out.
  const tmp = `${PASSKEYS}.new`;
  await writeFile(tmp, JSON.stringify(keys, null, 2), { mode: 0o600 });
  await rename(tmp, PASSKEYS);
};

const passwordAllowed = async (): Promise<boolean> => {
  if (!PASSWORD) return false;
  try {
    return (await readFile(MODE_FILE, 'utf8')).trim() !== 'off';
  } catch {
    return true;
  }
};

// --- challenges ------------------------------------------------------------

/** One replica (k8s/dashboard.yaml), so memory is the whole store. */
const challenges = new Map<string, number>();

const newChallenge = (): string => {
  const now = Date.now();
  for (const [c, expires] of challenges) if (expires < now) challenges.delete(c);
  if (challenges.size > 100) challenges.clear();
  const challenge = b64u(randomBytes(32));
  challenges.set(challenge, now + CHALLENGE_MS);
  return challenge;
};

/** Each challenge answers once. */
const takeChallenge = (challenge: string): boolean => {
  const expires = challenges.get(challenge);
  challenges.delete(challenge);
  return expires !== undefined && expires >= Date.now();
};

// --- WebAuthn --------------------------------------------------------------

/** The site a passkey belongs to is the name in the address bar. */
const relyingParty = (req: IncomingMessage) => String(req.headers.host ?? '').replace(/:\d+$/, '');

/** Checks what every ceremony shares: the browser's own record of what it was
 *  asked, where, and the authenticator's flags. Returns the reason on failure. */
const checkCeremony = (
  req: IncomingMessage,
  type: 'webauthn.create' | 'webauthn.get',
  clientDataJSON: Buffer,
  authData: Buffer,
): string | null => {
  let client: { type?: string; challenge?: string; origin?: string };
  try {
    client = JSON.parse(clientDataJSON.toString('utf8'));
  } catch {
    return 'unreadable client data';
  }
  const rp = relyingParty(req);
  if (client.type !== type) return 'wrong ceremony';
  if (!client.challenge || !takeChallenge(client.challenge)) return 'expired, try again';
  if (client.origin !== `https://${rp}`) return 'wrong address';
  if (authData.length < 37 || !authData.subarray(0, 32).equals(sha256(rp))) return 'wrong site';
  const flags = authData[32];
  // User present and user verified: Face ID, Touch ID or the device PIN ran.
  if ((flags & 0x05) !== 0x05) return 'Face ID / Touch ID did not run';
  return null;
};

const verifySignature = (key: Passkey, data: Buffer, signature: Buffer): boolean => {
  const publicKey = createPublicKey({ key: fromB64u(key.key), format: 'der', type: 'spki' });
  // Ed25519 hashes internally; the other two are SHA-256. ES256 signatures are
  // DER, which is node's default for EC keys.
  return verify(key.alg === -8 ? null : 'sha256', data, publicKey, signature);
};

// --- page and routes -------------------------------------------------------

const sendJson = (res: ServerResponse, status: number, body: unknown) => {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(body));
};

const readJson = async (req: IncomingMessage): Promise<Record<string, unknown>> => {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 16 * 1024) throw new Error('request body too large');
    chunks.push(chunk as Buffer);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
};

/** Handles /login and /auth/*. Returns false for anything else. */
export const handleLogin = async (req: IncomingMessage, url: URL, res: ServerResponse): Promise<boolean> => {
  if (url.pathname === '/login') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(LOGIN_PAGE);
    return true;
  }
  if (!url.pathname.startsWith('/auth/')) return false;

  // What the page needs to draw itself, and a fresh challenge for whichever
  // button is pressed.
  if (url.pathname === '/auth/options' && req.method === 'GET') {
    const keys = await loadPasskeys();
    sendJson(res, 200, {
      challenge: newChallenge(),
      passkeys: keys.map((k) => k.id),
      password: await passwordAllowed(),
      configured: Boolean(PASSWORD) || keys.length > 0,
      signedIn: await signedIn(req),
      rp: relyingParty(req),
    });
    return true;
  }

  // Same rule as /api/: a change must carry the console's own header.
  if (req.method !== 'POST' || req.headers['x-pi-console'] !== '1') {
    sendJson(res, 403, { error: 'refused' });
    return true;
  }
  const body = await readJson(req);

  if (url.pathname === '/auth/password') {
    if (!(await passwordAllowed())) {
      sendJson(res, 403, { error: 'Password sign-in is off. Use Face ID / Touch ID.' });
      return true;
    }
    const ok = timingSafeEqual(sha256(String(body.password ?? '')), sha256(PASSWORD));
    if (!ok) {
      sendJson(res, 401, { error: 'Wrong password' });
      return true;
    }
    await startSession(res);
    sendJson(res, 200, { ok: true });
    return true;
  }

  if (url.pathname === '/auth/passkey') {
    const keys = await loadPasskeys();
    const key = keys.find((k) => k.id === body.id);
    if (!key) {
      sendJson(res, 401, { error: 'This device is not registered' });
      return true;
    }
    const clientDataJSON = fromB64u(body.clientDataJSON);
    const authData = fromB64u(body.authenticatorData);
    const problem = checkCeremony(req, 'webauthn.get', clientDataJSON, authData);
    const data = Buffer.concat([authData, sha256(clientDataJSON)]);
    if (problem || !verifySignature(key, data, fromB64u(body.signature))) {
      sendJson(res, 401, { error: problem ?? 'Signature did not match' });
      return true;
    }
    await startSession(res);
    sendJson(res, 200, { ok: true });
    return true;
  }

  // Adding a device needs a session already: the password, or a passkey from
  // a device added before.
  if (url.pathname === '/auth/register') {
    if (!(await signedIn(req))) {
      sendJson(res, 401, { error: 'Sign in first' });
      return true;
    }
    const clientDataJSON = fromB64u(body.clientDataJSON);
    const authData = fromB64u(body.authenticatorData);
    const problem = checkCeremony(req, 'webauthn.create', clientDataJSON, authData);
    const alg = Number(body.alg);
    if (problem || !ALGS.includes(alg) || !body.id || !body.publicKey) {
      sendJson(res, 400, { error: problem ?? 'Unsupported key' });
      return true;
    }
    try {
      createPublicKey({ key: fromB64u(body.publicKey), format: 'der', type: 'spki' });
    } catch {
      sendJson(res, 400, { error: 'Unreadable public key' });
      return true;
    }
    const keys = await loadPasskeys();
    if (!keys.some((k) => k.id === body.id)) {
      keys.push({ id: String(body.id), key: String(body.publicKey), alg, added: new Date().toISOString() });
      try {
        await savePasskeys(keys);
      } catch {
        sendJson(res, 500, { error: `Cannot save to ${STATE_DIR}. Re-run deploy/install-dashboard-k8s.sh` });
        return true;
      }
    }
    sendJson(res, 200, { ok: true, devices: keys.length });
    return true;
  }

  sendJson(res, 404, { error: 'no such endpoint' });
  return true;
};

const LOGIN_PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>homelab sign in</title>
<style>
  :root { color-scheme: light dark; --bg: #f4f4f5; --card: #fff; --text: #18181b; --muted: #71717a; --line: #d4d4d8; --accent: #2563eb; --bad: #dc2626; }
  @media (prefers-color-scheme: dark) { :root { --bg: #09090b; --card: #18181b; --text: #f4f4f5; --muted: #a1a1aa; --line: #3f3f46; --accent: #3b82f6; --bad: #f87171; } }
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--bg); color: var(--text); font: 16px/1.4 system-ui, -apple-system, sans-serif; padding: 16px; }
  main { width: 100%; max-width: 340px; background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 24px; display: grid; gap: 12px; }
  h1 { margin: 0 0 4px; font-size: 20px; }
  button, input { width: 100%; font: inherit; padding: 12px; border-radius: 10px; border: 1px solid var(--line); background: var(--card); color: var(--text); }
  button { cursor: pointer; }
  button.primary { background: var(--accent); border-color: var(--accent); color: #fff; font-weight: 600; }
  p { margin: 0; color: var(--muted); font-size: 14px; }
  #msg { color: var(--bad); min-height: 1.4em; }
  [hidden] { display: none !important; }
</style>
</head>
<body>
<main>
  <h1>homelab</h1>
  <button id="bio" class="primary" hidden>Sign in with Face ID / Touch ID</button>
  <form id="pw" hidden>
    <input id="pass" type="password" autocomplete="current-password" placeholder="Admin password" required>
    <button type="submit">Sign in with password</button>
  </form>
  <div id="add" hidden>
    <p>Use Face ID / Touch ID on this device next time?</p>
    <button id="addBtn" class="primary" style="margin-top:12px">Set up Face ID / Touch ID</button>
    <button id="skip" style="margin-top:8px">Not now</button>
  </div>
  <p id="info"></p>
  <p id="msg"></p>
</main>
<script>
const $ = (id) => document.getElementById(id);
const enc = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
const dec = (s) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
const say = (text) => { $('msg').textContent = text || ''; };
const canBio = window.isSecureContext && 'PublicKeyCredential' in window;
const home = () => location.replace('/');
const post = async (path, body) => {
  const res = await fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Pi-Console': '1' }, body: JSON.stringify(body) });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || 'failed');
  return data;
};
const options = async () => (await fetch('/auth/options', { cache: 'no-store' })).json();

async function signInBio() {
  say('');
  try {
    const o = await options();
    const cred = await navigator.credentials.get({ publicKey: {
      challenge: dec(o.challenge), rpId: o.rp, userVerification: 'required', timeout: 60000,
      allowCredentials: o.passkeys.map((id) => ({ type: 'public-key', id: dec(id) })),
    } });
    await post('/auth/passkey', {
      id: cred.id,
      clientDataJSON: enc(cred.response.clientDataJSON),
      authenticatorData: enc(cred.response.authenticatorData),
      signature: enc(cred.response.signature),
    });
    home();
  } catch (e) { say(e.name === 'NotAllowedError' ? 'Cancelled' : e.message); }
}

async function addDevice() {
  say('');
  try {
    const o = await options();
    const cred = await navigator.credentials.create({ publicKey: {
      challenge: dec(o.challenge),
      rp: { id: o.rp, name: 'homelab' },
      user: { id: new TextEncoder().encode('homelab-admin'), name: 'admin', displayName: 'homelab admin' },
      pubKeyCredParams: [-7, -8, -257].map((alg) => ({ type: 'public-key', alg })),
      authenticatorSelection: { residentKey: 'preferred', userVerification: 'required' },
      excludeCredentials: o.passkeys.map((id) => ({ type: 'public-key', id: dec(id) })),
      attestation: 'none', timeout: 60000,
    } });
    const r = cred.response;
    if (!r.getPublicKey) throw new Error('This browser is too old for Face ID sign-in');
    await post('/auth/register', {
      id: cred.id,
      clientDataJSON: enc(r.clientDataJSON),
      authenticatorData: enc(r.getAuthenticatorData()),
      publicKey: enc(r.getPublicKey()),
      alg: r.getPublicKeyAlgorithm(),
    });
    home();
  } catch (e) {
    say(e.name === 'InvalidStateError' ? 'This device is already set up' : e.name === 'NotAllowedError' ? 'Cancelled' : e.message);
  }
}

$('bio').onclick = signInBio;
$('addBtn').onclick = addDevice;
$('skip').onclick = home;
$('pw').onsubmit = async (ev) => {
  ev.preventDefault();
  say('');
  try {
    await post('/auth/password', { password: $('pass').value });
    if (canBio) { $('pw').hidden = true; $('bio').hidden = true; $('add').hidden = false; } else home();
  } catch (e) { say(e.message); }
};

(async () => {
  const o = await options();
  if (!o.configured) { $('info').textContent = 'No sign-in set up. On the PC: sudo bash deploy/set-admin-password.sh'; return; }
  if (o.signedIn && new URLSearchParams(location.search).has('add')) { $('add').hidden = false; return; }
  if (o.signedIn) return home();
  $('bio').hidden = !(canBio && o.passkeys.length);
  $('pw').hidden = !o.password;
  if (!canBio && o.passkeys.length) $('info').textContent = 'Face ID / Touch ID needs the https:// address.';
  if (!o.password && !(canBio && o.passkeys.length)) $('info').textContent = 'Password sign-in is off. Open the https:// address on a device with Face ID / Touch ID set up.';
})();
</script>
</body>
</html>
`;
