// Utilidades para las pruebas de integración contra Supabase LOCAL (CLI + Docker). NUNCA contra un
// proyecto remoto: se niega a funcionar si la URL no es local. Las cuentas de prueba se crean con
// correos únicos (*.e4.test) y contraseñas aleatorias en cada ejecución; no hay credenciales fijas.
//
// Variables (las da `supabase status -o env` en la carpeta del Supabase local):
//   API_URL, ANON_KEY, SERVICE_ROLE_KEY, DB_URL, MAILPIT_URL
import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';

export const env = (k) => {
  const v = process.env[k];
  if (!v) throw new Error(`Falta la variable ${k} (ejecuta: eval "$(supabase status -o env)")`);
  return v;
};
export const API = env('API_URL').replace(/\/$/, '');
export const ANON = env('ANON_KEY');
export const SERVICE = env('SERVICE_ROLE_KEY');
export const DB = env('DB_URL');
export const MAIL = env('MAILPIT_URL').replace(/\/$/, '');
for (const [k, v] of [['API_URL', API], ['DB_URL', DB], ['MAILPIT_URL', MAIL]]) {
  if (!/^(https?|postgresql):\/\/([^@/]*@)?(127\.0\.0\.1|localhost)(:\d+)?(\/|$)/.test(v)) {
    throw new Error(`${k} no es local (${v.replace(/\/\/[^@]*@/, '//***@')}). Estas pruebas solo se ejecutan contra Supabase LOCAL.`);
  }
}

export const RUN = `${Date.now().toString(36)}${randomBytes(2).toString('hex')}`;
export const email = (name) => `${name}-${RUN}@e4.test`;
const passwords = new Map();
export const password = (mail) => {
  if (!passwords.has(mail)) passwords.set(mail, `Pw-${randomBytes(12).toString('hex')}`);
  return passwords.get(mail);
};
export const PIAZZA = '5e5e0000-0000-4000-8000-000000000001';

// ---------- Resultados ----------
export const results = [];
export const ok = (cond, name, detail = '') => {
  results.push({ ok: !!cond, name, detail });
  console.log(`${cond ? 'OK   ' : 'FALLO'} ${name}${!cond && detail ? ` — ${typeof detail === 'string' ? detail : JSON.stringify(detail)}` : ''}`);
};
export const summary = () => {
  const failed = results.filter((r) => !r.ok).length;
  console.log(`\n${results.length - failed} correctas, ${failed} fallidas`);
  return failed;
};

// ---------- Base de datos (como postgres, solo para preparar casos y comprobar estados) ----------
export const sql = (query) => execFileSync('psql', [DB, '-v', 'ON_ERROR_STOP=1', '-q', '-X', '-tA', '-c', query], { encoding: 'utf8' }).trim();

// ---------- Supabase Auth ----------
async function json(r) {
  const t = await r.text();
  try { return t ? JSON.parse(t) : null; } catch { return t; }
}
/** Cuenta confirmada creada con la API de administración (como haría el SQL Editor / panel). */
export async function createConfirmedUser(mail) {
  const r = await fetch(`${API}/auth/v1/admin/users`, {
    method: 'POST', headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'content-type': 'application/json' },
    body: JSON.stringify({ email: mail, password: password(mail), email_confirm: true }),
  });
  const b = await json(r);
  if (!r.ok) throw new Error(`No se pudo crear ${mail}: ${JSON.stringify(b)}`);
  return b.id;
}
export async function login(mail) {
  const r = await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: 'POST', headers: { apikey: ANON, 'content-type': 'application/json' }, body: JSON.stringify({ email: mail, password: password(mail) }),
  });
  const b = await json(r);
  if (!r.ok) throw new Error(`No se pudo iniciar sesión con ${mail}: ${JSON.stringify(b)}`);
  return b.access_token;
}
export async function setPassword(token, mail) {
  const r = await fetch(`${API}/auth/v1/user`, {
    method: 'PUT', headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ password: password(mail) }),
  });
  return { status: r.status, body: await json(r) };
}
export async function getUser(token) {
  const r = await fetch(`${API}/auth/v1/user`, { headers: { apikey: ANON, Authorization: `Bearer ${token}` } });
  return { status: r.status, body: await json(r) };
}

