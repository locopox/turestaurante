// Pruebas de SEGURIDAD de los pedidos de clientes (P1–P10) contra la API REAL de Supabase LOCAL.
//
// Fases (siempre en este orden):
//   1. PREPARAR (administración local): dos restaurantes de prueba (A y B), su carta y tres cuentas de
//      personal (sala A, cocina A, sala B). Todo lleva la marca PRUEBA-PEDIDOS y la marca de esta ejecución.
//   2. ATACAR: P1–P10 como lo haría alguien malintencionado, por la API (PostgREST) y SOLO con la clave
//      PÚBLICA: como cliente anónimo o con sesiones REALES de Supabase Auth. La clave de administración
//      se olvida antes de empezar esta fase.
//   3. LIMPIAR (administración local): borra SOLO los identificadores creados en esta ejecución, en una
//      única transacción. Si algún registro no encaja, no borra nada y avisa.
//
// Seguridad:
//   - Solo Supabase LOCAL (127.0.0.1 o localhost): comprueba la API y la base de datos ANTES de cualquier
//     operación de administración, y se detiene sin conectar si alguna no es local.
//   - Los ataques solo usan la clave pública; si una petición de ataque llevara una clave o sesión de
//     administración, el script se detiene.
//   - Las contraseñas de las cuentas de prueba son aleatorias, viven solo en la memoria del script y no se
//     muestran ni se guardan. No muestra ni registra claves, tokens ni los códigos secretos de los pedidos.
//   - No toca los datos existentes: hace una «foto» (solo lectura) de todo lo que no es de prueba antes y
//     después, y la prueba falla si algo ha cambiado.
//
// Uso (desde la carpeta del repositorio, con Supabase local en marcha):
//   eval "$(cd ~/tr-local && supabase status -o env)"
//   npm run test:local:orders                 # prueba completa
//   npm run test:local:orders -- --limpiar    # restos de una ejecución interrumpida (pide confirmación)
//
// psql: si este equipo no lo tiene (lo normal en Windows), se usa el psql del contenedor de la base de datos de
// Supabase LOCAL, después de comprobar que el contenedor es ese (ORDERS_TEST_PSQL=auto|local|docker).
import { execFileSync } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { createInterface } from 'node:readline';

const CLEAN_MODE = process.argv.includes('--limpiar');
const RUN = `${Date.now().toString(36)}${randomBytes(3).toString('hex')}`;
const MAIL_DOMAIN = 'pedidos-prueba.test';

let cleanupNeeded = false; // hay datos de prueba creados que limpiar
let dbRunner = null; // cómo se ejecuta psql (se elige tras comprobar que todo es local)

function stop(message, code = 2) {
  console.error(`\nDETENIDO: ${message}`);
  process.exit(code);
}

// ---------- Configuración: SOLO variables de entorno (las de `supabase status -o env`) ----------
for (const k of Object.keys(process.env)) {
  if (/PASS(WORD)?|CONTRASE/i.test(k) && /PEDIDO|ORDER|PRUEBA/i.test(k)) {
    stop(`la variable «${k}» parece una contraseña. Bórrala: esta prueba crea sus propias cuentas con contraseñas aleatorias.`);
  }
}
const env = (...names) => names.map((n) => (process.env[n] ?? '').trim()).find(Boolean) ?? '';
const API_URL = env('API_URL', 'SUPABASE_URL').replace(/\/$/, '');
const PUBLIC_KEY = env('PUBLISHABLE_KEY', 'ANON_KEY');
let ADMIN_KEY = env('SECRET_KEY', 'SERVICE_ROLE_KEY');
const DB_URL = env('DB_URL');

const LOCAL_HOSTS = ['127.0.0.1', 'localhost'];
const help = process.platform === 'win32'
  ? 'Carga las variables de Supabase LOCAL en esta ventana de PowerShell (instrucciones en supabase/tests/local/README.md).'
  : 'Carga las variables de Supabase LOCAL: eval "$(cd ~/tr-local && supabase status -o env)"';

function checkLocalApi() {
  let u;
  try {
    u = new URL(API_URL);
  } catch {
    stop(`falta API_URL o no es una dirección válida. ${help}`);
  }
  if (!['http:', 'https:'].includes(u.protocol) || !LOCAL_HOSTS.includes(u.hostname) || u.pathname !== '/'
      || u.search || u.username || u.password) {
    stop('API_URL no es un Supabase LOCAL (debe ser http://127.0.0.1:54321 o similar). Esta prueba nunca se conecta a un proyecto remoto.');
  }
}
/** Datos de conexión de DB_URL, comprobando que es la base de datos LOCAL. */
function localDb() {
  let u;
  try {
    u = new URL(DB_URL);
  } catch {
    stop(`falta DB_URL o no es una dirección válida. ${help}`);
  }
  // Sin parámetros: en una URL de PostgreSQL, «?host=…» o «?hostaddr=…» podrían llevar a otro servidor.
  if (!['postgres:', 'postgresql:'].includes(u.protocol) || !LOCAL_HOSTS.includes(u.hostname) || u.search) {
    stop('DB_URL no es la base de datos de Supabase LOCAL (debe ser postgresql://…@127.0.0.1:54322/postgres). Esta prueba nunca se conecta a una base de datos remota.');
  }
  return {
    host: u.hostname, port: u.port || '5432', user: decodeURIComponent(u.username),
    password: decodeURIComponent(u.password), database: decodeURIComponent(u.pathname.slice(1)) || 'postgres',
  };
}

function jwtRole(key) {
  try {
    return JSON.parse(Buffer.from(key.split('.')[1], 'base64url').toString('utf8')).role ?? null;
  } catch {
    return null;
  }
}
const isSecretKey = (k) => k.startsWith('sb_secret_') || jwtRole(k) === 'service_role';

// Todas las conexiones se comprueban ANTES de cualquier operación de administración.
checkLocalApi();
const DB = localDb();
if (!PUBLIC_KEY) stop(`falta la clave pública (PUBLISHABLE_KEY o ANON_KEY). ${help}`);
if (isSecretKey(PUBLIC_KEY)) stop('la clave pública contiene una clave SECRETA (service_role). Revisa PUBLISHABLE_KEY / ANON_KEY.');
if (!PUBLIC_KEY.startsWith('sb_publishable_') && jwtRole(PUBLIC_KEY) !== 'anon') {
  stop('PUBLISHABLE_KEY / ANON_KEY no parece una clave pública de Supabase («sb_publishable_…» o «anon»).');
}
if (!CLEAN_MODE) {
  if (!ADMIN_KEY) stop(`falta la clave de administración LOCAL (SECRET_KEY o SERVICE_ROLE_KEY), necesaria solo para crear las cuentas de prueba. ${help}`);
  if (!isSecretKey(ADMIN_KEY)) stop('SECRET_KEY / SERVICE_ROLE_KEY no parece una clave de administración de Supabase.');
}

