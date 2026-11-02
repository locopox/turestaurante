// Recuperación PROGRAMADA de invitaciones contra Supabase LOCAL con pg_cron, pg_net y Vault REALES y
// la Edge Function «invitations-recovery» en el Edge Runtime de Supabase.
// Requisitos: migración 20261105120000 aplicada; la función servida con INVITATIONS_RECOVERY_SECRET.
// Uso:
//   eval "$(supabase status -o env)"
//   RECOVERY_SECRET=<el mismo secreto de la función> RECOVERY_URL=<URL de la función vista desde la base de datos> \
//     node supabase/tests/local/recovery_integration_test.mjs [normal | sin-correo | tras-sin-correo]
//   «sin-correo»: con el servidor de correo PARADO (docker stop supabase_inbucket_<proyecto>): Supabase
//     Auth no puede entregar por SMTP. (En local, la CLI no aplica [auth.rate_limit] email_sent.)
//   «tras-sin-correo»: con el servidor de correo de nuevo en marcha; comprueba que lo pendiente se recupera.
// RECOVERY_URL en Supabase local suele ser http://supabase_kong_<proyecto>:8000/functions/v1/invitations-recovery
import {
  createConfirmedUser, email, invite, login, mailsTo, ok, PIAZZA, recover, rpc, sameExceptId, sleep, sql, summary, waitMails,
} from './lib.mjs';

