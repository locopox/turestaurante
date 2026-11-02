// Pruebas de integración de la fase 6 contra Supabase LOCAL (base de datos, Auth, Mailpit y la Edge
// Function «invitations» en el Edge Runtime de Supabase). Repetibles: cada ejecución crea sus datos.
// Uso (en la carpeta del Supabase local, con la función servida y APP_URL configurada):
//   eval "$(supabase status -o env)" && node supabase/tests/local/integration_test.mjs
// Variable opcional: APP_URL (por defecto http://127.0.0.1:5173/), la misma que tiene la función.
import { randomBytes } from 'node:crypto';
import {
  createConfirmedUser, email, followLink, getUser, invite, inviteLinks, login, mailsTo, ok, rest, rpc, sameExceptId,
  setPassword, sleep, sql, summary, waitMails,
} from './lib.mjs';

const APP_URL = process.env.APP_URL ?? 'http://127.0.0.1:5173/';
const step = (t) => console.log(`\n== ${t}`);
const msgOf = (r) => (r.body && (r.body.error ?? r.body.message ?? r.body.msg)) || '';

/** Cuenta NUEVA invitada: correo real → enlace type=invite → contraseña. Devuelve el token de sesión. */
async function activateFromMail(mail, n = 1) {
  const list = await waitMails(mail, n);
  const links = await inviteLinks(mail);
  const last = links[links.length - 1];
  if (!last) return { token: null, list, links };
  const f = await followLink(last.link);
  if (!f.accessToken) return { token: null, list, links, follow: f };
  await setPassword(f.accessToken, mail);
  return { token: await login(mail), list, links, follow: f };
}
const myInvitation = async (token, restaurantId) => (await rpc(token, 'my_invitations')).body?.find?.((i) => i.restaurant_id === restaurantId);
const roleIn = async (token, restaurantId) => (await rpc(token, 'my_memberships')).body?.find?.((m) => m.restaurant_id === restaurantId)?.role ?? null;
const invId = (r) => r.body?.invitationId;
const invState = (id) => sql(`select private.invitation_state(status, expires_at) || '/' || send_status from private.invitations where id = '${id}'`);

// ========== 1. Plataforma: crear dos restaurantes con su primer propietario (cuentas nuevas) ==========
step('1. La plataforma crea dos restaurantes con propietario invitado por correo');
const ADMIN = email('plataforma');
const adminId = await createConfirmedUser(ADMIN);
sql(`insert into public.platform_admins (user_id) values ('${adminId}')`);
const tAdmin = await login(ADMIN);
const OWNER_A = email('owner-a'), OWNER_B = email('owner-b');
const cA = await invite(tAdmin, { action: 'create_restaurant', name: `Restaurante A ${email('x').slice(2, 8)}`, slug: `ra-${email('x').split('@')[0].slice(2)}`, ownerEmail: OWNER_A });
const cB = await invite(tAdmin, { action: 'create_restaurant', name: `Restaurante B ${email('y').slice(2, 8)}`, slug: `rb-${email('y').split('@')[0].slice(2)}`, ownerEmail: OWNER_B });
ok(cA.status === 200 && cA.body.ok && cA.body.restaurantId, 'plataforma: crea el restaurante A con invitación de propietario', cA);
ok(cB.status === 200 && cB.body.ok && cB.body.restaurantId, 'plataforma: crea el restaurante B con invitación de propietario', cB);
const RA = cA.body.restaurantId, RB = cB.body.restaurantId;
ok(sql(`select active from public.restaurants where id = '${RA}'`) === 'f', 'restaurante nuevo: nace cerrado');
const actPlat = await rest(tAdmin, `restaurants?id=eq.${RA}`, { method: 'PATCH', body: JSON.stringify({ active: true }) });
ok(actPlat.status >= 400 && /propietario acepte/.test(JSON.stringify(actPlat.body)), 'plataforma: no puede abrirlo sin propietario', actPlat);

