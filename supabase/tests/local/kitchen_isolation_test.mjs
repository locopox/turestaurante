// Prueba de AISLAMIENTO entre restaurantes con una sesión real de Supabase Auth.
//
// Un usuario de cocina asignado SOLO a un restaurante:
//   - puede consultar la cocina de su restaurante (public.kitchen_orders → 200);
//   - recibe un rechazo al consultar la cocina de otro restaurante (403, código 42501).
//
// Seguridad:
//   - Solo contra Supabase LOCAL (127.0.0.1 o localhost): con cualquier otra URL se detiene sin conectar.
//   - Solo con la clave PÚBLICA (anon o sb_publishable_…): se niega a usar una clave secreta o service_role.
//   - La contraseña se pide en la terminal SIN mostrarse y nunca se guarda ni se lee de ningún archivo.
//   - No muestra ni registra contraseñas, claves ni tokens. No modifica datos (solo consulta), y al terminar
//     cierra la sesión que ha abierto.
//
// Configuración: supabase/tests/local/.env.local (ignorado por git), a partir de isolation.env.example.
// Uso: npm run test:local:isolation
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const CONFIG_FILE = join(HERE, '.env.local');

function stop(message, code = 2) {
  console.error(`\nDETENIDO: ${message}`);
  process.exit(code);
}