// ---------- API (PostgREST y Edge Functions) ----------
export async function rpc(token, fn, args = {}) {
  const r = await fetch(`${API}/rest/v1/rpc/${fn}`, {
    method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${token ?? ANON}`, 'content-type': 'application/json' }, body: JSON.stringify(args),
  });
  return { status: r.status, body: await json(r) };
}
export async function rest(token, path, init = {}) {
  const r = await fetch(`${API}/rest/v1/${path}`, {
    ...init, headers: { apikey: ANON, Authorization: `Bearer ${token ?? ANON}`, 'content-type': 'application/json', Prefer: 'return=representation', ...(init.headers ?? {}) },
  });
  return { status: r.status, body: await json(r) };
}
/** Edge Function «invitations» con el JWT de quien llama (token null: sin cabecera Authorization). */
export async function invite(token, body, extraHeaders = {}) {
  const headers = { apikey: ANON, 'content-type': 'application/json', ...extraHeaders };
  if (token) headers.Authorization = `Bearer ${token}`;
  const r = await fetch(`${API}/functions/v1/invitations`, { method: 'POST', headers, body: JSON.stringify(body) });
  return { status: r.status, body: await json(r), headers: Object.fromEntries(r.headers) };
}
export async function recover(secret, extraHeaders = {}) {
  const headers = { 'content-type': 'application/json', ...extraHeaders };
  if (secret !== null) headers['x-turestaurante-recovery'] = secret;
  const r = await fetch(`${API}/functions/v1/invitations-recovery`, { method: 'POST', headers, body: JSON.stringify({ action: 'recover' }) });
  return { status: r.status, body: await json(r) };
}

// ---------- Mailpit (buzón local de Supabase) ----------
export async function mailsTo(mail) {
  const r = await fetch(`${MAIL}/api/v1/search?query=${encodeURIComponent(`to:"${mail}"`)}`);
  const b = await r.json();
  return b.messages ?? [];
}
/** Espera a que haya `n` correos para `mail` (el envío va en segundo plano). */
export async function waitMails(mail, n = 1, timeoutMs = 20000) {
  const end = Date.now() + timeoutMs;
  let list = [];
  while (Date.now() < end) {
    list = await mailsTo(mail);
    if (list.length >= n) return list;
    await sleep(400);
  }
  return list;
}
export async function inviteLinks(mail) {
  const out = [];
  for (const m of await mailsTo(mail)) {
    const r = await fetch(`${MAIL}/api/v1/message/${m.ID}`);
    const b = await r.json();
    const text = `${b.Text ?? ''} ${b.HTML ?? ''}`.replace(/&amp;/g, '&');
    const link = text.match(/https?:\/\/[^\s"'<>]+\/auth\/v1\/verify\?[^\s"'<>]+/);
    if (link) out.push({ id: m.ID, created: m.Created, link: link[0], subject: b.Subject });
  }
  return out.sort((a, b) => Date.parse(a.created) - Date.parse(b.created));
}
/** Sigue el enlace del correo como haría el navegador, sin seguir la última redirección a la app. */
export async function followLink(link) {
  const r = await fetch(link, { redirect: 'manual' });
  const location = r.headers.get('location') ?? '';
  const hash = new URLSearchParams(location.split('#')[1] ?? '');
  const query = new URL(location || 'http://x').searchParams;
  return { status: r.status, location, accessToken: hash.get('access_token'), type: hash.get('type'), error: hash.get('error') ?? query.get('error'), errorCode: hash.get('error_code') ?? query.get('error_code') };
}
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const sameExceptId = (a, b) => JSON.stringify({ ...a, invitationId: 'x' }) === JSON.stringify({ ...b, invitationId: 'x' });