const mailsA = await waitMails(OWNER_A, 1);
ok(mailsA.length === 1, 'correo REAL de invitación en Mailpit para el propietario A (cuenta nueva)', mailsA.length);
const linkA = (await inviteLinks(OWNER_A))[0];
ok(linkA && /type=invite/.test(linkA.link), 'el correo contiene el enlace de Supabase Auth con type=invite', linkA?.link);
ok(linkA && new URL(linkA.link).searchParams.get('redirect_to') === APP_URL, 'el enlace vuelve a APP_URL (fijada en el servidor)', linkA && new URL(linkA.link).searchParams.get('redirect_to'));
const fA = await followLink(linkA.link);
ok(fA.status === 303 || fA.status === 302, 'Supabase Auth verifica el enlace y redirige', fA.status);
ok(fA.location.startsWith(APP_URL) && fA.type === 'invite' && !!fA.accessToken, 'la redirección llega a la app con #access_token…&type=invite', fA.location.slice(0, 80));
const uA = await getUser(fA.accessToken);
ok(uA.status === 200 && !!uA.body.email_confirmed_at, 'al pulsar el enlace, el correo queda CONFIRMADO', uA.body?.email_confirmed_at);
// Antes de aceptar: ningún permiso
ok((await roleIn(fA.accessToken, RA)) === null, 'antes de aceptar: no pertenece al restaurante');
const listBefore = await rpc(fA.accessToken, 'invitation_list', { p_restaurant_id: RA });
ok(listBefore.status >= 400, 'antes de aceptar: no ve las invitaciones del restaurante', listBefore.status);
const kitBefore = await rpc(fA.accessToken, 'kitchen_orders', { p_restaurant_id: RA });
ok(kitBefore.status >= 400, 'antes de aceptar: no ve la cocina', kitBefore.status);
const actBefore = await rest(fA.accessToken, `restaurants?id=eq.${RA}`, { method: 'PATCH', body: JSON.stringify({ prep_minutes: 33 }) });
ok(Array.isArray(actBefore.body) && actBefore.body.length === 0, 'antes de aceptar: no cambia la configuración', actBefore);
// Contraseña y aceptación
const pw = await setPassword(fA.accessToken, OWNER_A);
ok(pw.status === 200, 'cuenta nueva: establece su contraseña con la sesión del enlace', pw.status);
const tOwnerA = await login(OWNER_A);
ok(!!tOwnerA, 'cuenta nueva: inicia sesión con su contraseña');
const invA = await myInvitation(tOwnerA, RA);
ok(invA && invA.role === 'owner', 've su invitación de propietario', invA);
const accA = await rpc(tOwnerA, 'invitation_accept', { p_invitation_id: invA.id });
ok(accA.status === 200 && accA.body === RA, 'acepta la invitación', accA);
ok((await roleIn(tOwnerA, RA)) === 'owner', 'tras aceptar: es propietario de A');
const open = await rest(tOwnerA, `restaurants?id=eq.${RA}`, { method: 'PATCH', body: JSON.stringify({ active: true }) });
ok(open.status === 200 && open.body?.[0]?.active === true, 'con propietario: ya se puede abrir', open.status);
const actB = await activateFromMail(OWNER_B);
const invB = await myInvitation(actB.token, RB);
await rpc(actB.token, 'invitation_accept', { p_invitation_id: invB.id });
const tOwnerB = actB.token;
ok((await roleIn(tOwnerB, RB)) === 'owner', 'propietario B: mismo recorrido por correo, es propietario de B');
ok((await roleIn(tOwnerB, RA)) === null && (await roleIn(tOwnerA, RB)) === null, 'cada propietario solo tiene su restaurante');