// ---------- ¿Qué psql se usa? (el de este equipo o el del contenedor de Supabase LOCAL) ----------
/** Entorno para psql y docker: sin las variables PG* del usuario (podrían llevar psql a otro servidor). */
function childEnv(extra = {}) {
  const out = { ...process.env };
  for (const k of Object.keys(out)) if (/^PG/i.test(k)) delete out[k];
  return Object.assign(out, extra);
}
/** Variables de conexión de psql. La contraseña va en PGPASSWORD, nunca en la línea de órdenes. */
const pgVars = (host, port) => ({
  PGHOST: host, PGPORT: String(port), PGUSER: DB.user, PGPASSWORD: DB.password, PGDATABASE: DB.database,
  PGCONNECT_TIMEOUT: '5', PGAPPNAME: 'orders_security_test', PGCLIENTENCODING: 'UTF8',
});
/** Ejecuta un programa directamente (sin intérprete de órdenes). Nunca muestra su entorno. */
function runProgram(cmd, args, { input, env } = {}) {
  try {
    const out = execFileSync(cmd, args, {
      input, env: env ?? childEnv(), encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
    });
    return { ok: true, out: out.trim() };
  } catch (e) {
    return { ok: false, missing: e.code === 'ENOENT', err: String(e.stderr ?? '') };
  }
}
const firstLine = (text) => String(text).split(/\r?\n/).map((l) => l.trim()).find(Boolean) ?? '';

/**
 * Contenedor de la base de datos de Supabase LOCAL que publica el puerto de DB_URL. Se comprueba TODO antes de
 * ejecutar la primera consulta: Docker de este equipo, un único contenedor en marcha con ese puerto, nombre
 * supabase_db_<proyecto>, etiqueta de la CLI de Supabase con el mismo proyecto e imagen supabase/postgres.
 */