// ---------- Configuración (sin contraseñas) ----------
function readConfigFile() {
  if (!existsSync(CONFIG_FILE)) return {};
  const out = {};
  for (const raw of readFileSync(CONFIG_FILE, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const i = line.indexOf('=');
    if (i < 1) continue;
    out[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/^["']|["']$/g, '');
  }
  return out;
}
const fileConfig = readConfigFile();
// La contraseña NUNCA se acepta desde un archivo ni desde variables de entorno.
for (const k of [...Object.keys(fileConfig), ...Object.keys(process.env)]) {
  if (/PASS(WORD)?|CONTRASE/i.test(k) && /KITCHEN|COCINA|ISOLATION|AISLAMIENTO/i.test(k)) {
    stop(`la variable «${k}» parece una contraseña. Bórrala: la contraseña solo se escribe en la terminal cuando la prueba la pide.`);
  }
}
const cfg = (k, def) => (process.env[k] ?? fileConfig[k] ?? def ?? '').trim();

const SUPABASE_URL = cfg('SUPABASE_URL', 'http://127.0.0.1:54321').replace(/\/$/, '');
const PUBLIC_KEY = cfg('SUPABASE_PUBLIC_KEY');
const KITCHEN_EMAIL = cfg('KITCHEN_EMAIL');
const OWN_NAME = cfg('OWN_RESTAURANT_NAME', 'La Piazza');
const FOREIGN_NAME = cfg('FOREIGN_RESTAURANT_NAME', 'Restaurante Aislamiento PRUEBA');

// Exclusivamente Supabase LOCAL.
let parsed;
try {
  parsed = new URL(SUPABASE_URL);
} catch {
  stop('SUPABASE_URL no es una dirección válida.');
}
if (!['http:', 'https:'].includes(parsed.protocol) || !['127.0.0.1', 'localhost'].includes(parsed.hostname) || parsed.pathname !== '/') {
  stop('SUPABASE_URL no es un Supabase LOCAL (debe ser http://127.0.0.1:54321 o similar). Esta prueba nunca se conecta a un proyecto remoto.');
}

// Solo la clave PÚBLICA.
function jwtRole(key) {
  try {
    return JSON.parse(Buffer.from(key.split('.')[1], 'base64url').toString('utf8')).role ?? null;
  } catch {
    return null;
  }
}
if (!PUBLIC_KEY) stop('falta SUPABASE_PUBLIC_KEY en supabase/tests/local/.env.local (la clave «Publishable» o «anon» que muestra `supabase status`).');
if (PUBLIC_KEY.startsWith('sb_secret_') || jwtRole(PUBLIC_KEY) === 'service_role') {
  stop('SUPABASE_PUBLIC_KEY contiene una clave SECRETA (service_role). Esta prueba solo usa la clave pública: cámbiala por la «Publishable» o «anon».');
}
if (!PUBLIC_KEY.startsWith('sb_publishable_') && jwtRole(PUBLIC_KEY) !== 'anon') {
  stop('SUPABASE_PUBLIC_KEY no parece una clave pública de Supabase («sb_publishable_…» o «anon»).');
}
if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(KITCHEN_EMAIL)) stop('falta KITCHEN_EMAIL (correo del usuario de cocina) en supabase/tests/local/.env.local.');
if (OWN_NAME === FOREIGN_NAME) stop('OWN_RESTAURANT_NAME y FOREIGN_RESTAURANT_NAME deben ser restaurantes distintos.');

// ---------- Contraseña oculta ----------
function askHidden(question) {
  return new Promise((resolve, reject) => {
    const input = process.stdin;
    if (!input.isTTY) {
      reject(new Error('la contraseña se tiene que escribir en una terminal interactiva (no se acepta por tuberías ni archivos).'));
      return;
    }
    process.stdout.write(question);
    let value = '';
    input.setRawMode(true);
    input.resume();
    input.setEncoding('utf8');
    const done = (err) => {
      input.setRawMode(false);
      input.pause();
      input.removeListener('data', onData);
      process.stdout.write('\n');
      if (err) reject(err);
      else resolve(value);
    };
    const onData = (chunk) => {
      for (const ch of chunk) {
        if (ch === '\r' || ch === '\n') return done();
        if (ch === '\u0003') return done(new Error('cancelado por el usuario.')); // Ctrl+C
        if (ch === '\u007f' || ch === '\b') value = value.slice(0, -1); // Retroceso
        else if (ch >= ' ') value += ch;
      }
    };
    input.on('data', onData);
  });
}

// ---------- Llamadas a Supabase (sin registrar cabeceras ni cuerpos sensibles) ----------
async function call(path, { method = 'GET', token = null, body } = {}) {
  const headers = { apikey: PUBLIC_KEY, 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  let res;
  try {
    res = await fetch(`${SUPABASE_URL}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  } catch {
    stop(`no hay conexión con ${SUPABASE_URL}. ¿Está Supabase local en marcha (supabase start)?`);
  }
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  return { status: res.status, json };
}

const results = [];
function check(ok, name, detail = '') {
  results.push(ok);
  console.log(`${ok ? 'OK   ' : 'FALLO'} ${name}${!ok && detail ? ` — ${detail}` : ''}`);
}
/** Detalle seguro de una respuesta de error: solo estado, código y mensaje del servidor. */
const brief = (r) => `HTTP ${r.status}${r.json?.code ? `, código ${r.json.code}` : ''}${r.json?.message ? `: ${r.json.message}` : ''}`;

async function findRestaurant(name) {
  const r = await call(`/rest/v1/restaurants?select=id,name&name=eq.${encodeURIComponent(name)}`);
  if (r.status !== 200 || !Array.isArray(r.json)) stop(`no se pudo leer la lista de restaurantes (${brief(r)}).`);
  if (r.json.length !== 1) stop(`debe existir exactamente un restaurante llamado «${name}» (hay ${r.json.length}).`);
  return r.json[0].id;
}

// ---------- Prueba ----------
console.log(`Prueba de aislamiento de cocina contra Supabase LOCAL (${SUPABASE_URL})`);
console.log(`Usuario de cocina: ${KITCHEN_EMAIL}`);
console.log(`Restaurante propio: «${OWN_NAME}» · restaurante ajeno: «${FOREIGN_NAME}»\n`);

const ownId = await findRestaurant(OWN_NAME);
const foreignId = await findRestaurant(FOREIGN_NAME);

let password;
try {
  password = await askHidden(`Contraseña de ${KITCHEN_EMAIL} (no se mostrará): `);
} catch (e) {
  stop(e.message);
}
if (!password) stop('no se ha escrito ninguna contraseña.');

// Sesión REAL de Supabase Auth, con la clave pública.
const login = await call('/auth/v1/token?grant_type=password', { method: 'POST', body: { email: KITCHEN_EMAIL, password } });
password = null; // no se conserva más tiempo del necesario
if (login.status !== 200 || !login.json?.access_token) {
  const reason = login.json?.error_code ?? login.json?.code ?? login.json?.error ?? `HTTP ${login.status}`;
  stop(`no se pudo iniciar sesión (${reason}). Revisa el correo y la contraseña.`, 1);
}
let token = login.json.access_token;
check(true, 'sesión real iniciada en Supabase Auth (clave pública, sin service_role)');

try {
  // Control: el usuario es de cocina en su restaurante y no pertenece al ajeno.
  const m = await call('/rest/v1/rpc/my_memberships', { method: 'POST', token, body: {} });
  const memberships = Array.isArray(m.json) ? m.json : [];
  check(m.status === 200 && memberships.some((x) => x.restaurant_id === ownId && x.role === 'kitchen'),
    `el usuario tiene la función «cocina» en «${OWN_NAME}»`, brief(m));
  check(!memberships.some((x) => x.restaurant_id === foreignId), `el usuario NO pertenece a «${FOREIGN_NAME}»`);

  // 1) Su restaurante: permitido.
  const own = await call('/rest/v1/rpc/kitchen_orders', { method: 'POST', token, body: { p_restaurant_id: ownId } });
  check(own.status === 200 && Array.isArray(own.json), `puede consultar la cocina de «${OWN_NAME}» (HTTP 200)`, brief(own));

  // 2) Restaurante ajeno: rechazado con 42501.
  const foreign = await call('/rest/v1/rpc/kitchen_orders', { method: 'POST', token, body: { p_restaurant_id: foreignId } });
  check(foreign.status === 403 && foreign.json?.code === '42501',
    `recibe un rechazo al consultar la cocina de «${FOREIGN_NAME}» (HTTP 403, código 42501)`, brief(foreign));
  check(!Array.isArray(foreign.json), `no recibe ninguna comanda de «${FOREIGN_NAME}»`);
} finally {
  // Cierra SOLO esta sesión (no las que el usuario tenga abiertas en la app).
  await call('/auth/v1/logout?scope=local', { method: 'POST', token });
  token = null;
}

const failed = results.filter((ok) => !ok).length;
console.log(`\n${results.length - failed} correctas, ${failed} fallidas`);
console.log(failed ? 'RESULTADO: FALLO — el aislamiento NO se ha comprobado.' : 'RESULTADO: el usuario de cocina está aislado en su restaurante.');
process.exit(failed ? 1 : 0);