// ========== 2. Equipo: encargado y empleados (nuevos), con sus restricciones ==========
step('2. Propietario A invita a un encargado y a cocina; restricciones de cada rol');
const MGR = email('manager-a');
const iMgr = await invite(tOwnerA, { action: 'create', restaurantId: RA, email: MGR, role: 'manager' });
ok(iMgr.status === 200, 'owner: invita a un encargado', iMgr);
const aMgr = await activateFromMail(MGR);
await rpc(aMgr.token, 'invitation_accept', { p_invitation_id: (await myInvitation(aMgr.token, RA)).id });
const tMgr = aMgr.token;
ok((await roleIn(tMgr, RA)) === 'manager', 'encargado: entra por correo y es encargado de A');
const cases = [
  [tOwnerA, RA, 'owner', 403, 'owner no invita a propietarios'],
  [tMgr, RA, 'manager', 403, 'encargado no invita a encargados'],
  [tMgr, RA, 'owner', 403, 'encargado no invita a propietarios'],
  [tMgr, RB, 'waiter', 403, 'encargado de A no invita en B'],
  [tOwnerB, RA, 'waiter', 403, 'propietario de B no invita en A'],
];
for (const [t, r, role, st, name] of cases) {
  const x = await invite(t, { action: 'create', restaurantId: r, email: email('no'), role });
  ok(x.status === st, name, `${x.status} ${msgOf(x)}`);
}
const KIT = email('cocina-a');
const iKit = await invite(tMgr, { action: 'create', restaurantId: RA, email: KIT, role: 'kitchen' });
ok(iKit.status === 200, 'encargado: invita a cocina', iKit);
const aKit = await activateFromMail(KIT);
await rpc(aKit.token, 'invitation_accept', { p_invitation_id: (await myInvitation(aKit.token, RA)).id });
const tKit = aKit.token;
ok((await roleIn(tKit, RA)) === 'kitchen', 'cocina: entra como cocina');
const kitInv = await invite(tKit, { action: 'create', restaurantId: RA, email: email('no'), role: 'kitchen' });
ok(kitInv.status === 403, 'cocina: no invita a nadie', kitInv.status);
const noSess = await invite(null, { action: 'create', restaurantId: RA, email: email('no'), role: 'waiter' });
ok(noSess.status === 401, 'sin sesión: el gateway (verify_jwt) lo rechaza', noSess.status);
const anonOnly = await invite(undefined, { action: 'create', restaurantId: RA, email: email('no'), role: 'waiter' }, { Authorization: `Bearer ${process.env.ANON_KEY}` });
ok(anonOnly.status === 401, 'con la clave pública (sin usuario): rechazado', anonOnly.status);
const platAccept = await rpc(tAdmin, 'my_invitations');
ok(platAccept.status === 200 && platAccept.body.length === 0, 'plataforma: no tiene invitaciones para ser personal');

// ========== 3. Cuenta EXISTENTE en dos restaurantes, sin correo; permisos separados ==========
step('3. Una cuenta existente en dos restaurantes con funciones distintas');
const DOBLE = email('doble');
await createConfirmedUser(DOBLE);
const tDoble = await login(DOBLE);
const iD1 = await invite(tOwnerA, { action: 'create', restaurantId: RA, email: DOBLE, role: 'waiter' });
const iD2 = await invite(tOwnerB, { action: 'create', restaurantId: RB, email: DOBLE, role: 'kitchen' });
ok(iD1.status === 200 && iD2.status === 200, 'dos restaurantes la invitan (sala en A, cocina en B)');
await sleep(2500);
ok((await mailsTo(DOBLE)).length === 0, 'cuenta existente confirmada: NO recibe correo (lo verá en la app)');
ok(invState(invId(iD1)).endsWith('/no_necesario'), 'su entrega queda «no_necesario»', invState(invId(iD1)));
ok((await roleIn(tDoble, RA)) === null && (await roleIn(tDoble, RB)) === null, 'antes de aceptar: ningún permiso en A ni en B');
const ordersBefore = await rest(tDoble, `orders?restaurant_id=eq.${RA}&select=id`);
ok(ordersBefore.status === 200 && ordersBefore.body.length === 0, 'antes de aceptar: no ve pedidos');
const mine = (await rpc(tDoble, 'my_invitations')).body;
ok(mine.length === 2 && mine.every((i) => typeof i.role === 'string'), 've sus dos invitaciones en la app', mine);
for (const i of mine) await rpc(tDoble, 'invitation_accept', { p_invitation_id: i.id });
ok((await roleIn(tDoble, RA)) === 'waiter' && (await roleIn(tDoble, RB)) === 'kitchen', 'tras aceptar: sala en A y cocina en B');
// Un pedido en A y otro en B para comprobar permisos
const prodA = sql(`with c as (insert into public.categories (restaurant_id, name) values ('${RA}', 'Platos') returning id)
  insert into public.products (restaurant_id, category_id, name, price_cents) select '${RA}', id, 'Plato A', 900 from c returning id`);
const prodB = sql(`with c as (insert into public.categories (restaurant_id, name) values ('${RB}', 'Platos') returning id)
  insert into public.products (restaurant_id, category_id, name, price_cents) select '${RB}', id, 'Plato B', 800 from c returning id`);