function findSupabaseDbContainer() {
  const dockerHost = (process.env.DOCKER_HOST ?? '').trim();
  if (dockerHost && !/^(unix|npipe):\/\//i.test(dockerHost)) {
    stop('DOCKER_HOST apunta a un Docker que no es el de este equipo. Esta prueba solo usa el Docker local (quita DOCKER_HOST de esta ventana).');
  }
  const ctx = runProgram('docker', ['context', 'inspect', '--format', '{{.Endpoints.docker.Host}}']);
  if (ctx.missing) {
    stop('no se encuentra el programa «psql» en este equipo, ni el programa «docker» para usar el psql del contenedor de Supabase local. ¿Está instalado y en marcha Docker Desktop?');
  }
  if (!ctx.ok) stop(`no se pudo consultar Docker (${firstLine(ctx.err) || 'sin detalle'}). ¿Está Docker Desktop en marcha?`);
  if (!dockerHost && !/^(unix|npipe):\/\//i.test(ctx.out)) {
    stop('el contexto actual de Docker no es el Docker de este equipo. Esta prueba solo usa el Docker local (docker context use default).');
  }

  const ps = runProgram('docker', ['ps', '--filter', `publish=${DB.port}`, '--format', '{{.ID}}']);
  if (!ps.ok) stop(`no se pudo consultar Docker (${firstLine(ps.err) || 'sin detalle'}).`);
  const ids = ps.out.split(/\s+/).filter(Boolean);
  if (ids.length === 0) stop(`ningún contenedor de Docker en marcha publica el puerto ${DB.port} de DB_URL. ¿Está Supabase local en marcha (supabase start)?`);
  if (ids.length > 1) stop(`hay ${ids.length} contenedores que publican el puerto ${DB.port}: no se puede saber cuál es la base de datos de Supabase local.`);
  const id = ids[0];
  // Solo los campos necesarios (no se lee el entorno del contenedor, que contiene secretos).
  const field = (fmt) => {
    const r = runProgram('docker', ['inspect', '--type', 'container', '--format', `{{json ${fmt}}}`, id]);
    if (!r.ok) stop(`no se pudo inspeccionar el contenedor (${firstLine(r.err) || 'sin detalle'}).`);
    try {
      return JSON.parse(r.out);
    } catch {
      stop('Docker ha devuelto una respuesta inesperada al inspeccionar el contenedor.');
    }
  };
  const name = String(field('.Name') ?? '').replace(/^\//, '');
  const image = String(field('.Config.Image') ?? '');
  const labels = field('.Config.Labels') ?? {};
  const ports = field('.NetworkSettings.Ports') ?? {};
  const running = field('.State.Running') === true;

  const project = /^supabase_db_([A-Za-z0-9_.-]+)$/.exec(name)?.[1];
  const imageRepo = image.replace(/@.*$/, '').replace(/:[^/:]+$/, '');
  const notSupabase = (why) => stop(`el contenedor que publica el puerto ${DB.port} («${name || id}») no parece la base de datos de Supabase local: ${why}. No se ejecuta ninguna consulta.`);
  if (!running) notSupabase('no está en marcha');
  if (!project) notSupabase('su nombre no es supabase_db_<proyecto>');
  if (labels['com.supabase.cli.project'] !== project) notSupabase('no tiene la etiqueta de la CLI de Supabase de ese proyecto');
  if (!/(^|\/)supabase\/postgres$/.test(imageRepo)) notSupabase('su imagen no es supabase/postgres');
  let innerPort = null;
  for (const [key, bindings] of Object.entries(ports)) {
    const m = /^(\d+)\/tcp$/.exec(key);
    if (m && (bindings ?? []).some((b) => String(b.HostPort) === DB.port && ['', '0.0.0.0', '127.0.0.1', '::', '::1'].includes(b.HostIp ?? ''))) innerPort = m[1];
  }
  if (!innerPort) notSupabase(`no publica su PostgreSQL en el puerto ${DB.port} de este equipo`);
  const v = runProgram('docker', ['exec', id, 'psql', '--version']);
  if (!v.ok) stop(`el contenedor ${name} no tiene psql disponible (${firstLine(v.err) || 'sin detalle'}).`);
  return { id, name, innerPort };
}

const PSQL_MODE = (process.env.ORDERS_TEST_PSQL ?? 'auto').trim().toLowerCase(); // auto | local | docker
/** Elige cómo ejecutar psql. Se decide (y se comprueba) antes de la primera operación de administración. */
function chooseDbRunner() {
  if (!['auto', 'local', 'docker'].includes(PSQL_MODE)) stop('ORDERS_TEST_PSQL solo admite «auto», «local» o «docker».');
  if (PSQL_MODE !== 'docker') {
    const v = runProgram('psql', ['--version']);
    if (v.ok) {
      return {
        label: 'psql de este equipo',
        exec: (args, input) => runProgram('psql', args, { input, env: childEnv(pgVars(DB.host, DB.port)) }),
      };
    }
    if (PSQL_MODE === 'local') stop('no se encuentra el programa «psql» en este equipo (ORDERS_TEST_PSQL=local).');
  }
  const c = findSupabaseDbContainer();
  // Dentro del contenedor, PostgreSQL escucha en su propio puerto. «-e NOMBRE» (sin valor) pasa la variable
  // desde el entorno de docker: la contraseña no aparece en la línea de órdenes.
  const vars = pgVars('127.0.0.1', c.innerPort);
  const passEnv = Object.keys(vars).flatMap((k) => ['-e', k]);
  return {
    label: `psql del contenedor ${c.name}`,
    exec: (args, input) => runProgram('docker', ['exec', '-i', ...passEnv, c.id, 'psql', ...args], { input, env: childEnv(vars) }),
  };
}

// ---------- Administración LOCAL (solo preparar, limpiar y la «foto» de solo lectura) ----------
/** Ejecuta SQL en la base de datos LOCAL. Los valores van como variables de psql (:'nombre'), nunca pegados al texto. */
function adminSql(script, vars = {}) {
  if (!dbRunner) throw new Error('no se ha comprobado la conexión con la base de datos local');
  const args = ['-X', '-q', '-tA', '-v', 'ON_ERROR_STOP=1'];
  for (const [k, v] of Object.entries(vars)) args.push('-v', `${k}=${v}`);
  const r = dbRunner.exec(args, script);
  if (r.ok) return r.out;
  let msg;
  if (r.missing) msg = `no se encuentra el programa necesario para usar la base de datos (${dbRunner.label})`;
  else {
    const lines = r.err.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    msg = (lines.find((l) => /ERROR|FATAL|error|could not|no se pudo/i.test(l)) ?? lines[0] ?? 'psql terminó con un error sin mensaje')
      .replace(/^.*?(ERROR|FATAL|error):\s*/, '').trim();
  }
  const err = new Error(`${msg} [${dbRunner.label}]`);
  err.sql = true;
  throw err;
}
// Con las URL y las claves ya comprobadas, se elige el psql (y, si es el del contenedor, se verifica el
// contenedor) ANTES de la primera operación de administración.
dbRunner = chooseDbRunner();

const pgArray = (ids) => `{${ids.join(',')}}`;

/** Crea una cuenta confirmada con la API de administración de Auth LOCAL (solo en la fase de preparación). */
async function adminCreateUser(email, password) {
  if (!ADMIN_KEY) throw new Error('la clave de administración ya no está disponible');
  const r = await fetch(`${API_URL}/auth/v1/admin/users`, {
    method: 'POST',
    headers: { apikey: ADMIN_KEY, Authorization: `Bearer ${ADMIN_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password, email_confirm: true }),
  });
  const b = await r.json().catch(() => null);
  if (!r.ok || !b?.id) throw new Error(`no se pudo crear la cuenta de prueba ${email} (HTTP ${r.status})`);
  return b.id;
}

// ---------- API PÚBLICA (la única que usan los ataques) ----------
async function api(path, { method = 'GET', token = null, body, prefer } = {}) {
  // Barrera: un ataque nunca puede ir con credenciales de administración.
  if (isSecretKey(PUBLIC_KEY) || (token && jwtRole(token) !== 'authenticated')) {
    stop('una petición de ataque iba a usar credenciales de administración. Se detiene la prueba.');
  }
  const headers = { apikey: PUBLIC_KEY, 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (prefer) headers.Prefer = prefer;
  let res;
  try {
    res = await fetch(`${API_URL}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  } catch {
    throw new Error(`no hay conexión con ${API_URL}`);
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
const rpc = (fn, args = {}, token = null) => api(`/rest/v1/rpc/${fn}`, { method: 'POST', token, body: args });
/** Detalle seguro de una respuesta: solo estado, código y mensaje del servidor. */
const brief = (r) => `HTTP ${r.status}${r.json?.code ? `, código ${r.json.code}` : ''}${r.json?.message ? `: ${r.json.message}` : ''}`;
/** Rechazado = error de la API (401/403/400/404…). */
const denied = (r) => r.status >= 400;
/** Sin efecto = rechazado, o aceptado sin tocar ninguna fila. */
const noEffect = (r) => denied(r) || (r.status < 300 && (r.json === null || (Array.isArray(r.json) && r.json.length === 0)));

// ---------- Resultados ----------
const results = [];
function check(ok, name, detail = '') {
  results.push(!!ok);
  console.log(`${ok ? 'OK   ' : 'FALLO'} ${name}${!ok && detail ? ` — ${detail}` : ''}`);
}
const section = (t) => console.log(`\n— ${t}`);

// ---------- Comprobaciones previas de limpieza (si hay dudas, no se borra nada) ----------
// Funciona igual para la ejecución actual (identificadores en memoria) y para --limpiar (identificadores
// mostrados y confirmados). Todo en una transacción: o se borra todo o nada.
const CLEANUP_SQL = `
begin;
select set_config('tr.rids', :'rids', true), set_config('tr.oids', :'oids', true),
       set_config('tr.uids', :'uids', true), set_config('tr.run', :'run', true), set_config('tr.domain', :'domain', true);
do $$
declare
  rids uuid[] := current_setting('tr.rids')::uuid[];
  oids uuid[] := current_setting('tr.oids')::uuid[];
  uids uuid[] := current_setting('tr.uids')::uuid[];
  run text := current_setting('tr.run');          -- marca de la ejecución (o patrón genérico en --limpiar)
  domain text := current_setting('tr.domain');
  n int;
begin
  -- Restaurantes: todos existen y llevan la marca de prueba (nombre y dirección web).
  select count(*) into n from public.restaurants r where r.id = any(rids)
    and r.name ~ ('^PRUEBA-PEDIDOS [AB] ' || run || '$') and r.slug ~ ('^prueba-pedidos-[ab]-' || run || '$');
  if n <> cardinality(rids) then
    raise exception 'DUDA: algún restaurante a borrar no existe o no lleva la marca PRUEBA-PEDIDOS';
  end if;
  -- Pedidos: exactamente los de la lista, y solo en los restaurantes de prueba.
  if exists (select 1 from public.orders o where o.restaurant_id = any(rids) and not (o.id = any(oids))) then
    raise exception 'DUDA: hay pedidos en los restaurantes de prueba que no están en la lista';
  end if;
  if exists (select 1 from public.orders o where o.id = any(oids) and not (o.restaurant_id = any(rids))) then
    raise exception 'DUDA: algún pedido de la lista no es de un restaurante de prueba';
  end if;
  -- Nada de historial de pagos, invitaciones ni soporte (no se borra: no lo crea esta prueba).
  if exists (select 1 from private.payment_sessions s where s.order_id = any(oids))
     or exists (select 1 from public.payment_events e where e.restaurant_id = any(rids) or e.order_id = any(oids))
     or exists (select 1 from private.invitations i where i.restaurant_id = any(rids))
     or exists (select 1 from private.support_grants g where g.restaurant_id = any(rids)) then
    raise exception 'DUDA: los restaurantes de prueba tienen pagos, invitaciones o accesos de soporte';
  end if;
  -- Personal: solo las cuentas de prueba, y esas cuentas no tienen acceso a ningún otro restaurante.
  if exists (select 1 from public.restaurant_staff s where s.restaurant_id = any(rids) and not (s.user_id = any(uids))) then
    raise exception 'DUDA: hay personal en los restaurantes de prueba que no es una cuenta de prueba';
  end if;
  if exists (select 1 from public.restaurant_staff s where s.user_id = any(uids) and not (s.restaurant_id = any(rids))) then
    raise exception 'DUDA: alguna cuenta de prueba tiene acceso a un restaurante que no es de prueba';
  end if;
  -- Cuentas: todas existen, con el correo de prueba, y ninguna es de la plataforma.
  select count(*) into n from auth.users u where u.id = any(uids)
    and u.email ~ ('^[a-z-]+-' || run || '@' || replace(domain, '.', '\\.') || '$');
  if n <> cardinality(uids) then
    raise exception 'DUDA: alguna cuenta a borrar no existe o no tiene un correo de prueba';
  end if;
  if exists (select 1 from public.platform_admins p where p.user_id = any(uids)) then
    raise exception 'DUDA: alguna cuenta de prueba es de la plataforma';
  end if;

  delete from public.orders where id = any(oids) and restaurant_id = any(rids);   -- líneas y accesos van con el pedido
  delete from public.restaurants where id = any(rids);                            -- carta, personal y numeración van con él
  delete from auth.users where id = any(uids);

  if exists (select 1 from public.restaurants where id = any(rids)) or exists (select 1 from public.orders where id = any(oids))
     or exists (select 1 from auth.users where id = any(uids)) then
    raise exception 'la limpieza no ha borrado todo';
  end if;
end $$;
commit;
select 'limpio';
`;

function cleanup(ids, run) {
  return adminSql(CLEANUP_SQL, {
    rids: pgArray(ids.restaurants), oids: pgArray(ids.orders), uids: pgArray(ids.users), run, domain: MAIL_DOMAIN,
  });
}

// ---------- «Foto» de solo lectura de todo lo que NO es de esta prueba ----------
const SNAPSHOT_SQL = `
select count(*) || ':' || md5(coalesce(string_agg(x, '|' order by x), ''))
from (
  select 'restaurant' || row_to_json(r)::text x from public.restaurants r where not (r.id = any(:'rids'::uuid[]))
  union all select 'category' || row_to_json(c)::text from public.categories c where not (c.restaurant_id = any(:'rids'::uuid[]))
  union all select 'product' || row_to_json(p)::text from public.products p where not (p.restaurant_id = any(:'rids'::uuid[]))
  union all select 'staff' || row_to_json(s)::text from public.restaurant_staff s where not (s.restaurant_id = any(:'rids'::uuid[]))
  union all select 'order' || row_to_json(o)::text from public.orders o where not (o.restaurant_id = any(:'rids'::uuid[]))
  union all select 'item' || row_to_json(i)::text from public.order_items i
    join public.orders o on o.id = i.order_id where not (o.restaurant_id = any(:'rids'::uuid[]))
  union all select 'access' || row_to_json(a)::text from private.order_access a
    join public.orders o on o.id = a.order_id where not (o.restaurant_id = any(:'rids'::uuid[]))
  union all select 'counter' || row_to_json(k)::text from private.order_counters k where not (k.restaurant_id = any(:'rids'::uuid[]))
  union all select 'session' || row_to_json(ps)::text from private.payment_sessions ps
  union all select 'event' || row_to_json(e)::text from public.payment_events e
  union all select 'invitation' || row_to_json(iv)::text from private.invitations iv
  union all select 'grant' || row_to_json(g)::text from private.support_grants g
  union all select 'user' || u.id || u.email || coalesce(u.email_confirmed_at::text, '') from auth.users u
    where u.email is null or u.email !~ ('-' || :'run' || '@')
) s;
`;
const AUDIT_OUTSIDE_SQL = `select count(*) from private.audit_log a where a.created_at >= :'since'::timestamptz
  and (a.restaurant_id is null or not (a.restaurant_id = any(:'rids'::uuid[])))
  and a.target_table in ('orders', 'order_items', 'products', 'restaurants', 'restaurant_staff', 'categories');`;

// ---------- Confirmación en la terminal (--limpiar) ----------
function ask(question) {
  if (!process.stdin.isTTY) stop('la confirmación se tiene que escribir en una terminal interactiva.');
  return new Promise((resolve) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    rl.question(question, (a) => {
      rl.close();
      resolve(a.trim());
    });
  });
}

// =====================================================================================================
// MODO --limpiar: restos de ejecuciones interrumpidas
// =====================================================================================================
if (CLEAN_MODE) {
  console.log(`Limpieza de restos de la prueba de pedidos en la base de datos LOCAL (${DB.host}:${DB.port}, ${dbRunner.label})\n`);
  let found;
  try {
    found = JSON.parse(adminSql(`
      select json_build_object(
        'restaurants', coalesce((select json_agg(json_build_object('id', r.id, 'name', r.name, 'slug', r.slug,
          'orders', (select coalesce(json_agg(o.id), '[]') from public.orders o where o.restaurant_id = r.id),
          'staff', (select coalesce(json_agg(coalesce(u.email, '(sin correo)') order by u.email), '[]')
            from public.restaurant_staff s left join auth.users u on u.id = s.user_id where s.restaurant_id = r.id)) order by r.created_at)
          from public.restaurants r where r.name like 'PRUEBA-PEDIDOS %' or r.slug like 'prueba-pedidos-%'), '[]'),
        'users', coalesce((select json_agg(json_build_object('id', u.id, 'email', u.email) order by u.created_at)
          from auth.users u where u.email like :'pattern'), '[]'));`, { pattern: `%@${MAIL_DOMAIN}` }));
  } catch (e) {
    stop(`no se pudo consultar la base de datos local (${e.message}).`);
  }
  if (!found.restaurants.length && !found.users.length) {
    console.log('No hay restos de la prueba. No se borra nada.');
    process.exit(0);
  }
  console.log('Se eliminarían estos registros:\n');
  for (const r of found.restaurants) {
    console.log(`  Restaurante «${r.name}» (${r.slug}) · ${r.id}`);
    console.log(`      con ${r.orders.length} pedido(s) y su carta; personal:`);
    for (const m of r.staff) console.log(`        ${m}${m.endsWith(`@${MAIL_DOMAIN}`) ? '' : '   ← NO es una cuenta de prueba: la limpieza se detendrá'}`);
  }
  for (const u of found.users) console.log(`  Cuenta ${u.email} · ${u.id}`);
  console.log('\nNo se tocará nada más (en particular, La Piazza ni el Restaurante Aislamiento PRUEBA).');
  console.log('El registro de auditoría no se puede borrar (está protegido) y conserva la huella de la prueba.\n');
  const answer = await ask('Escribe BORRAR para eliminarlos (cualquier otra cosa cancela): ');
  if (answer !== 'BORRAR') {
    console.log('Cancelado. No se ha borrado nada.');
    process.exit(0);
  }
  try {
    cleanup({
      restaurants: found.restaurants.map((r) => r.id),
      orders: found.restaurants.flatMap((r) => r.orders),
      users: found.users.map((u) => u.id),
    }, '[a-z0-9]+');
  } catch (e) {
    stop(`no se ha borrado nada. ${e.message}. Revisa esos registros a mano antes de continuar.`, 1);
  }
  console.log('Restos eliminados.');
  process.exit(0);
}

// =====================================================================================================
// PRUEBA COMPLETA
// =====================================================================================================
const RA = randomUUID();
const RB = randomUUID();
const ids = { restaurants: [RA, RB], orders: [], users: [] };
const names = { a: `PRUEBA-PEDIDOS A ${RUN}`, b: `PRUEBA-PEDIDOS B ${RUN}` };
const P = { a1: randomUUID(), a2: randomUUID(), b1: randomUUID() };
const PRICE = { a1: 1250, a2: 300, b1: 900 };
const mail = (who) => `${who}-${RUN}@${MAIL_DOMAIN}`;
const sessions = {}; // tokens de sesión, solo en memoria
const newCustomerToken = () => randomBytes(32).toString('hex'); // como hace la app

function runCleanup() {
  if (!cleanupNeeded) return true;
  try {
    cleanup(ids, RUN);
    cleanupNeeded = false;
    return true;
  } catch (e) {
    console.error(`\nAVISO: la limpieza no ha borrado nada (${e.message}).`);
    console.error('Revisa los registros PRUEBA-PEDIDOS y usa «npm run test:local:orders -- --limpiar».');
    return false;
  }
}
process.on('SIGINT', () => {
  console.log('\nInterrumpido: limpiando los datos de esta ejecución…');
  runCleanup();
  process.exit(130);
});

console.log('Pruebas de seguridad de pedidos (P1–P10) contra Supabase LOCAL');
console.log(`API: ${API_URL} · base de datos: ${DB.host}:${DB.port} (${dbRunner.label}) · ejecución ${RUN}`);

let snapshotBefore;
let startedAt;
let exitCode = 0;
try {
  // ---------------- 1. PREPARAR ----------------
  section('Preparación (administración local)');
  startedAt = adminSql('select now();');
  if (adminSql('select count(*) from public.restaurants where name like :\'n\' or id = any(:\'rids\'::uuid[]);',
    { n: `%${RUN}%`, rids: pgArray(ids.restaurants) }) !== '0') stop('ya existe un restaurante con la marca de esta ejecución.');
  snapshotBefore = adminSql(SNAPSHOT_SQL, { rids: pgArray(ids.restaurants), run: RUN });

  cleanupNeeded = true;
  const CA = randomUUID();
  const CB = randomUUID();
  adminSql(`
    begin;
    insert into public.restaurants (id, slug, name, active, tables, pickup_enabled, online_payment_enabled, counter_payment_enabled)
    values (:'ra', :'slug_a', :'name_a', true, 10, true, true, true),
           (:'rb', :'slug_b', :'name_b', true, 10, true, true, true);
    insert into public.categories (id, restaurant_id, name) values (:'ca', :'ra', 'Categoría de prueba'), (:'cb', :'rb', 'Categoría de prueba');
    insert into public.products (id, restaurant_id, category_id, name, price_cents) values
      (:'pa1', :'ra', :'ca', 'Producto A1 de prueba', :'price_a1'),
      (:'pa2', :'ra', :'ca', 'Producto A2 de prueba', :'price_a2'),
      (:'pb1', :'rb', :'cb', 'Producto B1 de prueba', :'price_b1');
    commit;`, {
    ra: RA, rb: RB, slug_a: `prueba-pedidos-a-${RUN}`, slug_b: `prueba-pedidos-b-${RUN}`, name_a: names.a, name_b: names.b,
    ca: CA, cb: CB, pa1: P.a1, pa2: P.a2, pb1: P.b1, price_a1: PRICE.a1, price_a2: PRICE.a2, price_b1: PRICE.b1,
  });
  console.log(`Restaurantes «${names.a}» y «${names.b}» con su carta`);

  const staff = [['sala-a', RA, 'waiter'], ['cocina-a', RA, 'kitchen'], ['sala-b', RB, 'waiter']];
  const passwords = new Map(); // solo en memoria
  for (const [who, rid, role] of staff) {
    const pw = `Pw-${randomBytes(18).toString('base64url')}`;
    const uid = await adminCreateUser(mail(who), pw);
    ids.users.push(uid);
    passwords.set(who, pw);
    adminSql(`insert into public.restaurant_staff (restaurant_id, user_id, role) values (:'rid', :'uid', :'role');`, { rid, uid, role });
  }
  ADMIN_KEY = null; // a partir de aquí no hay clave de administración en el script
  console.log('Cuentas de prueba: sala A, cocina A y sala B (contraseñas aleatorias, solo en memoria)');
  console.log('La clave de administración se ha olvidado: los ataques solo usan la clave pública.');

  // ---------------- 2. ATACAR (solo clave pública) ----------------
  for (const [who] of staff) {
    const r = await api('/auth/v1/token?grant_type=password', { method: 'POST', body: { email: mail(who), password: passwords.get(who) } });
    if (r.status !== 200 || !r.json?.access_token) throw new Error(`no se pudo iniciar sesión como ${who} (HTTP ${r.status})`);
    sessions[who] = r.json.access_token;
  }
  passwords.clear();
  const salaA = sessions['sala-a'];
  const cocinaA = sessions['cocina-a'];
  const salaB = sessions['sala-b'];
  section('Sesiones reales');
  check(Object.values(sessions).every((t) => jwtRole(t) === 'authenticated'), 'sala A, cocina A y sala B han iniciado sesión con la clave pública');

  /** Pedido hecho como cliente ANÓNIMO, por la misma función que usa la app. */
  async function anonOrder(rid, extra = () => ({})) {
    const token = newCustomerToken();
    const r = await rpc('create_order', {
      payload: { restaurantId: rid, mode: 'mesa', table: 3, paymentMethod: 'caja', notes: '', accessToken: token, ...extra(token) },
    });
    if (r.status === 200 && r.json?.id) ids.orders.push(r.json.id);
    return { r, token, id: r.json?.id };
  }
  /** Estado de un pedido de A visto por la sala de A (sesión real, respeta RLS). */
  async function stateA(id) {
    const r = await api(`/rest/v1/orders?id=eq.${id}&select=total_cents,payment_method,payment_status,prep_status,payment_ref`, { token: salaA });
    return Array.isArray(r.json) && r.json.length === 1 ? r.json[0] : null;
  }
  async function itemsA(id) {
    const r = await api(`/rest/v1/order_items?order_id=eq.${id}&select=name,unit_price_cents,quantity&order=name`, { token: salaA });
    return Array.isArray(r.json) ? r.json : null;
  }
  const same = (a, b) => a !== null && b !== null && JSON.stringify(a) === JSON.stringify(b);

  // P1 ── precio y nombre falsos al crear el pedido
  section('P1 · Cliente anónimo envía precios, nombres y total falsos');
  const expected = 2 * PRICE.a1 + 1 * PRICE.a2;
  const o1 = await anonOrder(RA, () => ({
    total: 1, totalCents: 1, total_cents: 1,
    items: [
      { productId: P.a1, quantity: 2, price: 1, unitPrice: 1, unit_price_cents: 1, name: 'GRATIS' },
      { productId: P.a2, quantity: 1, price: 0, unitPrice: 0, unit_price_cents: 0, name: 'GRATIS' },
    ],
  }));
  check(o1.r.status === 200 && o1.id, 'el pedido manipulado se crea (se ignoran los campos falsos)', brief(o1.r));
  check(o1.r.json?.total === expected, `el total lo calcula el servidor: ${expected / 100} € y no 0,01 €`, `total ${o1.r.json?.total}`);
  const lines1 = await itemsA(o1.id);
  check(same(lines1, [
    { name: 'Producto A1 de prueba', unit_price_cents: PRICE.a1, quantity: 2 },
    { name: 'Producto A2 de prueba', unit_price_cents: PRICE.a2, quantity: 1 },
  ]), 'las líneas guardadas tienen el nombre y el precio de la carta', JSON.stringify(lines1));
  check((await stateA(o1.id))?.total_cents === expected, 'el total guardado en la base de datos es el de la carta');
  const foreignProduct = await anonOrder(RA, () => ({ items: [{ productId: P.b1, quantity: 1, price: 1 }] }));
  check(denied(foreignProduct.r), 'rechaza un producto de otro restaurante', brief(foreignProduct.r));

  // Más pedidos de prueba (como cliente anónimo)
  const o2 = await anonOrder(RA, () => ({ paymentMethod: 'online', items: [{ productId: P.a1, quantity: 1 }] })); // pendiente online
  const o3 = await anonOrder(RA, () => ({ items: [{ productId: P.a2, quantity: 2 }] }));                           // pendiente de caja
  const o4 = await anonOrder(RB, () => ({ items: [{ productId: P.b1, quantity: 1 }] }));                           // en B
  if (![o2, o3, o4].every((o) => o.id)) throw new Error('no se pudieron crear los pedidos de prueba');
  const before = { o1: await stateA(o1.id), o2: await stateA(o2.id), o3: await stateA(o3.id) };
  const items1 = await itemsA(o1.id);

  // P2 ── cambiar el total con PATCH
  section('P2 · Cambiar el total directamente en la tabla');
  let r = await api(`/rest/v1/orders?id=eq.${o1.id}`, { method: 'PATCH', body: { total_cents: 1 }, prefer: 'return=representation' });
  check(noEffect(r), 'anónimo: PATCH del total rechazado', brief(r));
  r = await api(`/rest/v1/orders?id=eq.${o1.id}`, { method: 'PATCH', token: salaA, body: { total_cents: 1 }, prefer: 'return=representation' });
  check(noEffect(r), 'sala A (su propio restaurante): PATCH del total rechazado', brief(r));
  r = await api(`/rest/v1/order_items?order_id=eq.${o1.id}`, { method: 'PATCH', body: { unit_price_cents: 1 }, prefer: 'return=representation' });
  check(noEffect(r), 'anónimo: PATCH del precio de las líneas rechazado', brief(r));
  r = await api(`/rest/v1/order_items?order_id=eq.${o1.id}`, { method: 'PATCH', token: salaA, body: { unit_price_cents: 1 }, prefer: 'return=representation' });
  check(noEffect(r), 'sala A: PATCH del precio de las líneas rechazado', brief(r));
  r = await api(`/rest/v1/products?id=eq.${P.a1}`, { method: 'PATCH', body: { price_cents: 1 }, prefer: 'return=representation' });
  check(noEffect(r), 'anónimo: cambiar el precio de la carta rechazado', brief(r));
  check(same(await stateA(o1.id), before.o1), 'comprobación inversa: el pedido sigue exactamente igual');
  check(same(await itemsA(o1.id), items1), 'comprobación inversa: las líneas siguen exactamente igual');

  // P3 ── insertar pedidos o líneas directamente
  section('P3 · Crear pedidos o líneas directamente en las tablas');
  const countA = async () => (await api(`/rest/v1/orders?restaurant_id=eq.${RA}&select=id`, { token: salaA })).json?.length;
  const nA = await countA();
  const fakeOrder = { restaurant_id: RA, number: 999, mode: 'mesa', table_number: 1, total_cents: 0, payment_method: 'caja', payment_status: 'cobrado_caja' };
  r = await api('/rest/v1/orders', { method: 'POST', body: fakeOrder, prefer: 'return=representation' });
  check(denied(r), 'anónimo: INSERT directo de un pedido «ya cobrado» rechazado', brief(r));
  r = await api('/rest/v1/orders', { method: 'POST', token: salaA, body: fakeOrder, prefer: 'return=representation' });
  check(denied(r), 'sala A: INSERT directo de un pedido rechazado', brief(r));
  r = await api('/rest/v1/order_items', { method: 'POST', body: { order_id: o1.id, name: 'Extra', unit_price_cents: 0, quantity: 5 }, prefer: 'return=representation' });
  check(denied(r), 'anónimo: añadir líneas a un pedido rechazado', brief(r));
  check((await countA()) === nA, 'comprobación inversa: el restaurante A sigue con los mismos pedidos');
  check(same(await itemsA(o1.id), items1), 'comprobación inversa: el pedido no tiene líneas nuevas');

  // P4 ── marcar como pagado
  section('P4 · Marcar un pedido como pagado sin autorización');
  r = await rpc('staff_mark_paid_at_counter', { p_order_id: o3.id });
  check(denied(r), 'anónimo: marcar como cobrado en caja rechazado', brief(r));
  r = await rpc('staff_mark_paid_at_counter', { p_order_id: o3.id }, cocinaA);
  check(denied(r), 'cocina A: marcar como cobrado rechazado', brief(r));
  r = await api(`/rest/v1/orders?id=eq.${o3.id}`, { method: 'PATCH', body: { payment_status: 'cobrado_caja' }, prefer: 'return=representation' });
  check(noEffect(r), 'anónimo: PATCH del estado de pago rechazado', brief(r));
  r = await api(`/rest/v1/orders?id=eq.${o2.id}`, { method: 'PATCH', token: cocinaA, body: { payment_status: 'pagado_verificado' }, prefer: 'return=representation' });
  check(noEffect(r), 'cocina A: PATCH a «pagado» rechazado', brief(r));
  check(same(await stateA(o3.id), before.o3), 'comprobación inversa: sigue pendiente de cobro en caja');
  check(same(await stateA(o2.id), before.o2), 'comprobación inversa: el pedido online sigue sin pagar');

  // P5 ── funciones de pago del servidor
  section('P5 · Usar las funciones de pago reservadas al servidor');
  const fakeRef = `ataque_${RUN}`;
  for (const [who, tok] of [['anónimo', null], ['sala A', salaA]]) {
    r = await rpc('payment_checkout_started', { p_order_id: o2.id, p_payment_ref: fakeRef, p_amount_cents: before.o2.total_cents }, tok);
    check(denied(r), `${who}: iniciar un pago (payment_checkout_started) rechazado`, brief(r));
    r = await rpc('payment_record_result', { p_provider_event_id: `evt_${RUN}_${who.length}`, p_payment_ref: fakeRef, p_outcome: 'pagado', p_amount_cents: before.o2.total_cents }, tok);
    check(denied(r), `${who}: registrar un pago como «pagado» (payment_record_result) rechazado`, brief(r));
  }
  check(same(await stateA(o2.id), before.o2), 'comprobación inversa: el pedido online sigue pendiente y sin referencia de pago');

  // P6 ── leer el pedido de otro cliente
  section('P6 · Consultar un pedido sin su código secreto');
  for (const [label, tok] of [['código aleatorio', newCustomerToken()], ['código de OTRO pedido', o3.token], ['código mal formado', 'abc'], ['sin código', '']]) {
    r = await rpc('get_customer_order', { p_order_id: o1.id, p_token: tok });
    check(r.status === 200 ? r.json === null : denied(r), `${label}: no devuelve nada`, brief(r));
  }
  r = await rpc('get_customer_order', { p_order_id: o1.id, p_token: o1.token });
  check(r.status === 200 && r.json?.id === o1.id, 'control: con su propio código, el cliente sí ve su pedido', brief(r));
  check(r.json && !('customerPhone' in r.json) && !('paymentRef' in r.json), 'control: la vista del cliente no incluye teléfono ni referencia de pago');
  r = await api(`/rest/v1/orders?select=id&id=eq.${o1.id}`);
  check(noEffect(r), 'anónimo: leer la tabla de pedidos directamente no devuelve nada', brief(r));

  // P7 ── pasar a caja el pedido de otro cliente
  section('P7 · Pasar a caja el pedido de otro cliente');
  r = await rpc('customer_switch_to_counter', { p_order_id: o2.id, p_token: o1.token });
  check(denied(r), 'con el código de otro pedido: rechazado', brief(r));
  r = await rpc('customer_switch_to_counter', { p_order_id: o2.id, p_token: newCustomerToken() });
  check(denied(r), 'con un código aleatorio: rechazado', brief(r));
  check(same(await stateA(o2.id), before.o2), 'comprobación inversa: sigue siendo un pago online pendiente');

  // P8 ── cancelar como cliente
  section('P8 · Cancelar un pedido como cliente');
  r = await rpc('staff_set_prep_status', { p_order_id: o1.id, p_status: 'cancelado' });
  check(denied(r), 'anónimo: cancelar con la función del personal rechazado', brief(r));
  r = await api(`/rest/v1/orders?id=eq.${o1.id}`, { method: 'PATCH', body: { prep_status: 'cancelado' }, prefer: 'return=representation' });
  check(noEffect(r), 'anónimo: PATCH a «cancelado» rechazado', brief(r));
  r = await api(`/rest/v1/orders?id=eq.${o1.id}`, { method: 'DELETE', prefer: 'return=representation' });
  check(noEffect(r), 'anónimo: borrar el pedido rechazado', brief(r));
  check(same(await stateA(o1.id), before.o1), 'comprobación inversa: el pedido sigue sin cancelar');

  // P9 ── leer pedidos de otro restaurante
  section('P9 · Sala de B intenta ver los pedidos de A');
  r = await api(`/rest/v1/orders?restaurant_id=eq.${RA}&select=id,total_cents`, { token: salaB });
  check(r.status === 200 && Array.isArray(r.json) && r.json.length === 0, 'sala B: lista de pedidos de A vacía', brief(r));
  r = await api(`/rest/v1/orders?id=eq.${o1.id}&select=id`, { token: salaB });
  check(noEffect(r), 'sala B: un pedido concreto de A no aparece', brief(r));
  r = await api(`/rest/v1/order_items?order_id=eq.${o1.id}&select=name`, { token: salaB });
  check(noEffect(r), 'sala B: las líneas de un pedido de A no aparecen', brief(r));
  r = await rpc('kitchen_orders', { p_restaurant_id: RA }, salaB);
  check(denied(r), 'sala B: la cocina de A rechazada', brief(r));
  r = await rpc('get_customer_order', { p_order_id: o1.id, p_token: o4.token }, salaB);
  check(r.status === 200 ? r.json === null : denied(r), 'sala B: con el código de un pedido de B no ve uno de A', brief(r));
  r = await api(`/rest/v1/orders?restaurant_id=eq.${RB}&select=id`, { token: salaB });
  check(r.status === 200 && Array.isArray(r.json) && r.json.length === 1 && r.json[0].id === o4.id, 'control: sala B sí ve los pedidos de su restaurante', brief(r));

  // P10 ── cobrar o cancelar pedidos de otro restaurante
  section('P10 · Sala de B intenta cobrar o cancelar pedidos de A');
  r = await rpc('staff_mark_paid_at_counter', { p_order_id: o3.id }, salaB);
  check(denied(r), 'sala B: cobrar un pedido de A rechazado', brief(r));
  r = await rpc('staff_set_prep_status', { p_order_id: o3.id, p_status: 'cancelado' }, salaB);
  check(denied(r), 'sala B: cancelar un pedido de A rechazado', brief(r));
  r = await rpc('staff_set_prep_status', { p_order_id: o3.id, p_status: 'en_preparacion' }, salaB);
  check(denied(r), 'sala B: cambiar la preparación de un pedido de A rechazado', brief(r));
  r = await api(`/rest/v1/orders?id=eq.${o3.id}`, { method: 'PATCH', token: salaB, body: { prep_status: 'cancelado' }, prefer: 'return=representation' });
  check(noEffect(r), 'sala B: PATCH de un pedido de A rechazado', brief(r));
  check(same(await stateA(o3.id), before.o3), 'comprobación inversa: el pedido de A sigue igual');

  // Controles finales: los rechazos se deben a la seguridad, no a un error de la prueba
  section('Controles: lo legítimo sí funciona');
  r = await rpc('staff_mark_paid_at_counter', { p_order_id: o3.id }, salaA);
  check(r.status < 300 && (await stateA(o3.id))?.payment_status === 'cobrado_caja', 'sala A sí puede cobrar en caja un pedido de su restaurante', brief(r));
  r = await rpc('customer_switch_to_counter', { p_order_id: o2.id, p_token: o2.token });
  check(r.status === 200 && r.json?.paymentStatus === 'pendiente_caja', 'el cliente sí puede pasar a caja su propio pedido con su código', brief(r));
  r = await rpc('kitchen_orders', { p_restaurant_id: RA }, cocinaA);
  check(r.status === 200 && Array.isArray(r.json), 'cocina A sí puede consultar su cocina', brief(r));
} catch (e) {
  exitCode = 1;
  console.error(`\nERROR durante la prueba: ${e.message}`);
} finally {
  // Cierra SOLO las sesiones abiertas por la prueba.
  for (const t of Object.values(sessions)) await api('/auth/v1/logout?scope=local', { method: 'POST', token: t }).catch(() => {});
  for (const k of Object.keys(sessions)) delete sessions[k];

  // ---------------- 3. LIMPIAR y comprobar que nada más ha cambiado ----------------
  section('Limpieza y protección de los datos existentes');
  const hadData = cleanupNeeded;
  const cleaned = runCleanup();
  if (hadData) check(cleaned, `limpieza: borrados ${ids.orders.length} pedidos, 2 restaurantes y ${ids.users.length} cuentas de esta ejecución`);
  if (snapshotBefore) {
    try {
      const after = adminSql(SNAPSHOT_SQL, { rids: pgArray(ids.restaurants), run: RUN });
      check(after === snapshotBefore, 'los datos que no son de la prueba (La Piazza, Restaurante Aislamiento PRUEBA…) no han cambiado');
      const audit = adminSql(AUDIT_OUTSIDE_SQL, { since: startedAt, rids: pgArray(ids.restaurants) });
      check(audit === '0', 'el registro de auditoría no muestra cambios en otros restaurantes durante la prueba', `${audit} entradas`);
      const left = adminSql(`select (select count(*) from public.restaurants where id = any(:'rids'::uuid[]))
        + (select count(*) from auth.users where email like :'m');`, { rids: pgArray(ids.restaurants), m: `%-${RUN}@${MAIL_DOMAIN}` });
      check(left === '0', 'no queda ningún restaurante ni cuenta de esta ejecución');
    } catch (e) {
      check(false, 'comprobación final de los datos existentes', e.message);
    }
  }
}

const failed = results.filter((ok) => !ok).length;
console.log(`\n${results.length - failed} correctas, ${failed} fallidas`);
if (exitCode || failed) {
  console.log('RESULTADO: FALLO — revisa las líneas marcadas con FALLO.');
  process.exit(1);
}
console.log('RESULTADO: ningún ataque P1–P10 ha funcionado y los datos existentes siguen intactos.');
process.exit(0);