const MODE = process.argv[2] ?? 'normal';
const SECRET = process.env.RECOVERY_SECRET;
const URL_FROM_DB = process.env.RECOVERY_URL;
if (!SECRET || !URL_FROM_DB) throw new Error('Faltan RECOVERY_SECRET y RECOVERY_URL');
const step = (t) => console.log(`\n== ${t}`);
const q = (s) => s.replace(/'/g, "''");

function setVault(url, secret) {
  sql(`delete from vault.secrets where name in ('turestaurante_recovery_url', 'turestaurante_recovery_secret')`);
  sql(`select vault.create_secret('${q(url)}', 'turestaurante_recovery_url', 'E4 local')`);
  sql(`select vault.create_secret('${q(secret)}', 'turestaurante_recovery_secret', 'E4 local')`);
}
/** Invitación pendiente «atascada»: creada hace 3 minutos y sin enviar (su proceso no llegó a hacerlo). */
function stuck(mail, restaurantId, inviterId, minutes = 3) {
  return sql(`insert into private.invitations (restaurant_id, email, role, invited_by, invited_by_kind, created_at, expires_at)
    select '${restaurantId}', '${mail}', 'waiter', '${inviterId}', 'personal', t, t + interval '168 hours'
    from (select now() - interval '${minutes} minutes' as t) x returning id`);
}
const state = (id) => sql(`select send_status || '/' || send_attempts from private.invitations where id = '${id}'`);
const owner = () => sql(`select user_id from public.restaurant_staff where restaurant_id = '${PIAZZA}' and role = 'owner' limit 1`);
/** Ejecuta la tarea como pg_cron y espera la respuesta HTTP real que guarda pg_net. */
async function tick() {
  const id = sql('select coalesce(private.invitations_recovery_tick()::text, \'\')');
  const outcome = sql('select outcome || coalesce(\'|\' || detail, \'\') from private.invitations_recovery_runs order by id desc limit 1');
  if (!id) return { id: null, outcome };
  const end = Date.now() + 40000;
  let res = '';
  while (Date.now() < end) {
    res = sql(`select coalesce(status_code::text, '') || '|' || coalesce(timed_out::text, '') || '|' || coalesce(error_msg, '') || '|' || coalesce(content, '') from net._http_response where id = ${id}`);
    if (res) break;
    await sleep(500);
  }
  const [status, timedOut, error, ...content] = res.split('|');
  let body = null;
  try { body = JSON.parse(content.join('|')); } catch { /* sin JSON */ }
  return { id, outcome, status: Number(status) || null, timedOut, error, body };
}

const ownerId = owner();
if (!ownerId) throw new Error('La Piazza no tiene propietario en esta base de datos (prepara los datos primero).');

if (MODE === 'normal') {
  step('1. Configuración real: extensiones, tarea y Vault');
  ok(sql(`select string_agg(extname, ',' order by extname) from pg_extension where extname in ('pg_cron', 'pg_net', 'supabase_vault')`) === 'pg_cron,pg_net,supabase_vault',
    'pg_cron, pg_net y supabase_vault instalados (reales)');
  ok(sql(`select count(*) || '|' || min(schedule) || '|' || bool_and(active) from cron.job where jobname = 'turestaurante-recuperar-invitaciones'`) === '1|*/5 * * * *|true',
    'una sola tarea, cada 5 minutos, activa');
  sql(`delete from vault.secrets where name in ('turestaurante_recovery_url', 'turestaurante_recovery_secret')`);
  // Sin entregas pendientes de esta prueba puede haber otras: solo se comprueba que con Vault vacío no llama.
  const P0 = email('vault-vacio');
  stuck(P0, PIAZZA, ownerId);
  const t0 = await tick();
  ok(t0.id === null && t0.outcome.startsWith('sin_configurar'), 'sin secretos en Vault: no llama y anota «sin_configurar»', t0.outcome);
  setVault(URL_FROM_DB, SECRET);
  ok(sql(`select count(*) from vault.secrets where name like 'turestaurante_recovery_%' and secret not like '%${q(SECRET)}%'`) === '2',
    'Vault guarda los secretos CIFRADOS (la columna secret no contiene el valor)');

  step('2. Autenticación de la función de recuperación');
  for (const [name, secret, headers] of [['sin secreto', null, {}], ['secreto incorrecto', 'x'.repeat(40), {}],
    ['clave secreta de Supabase', process.env.SERVICE_ROLE_KEY, {}], ['JWT de usuario', null, { Authorization: `Bearer ${await login(await (async () => { const m = email('jwt'); await createConfirmedUser(m); return m; })())}` }]]) {
    const r = await recover(secret, headers);
    ok(r.status === 401, `función de recuperación: ${name} → 401`, r);
  }
  const fromBrowser = await recover(SECRET, { Origin: 'http://127.0.0.1:5173' });
  ok(fromBrowser.status === 403, 'función de recuperación: con el secreto pero desde un navegador → 403', fromBrowser.status);
  setVault(URL_FROM_DB, 'z'.repeat(40));
  const tBad = await tick();
  ok(tBad.outcome === 'solicitada' && tBad.status === 401, 'pg_net llega a la función, pero con otro secreto en Vault: 401 (y queda anotado)', tBad);
  setVault(URL_FROM_DB, SECRET);

  step('3. pg_net + Edge Function: recupera entregas pendientes sin nuevas invitaciones');
  const M1 = email('atascada');
  const id1 = stuck(M1, PIAZZA, ownerId);
  const t1 = await tick();
  ok(t1.outcome === 'solicitada' && t1.status === 200 && t1.body?.ok === true, 'la tarea llama con pg_net y la función responde 200', t1);
  ok((await waitMails(M1, 1)).length === 1 && state(id1) === 'enviada/1', 'la invitación atascada se envía (correo en Mailpit, «enviada»)', state(id1));
  ok(!JSON.stringify(t1.body).includes('@'), 'el resumen de la respuesta no contiene correos', t1.body);
  // Reserva interrumpida (proceso caído hace 11 minutos)
  const M2 = email('interrumpida');
  const id2 = stuck(M2, PIAZZA, ownerId, 20);
  sql(`update private.invitations set send_status = 'enviando', send_attempts = 1, send_claim = gen_random_uuid(), send_claimed_at = now() - interval '11 minutes' where id = '${id2}'`);
  const t2 = await tick();
  ok(t2.status === 200 && (await waitMails(M2, 1)).length === 1 && state(id2) === 'enviada/2', 'una entrega interrumpida se retoma (2.º intento) y se envía', state(id2));
  const t3 = await tick();
  ok(t3.id === null && t3.outcome === 'sin_pendientes', 'sin pendientes: no llama a la función', t3.outcome);
  await sleep(1500);
  ok((await mailsTo(M1)).length === 1 && (await mailsTo(M2)).length === 1, 'no se reenvía lo ya enviado');

  step('4. Ejecuciones simultáneas de la recuperación');
  const many = Array.from({ length: 4 }, (_, i) => email(`paralelo${i}`));
  for (const m of many) stuck(m, PIAZZA, ownerId);
  const par = await Promise.all(Array.from({ length: 5 }, () => recover(SECRET)));
  ok(par.every((r) => r.status === 200), '5 llamadas simultáneas responden 200', par.map((r) => r.status));
  await sleep(3000);
  const counts = await Promise.all(many.map(async (m) => (await mailsTo(m)).length));
  ok(counts.every((c) => c === 1), 'cada entrega se envía UNA sola vez', counts);

  step('5. pg_cron ejecuta la tarea de verdad');
  const jobId = sql(`select jobid from cron.job where jobname = 'turestaurante-recuperar-invitaciones'`);
  const M3 = email('cron');
  const id3 = stuck(M3, PIAZZA, ownerId);
  const before = sql(`select coalesce(max(runid), 0) from cron.job_run_details where jobid = ${jobId}`);
  console.log('   (esperando a la siguiente ejecución programada; como mucho 5 minutos)');
  const end = Date.now() + 330000;
  let run = '';
  while (Date.now() < end) {
    run = sql(`select status || '|' || start_time from cron.job_run_details where jobid = ${jobId} and runid > ${before} order by runid desc limit 1`);
    if (run) break;
    await sleep(5000);
  }
  ok(run.startsWith('succeeded'), 'la tarea de cada 5 minutos se ejecuta sola y termina bien', run);
  ok((await waitMails(M3, 1, 40000)).length === 1 && state(id3) === 'enviada/1', 'y recupera la entrega pendiente sin intervención', state(id3));

  step('6. Estado visible solo para la plataforma');
  const A = email('plat-estado');
  const aid = await createConfirmedUser(A);
  sql(`insert into public.platform_admins (user_id) values ('${aid}')`);
  const tA = await login(A);
  const st = await rpc(tA, 'invitations_recovery_status', { p_limit: 20 });
  const jb = await rpc(tA, 'invitations_recovery_job');
  ok(st.status === 200 && st.body.some((r) => r.outcome === 'solicitada' && r.http_status === 200 && r.summary?.ok === true), 'plataforma: ve ejecuciones con su estado HTTP y resumen', st.body?.slice?.(0, 2));
  ok(jb.status === 200 && jb.body[0]?.schedule === '*/5 * * * *' && jb.body[0]?.last_status === 'succeeded', 'plataforma: ve la tarea y su última ejecución', jb.body);
  const tOwner = await login((await (async () => { const m = email('owner-ver'); const id = await createConfirmedUser(m); sql(`insert into public.restaurant_staff values ('${PIAZZA}', '${id}', 'manager')`); return m; })()));
  ok((await rpc(tOwner, 'invitations_recovery_status', { p_limit: 5 })).status >= 400, 'personal del restaurante: no ve la recuperación');
  ok((await rpc(null, 'invitations_recovery_status', { p_limit: 5 })).status >= 400, 'anónimo: no ve la recuperación');
}

if (MODE === 'sin-correo') {
  step('Fallo de entrega real (servidor de correo parado)');
  const O = email('owner-fallo');
  const oid = await createConfirmedUser(O);
  sql(`insert into public.restaurant_staff values ('${PIAZZA}', '${oid}', 'manager')`);
  const tO = await login(O);
  const NEW = email('sin-cuenta-fallo');
  const EXIST = email('con-cuenta-fallo');
  await createConfirmedUser(EXIST);
  const rNew = await invite(tO, { action: 'create', restaurantId: PIAZZA, email: NEW, role: 'waiter' });
  const rExist = await invite(tO, { action: 'create', restaurantId: PIAZZA, email: EXIST, role: 'waiter' });
  ok(rNew.status === 200 && rExist.status === 200 && sameExceptId(rNew.body, rExist.body), 'fallo de envío: la respuesta es idéntica a la de una cuenta existente', [rNew.body, rExist.body]);
  await sleep(4000);
  const sNew = state(rNew.body.invitationId);
  ok(sNew === 'sin_enviar/1', 'el envío falla (Auth no puede entregar por SMTP) y queda pendiente de reintento', sNew);
  ok(state(rExist.body.invitationId) === 'no_necesario/1', 'la cuenta existente no necesitaba correo');
  const listO = (await rpc(tO, 'invitation_list', { p_restaurant_id: PIAZZA })).body.filter((i) => [NEW, EXIST].includes(i.email));
  ok(listO.length === 2 && new Set(listO.map((i) => i.state)).size === 1 && listO.every((i) => !('send_status' in i)), 'el encargado ve las dos igual (pendientes), sin datos de entrega', listO);
  const audit = (await rpc(tO, 'audit_list', { p_restaurant_id: PIAZZA, p_limit: 500 })).body;
  ok(Array.isArray(audit) ? !audit.some((e) => e.action === 'invitacion.entrega') : true, 'el registro del restaurante no muestra el fallo');
  const reint = sql(`select count(*) from private.audit_log where action = 'invitacion.entrega' and restaurant_id is null and target_id = '${rNew.body.invitationId}' and details ->> 'resultado' = 'reintento'`);
  ok(reint === '1', 'el fallo queda en el registro SOLO para la plataforma (resultado «reintento»)', reint);
  ok(sql(`select count(*) from auth.users where lower(email) = '${NEW}'`) === '0', 'Supabase no deja una cuenta a medias cuando falla el envío');
  sql(`insert into private.invitations_recovery_runs (outcome, detail) values ('sin_pendientes', 'marca E4 ${rNew.body.invitationId}')`);
  console.log(`PENDIENTE_ID=${rNew.body.invitationId} PENDIENTE_EMAIL=${NEW}`);
}

if (MODE === 'tras-sin-correo') {
  step('Con el servidor de correo de nuevo en marcha: la entrega pendiente se recupera');
  const mark = sql(`select detail from private.invitations_recovery_runs where detail like 'marca E4 %' order by id desc limit 1`);
  const id = mark.replace('marca E4 ', '');
  const mail = sql(`select email from private.invitations where id = '${id}'`);
  ok(state(id) === 'sin_enviar/1', 'sigue pendiente, esperando la espera del reintento (5 min)', state(id));
  sql(`update private.invitations set send_next_at = now() - interval '1 second' where id = '${id}'`);
  const t = await tick();
  ok(t.status === 200 && (await waitMails(mail, 1)).length === 1 && state(id) === 'enviada/2', 'la tarea la recupera: correo enviado en el 2.º intento', state(id));
}

const failed = summary();
process.exit(failed ? 1 : 0);