sql(`update public.restaurants set active = true where id = '${RB}'`);
for (const [r, p] of [[RA, prodA], [RB, prodB]]) {
  await rpc(null, 'create_order', { payload: { restaurantId: r, mode: 'mesa', table: 1, paymentMethod: 'caja', accessToken: randomBytes(32).toString('hex'), items: [{ productId: p, quantity: 1 }] } });
}
const oA = await rest(tDoble, `orders?restaurant_id=eq.${RA}&select=id`);
const oB = await rest(tDoble, `orders?restaurant_id=eq.${RB}&select=id`);
const kB = await rpc(tDoble, 'kitchen_orders', { p_restaurant_id: RB });
ok(oA.body.length === 1, 'en A (sala): ve los pedidos', oA.body);
ok(oB.body.length === 0 && kB.status === 200 && kB.body.length === 1, 'en B (cocina): no ve pedidos, sí las comandas', { oB: oB.body, kB: kB.status });
const inviteAsWaiter = await invite(tDoble, { action: 'create', restaurantId: RB, email: email('no'), role: 'kitchen' });
ok(inviteAsWaiter.status === 403, 'ser propietario en ningún sitio: no invita en B', inviteAsWaiter.status);
const removed = await rpc(tOwnerA, 'staff_remove_member', { p_restaurant_id: RA, p_user_id: sql(`select id from auth.users where email = '${DOBLE}'`) });
ok(removed.status === 200 || removed.status === 204, 'el propietario de A le retira el acceso', removed.status);
const oA2 = await rest(tDoble, `orders?restaurant_id=eq.${RA}&select=id`);
const kB2 = await rpc(tDoble, 'kitchen_orders', { p_restaurant_id: RB });
ok(oA2.body.length === 0 && (await roleIn(tDoble, RA)) === null, 'pierde AL INSTANTE el acceso a A (misma sesión)');
ok(kB2.status === 200 && (await roleIn(tDoble, RB)) === 'kitchen', 'conserva su cuenta y su acceso a B');

// ========== 4. Cuenta invitada SIN CONFIRMAR: nuevo enlace, sin cuenta duplicada ==========
step('4. Cuenta invitada que aún no ha confirmado');
const PEND = email('sinconfirmar');
const p1 = await invite(tOwnerA, { action: 'create', restaurantId: RA, email: PEND, role: 'waiter' });
await waitMails(PEND, 1);
const p2 = await invite(tOwnerB, { action: 'create', restaurantId: RB, email: PEND, role: 'waiter' });
const pendMails = await waitMails(PEND, 2);
ok(p1.status === 200 && p2.status === 200 && pendMails.length === 2, 'sin confirmar: la segunda invitación le reenvía el enlace (2 correos)', pendMails.length);
ok(sql(`select count(*) from auth.users where lower(email) = '${PEND}'`) === '1', 'Supabase no crea una cuenta duplicada');
const [oldLink, newLink] = await inviteLinks(PEND);
const fOld = await followLink(oldLink.link);
ok(!fOld.accessToken && !!(fOld.error || fOld.errorCode), 'el enlace anterior ya no vale', fOld.location.slice(0, 120));
const fNew = await followLink(newLink.link);
ok(!!fNew.accessToken && fNew.type === 'invite', 'el enlace nuevo sí abre sesión (type=invite)');
await setPassword(fNew.accessToken, PEND);
const tPend = await login(PEND);
ok((await rpc(tPend, 'my_invitations')).body.length === 2, 've las invitaciones de los dos restaurantes');

// ========== 5. Rechazar, revocar, caducar y reenviar ==========
step('5. Rechazo, revocación, caducidad y reenvío');
const RECH = email('rechaza');
await createConfirmedUser(RECH);
const tRech = await login(RECH);
const iR = await invite(tOwnerA, { action: 'create', restaurantId: RA, email: RECH, role: 'kitchen' });
const dec = await rpc(tRech, 'invitation_decline', { p_invitation_id: invId(iR) });
ok(dec.status === 200 || dec.status === 204, 'rechazar', dec);
const accR = await rpc(tRech, 'invitation_accept', { p_invitation_id: invId(iR) });
ok(accR.status >= 400 && /ya no está disponible/.test(msgOf(accR)), 'rechazada: ya no se puede aceptar', msgOf(accR));
const listOwner = (await rpc(tOwnerA, 'invitation_list', { p_restaurant_id: RA })).body;
ok(listOwner.find((i) => i.id === invId(iR))?.state === 'rechazada', 'el propietario la ve rechazada');

const REV = email('revocada');
const iRev = await invite(tMgr, { action: 'create', restaurantId: RA, email: REV, role: 'waiter' });
const rv = await rpc(tMgr, 'invitation_revoke', { p_invitation_id: invId(iRev) });
ok(rv.status === 200 || rv.status === 204, 'encargado: revoca una invitación de sala', rv.status);
const aRev = await activateFromMail(REV);
ok(!!aRev.token && (await rpc(aRev.token, 'my_invitations')).body.length === 0, 'revocada: la persona no la ve aunque active su cuenta');
const accRev = await rpc(aRev.token, 'invitation_accept', { p_invitation_id: invId(iRev) });
ok(accRev.status >= 400 && (await roleIn(aRev.token, RA)) === null, 'revocada: no se puede aceptar ni da permisos', msgOf(accRev));
const iMgrOwnerInv = (await rpc(tMgr, 'invitation_list', { p_restaurant_id: RA })).body.find((i) => i.role === 'manager');
const rvMgr = await rpc(tMgr, 'invitation_revoke', { p_invitation_id: iMgrOwnerInv?.id ?? '00000000-0000-0000-0000-000000000000' });
ok(rvMgr.status >= 400, 'encargado: no revoca la invitación de un encargado', rvMgr.status);

const CAD = email('caducada');
await createConfirmedUser(CAD);
const ownerAId = sql(`select id from auth.users where email = '${OWNER_A}'`);
const cadId = sql(`insert into private.invitations (restaurant_id, email, role, invited_by, invited_by_kind, created_at, expires_at)
  select '${RA}', '${CAD}', 'waiter', '${ownerAId}', 'personal', t, t + interval '168 hours' from (select now() - interval '8 days' as t) x returning id`);
const tCad = await login(CAD);
ok((await rpc(tCad, 'my_invitations')).body.length === 0, 'caducada (8 días): no aparece');
const accCad = await rpc(tCad, 'invitation_accept', { p_invitation_id: cadId });
ok(accCad.status >= 400 && /caducado/.test(msgOf(accCad)), 'caducada: no se puede aceptar', msgOf(accCad));
const resCad = await invite(tOwnerA, { action: 'resend', invitationId: cadId });
ok(resCad.status === 400 && /caducado/.test(msgOf(resCad)), 'caducada: no se reenvía (hay que crear otra)', `${resCad.status} ${msgOf(resCad)}`);

const RES = email('reenvio');
const oldId = sql(`insert into private.invitations (restaurant_id, email, role, invited_by, invited_by_kind, created_at, expires_at)
  select '${RA}', '${RES}', 'waiter', '${ownerAId}', 'personal', t, t + interval '168 hours' from (select now() - interval '10 minutes' as t) x returning id`);
const rs = await invite(tOwnerA, { action: 'resend', invitationId: oldId });
ok(rs.status === 200 && invId(rs) && invId(rs) !== oldId, 'reenviar (pasados 5 min): crea una invitación nueva', rs);
ok((await waitMails(RES, 1)).length === 1, 'el reenvío llega por correo');
ok(invState(oldId).startsWith('reemplazada'), 'la anterior queda reemplazada', invState(oldId));
const rs2 = await invite(tOwnerA, { action: 'resend', invitationId: invId(rs) });
ok(rs2.status === 429 && /5 minutos/.test(msgOf(rs2)), 'reenviar otra vez enseguida: 429 (espera de 5 minutos)', `${rs2.status} ${msgOf(rs2)}`);

// ========== 6. No revelar si el correo tiene cuenta ==========
step('6. Misma respuesta tenga o no cuenta el correo');
const cmp = [
  ['sin cuenta', email('fantasma')],
  ['cuenta confirmada sin restaurante', RECH],
  ['personal de otro restaurante', OWNER_B],
  ['cuenta de plataforma', ADMIN],
];
const responses = [];
for (const [, m] of cmp) responses.push(await invite(tMgr, { action: 'create', restaurantId: RA, email: m, role: 'waiter' }));
ok(responses.every((r) => r.status === 200), 'todas responden 200', responses.map((r) => r.status));
ok(responses.every((r) => sameExceptId(r.body, responses[0].body)), 'el cuerpo es idéntico (salvo el identificador)', responses.map((r) => r.body));
const newIds = responses.map(invId);
const listM = (await rpc(tMgr, 'invitation_list', { p_restaurant_id: RA })).body.filter((i) => newIds.includes(i.id));
ok(listM.length === 4 && new Set(listM.map((i) => JSON.stringify([i.state, i.can_manage, i.invited_by_label, i.resend_count]))).size === 1, 'la lista del encargado es idéntica en los cuatro casos', listM);
ok(listM.every((i) => !('send_status' in i) && !('account_exists' in i)), 'la lista no incluye nada sobre la entrega ni la cuenta');
const auditOwner = (await rpc(tOwnerA, 'audit_list', { p_restaurant_id: RA, p_limit: 500 })).body;
ok(auditOwner.some((e) => e.action === 'invitacion.creada') && !auditOwner.some((e) => e.action === 'invitacion.entrega'),
  'el propietario ve las invitaciones en su registro, pero no las entregas');
const auditPlat = (await rpc(tAdmin, 'audit_list', { p_restaurant_id: null, p_limit: 500 })).body;
ok(auditPlat.some((e) => e.action === 'invitacion.entrega' && e.details.restaurante === RA && e.details.resultado === 'no_necesario')
  && auditPlat.some((e) => e.action === 'invitacion.entrega' && e.details.restaurante === RA && e.details.resultado === 'enviada'), 'la plataforma sí ve las entregas (enviada / no necesaria)');
// En los DETALLES el correo invitado va enmascarado (actor_email es la identidad de quien actúa, no el invitado).
ok(auditPlat.filter((e) => e.action.startsWith('invitacion.')).every((e) => !/[^*]@/.test(String(e.details.correo ?? '')) && /^.\*\*\*@/.test(String(e.details.correo ?? 'x***@'))),
  'los detalles del registro guardan el correo invitado enmascarado');

// ========== 7. Límites ==========
step('7. Límites: 20 invitaciones por hora');
const ownerBId = sql(`select id from auth.users where email = '${OWNER_B}'`);
const already = Number(sql(`select count(*) from private.invitations where invited_by = '${ownerBId}' and replaces is null and created_at > now() - interval '1 hour'`));
const many = [];
for (let i = 0; i < 20 - already; i++) many.push(await invite(tOwnerB, { action: 'create', restaurantId: RB, email: email(`lote${i}`), role: 'waiter' }));
ok(many.every((r) => r.status === 200), `propietario B: hasta 20 invitaciones nuevas (${already} ya hechas + ${many.length})`, many.filter((r) => r.status !== 200).map((r) => `${r.status} ${msgOf(r)}`));
const r21 = await invite(tOwnerB, { action: 'create', restaurantId: RB, email: email('lote21'), role: 'waiter' });
ok(r21.status === 429 && /20 invitaciones/.test(msgOf(r21)), 'la 21.ª en la misma hora: 429', `${r21.status} ${msgOf(r21)}`);

// ========== 8. Concurrencia ==========
step('8. Peticiones simultáneas');
const SAME = email('simultanea');
const par = await Promise.all(Array.from({ length: 8 }, () => invite(tOwnerA, { action: 'create', restaurantId: RA, email: SAME, role: 'kitchen' })));
ok(par.filter((r) => r.status === 200).length === 1, '8 invitaciones simultáneas al mismo correo: se crea UNA', par.map((r) => r.status));
await sleep(3000);
ok((await mailsTo(SAME)).length === 1, 'y llega UN solo correo');
const RES2 = email('reenvio-simultaneo');
const old2 = sql(`insert into private.invitations (restaurant_id, email, role, invited_by, invited_by_kind, created_at, expires_at)
  select '${RA}', '${RES2}', 'waiter', '${ownerAId}', 'personal', t, t + interval '168 hours' from (select now() - interval '10 minutes' as t) x returning id`);
const par2 = await Promise.all(Array.from({ length: 6 }, () => invite(tOwnerA, { action: 'resend', invitationId: old2 })));
ok(par2.filter((r) => r.status === 200).length === 1, '6 reenvíos simultáneos: solo UNO crea invitación', par2.map((r) => r.status));
await sleep(3000);
ok((await mailsTo(RES2)).length === 1, 'y llega UN solo correo');

const failed = summary();
process.exit(failed ? 1 : 0);
