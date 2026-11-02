import { expect, test, type Page } from '@playwright/test';
// Utilidades compartidas con las pruebas de integración (comprueban que todo sea LOCAL).
import {
  createConfirmedUser, email, followLink, invite, inviteLinks, login, mailsTo, password, rpc, setPassword, sql, waitMails,
} from '../supabase/tests/local/lib.mjs';

/**
 * Recorridos principales de la fase 6 en el navegador, contra Supabase LOCAL (Auth, base de datos,
 * Mailpit y Edge Functions reales). Cada prueba crea sus restaurantes y cuentas (correos *.e4.test,
 * contraseñas aleatorias): no hay credenciales en el repositorio.
 */

let tPlatform = '';
test.beforeAll(async () => {
  const admin = email('e2e-plataforma');
  const id = await createConfirmedUser(admin);
  sql(`insert into public.platform_admins (user_id) values ('${id}')`);
  tPlatform = await login(admin);
});

/** Restaurante nuevo con propietario (cuenta nueva activada desde el correo real). */
async function restaurantWithOwner(label: string) {
  const ownerEmail = email(`e2e-owner-${label}`);
  const slug = `e2e-${label}-${email('s').split('@')[0].slice(2)}`.slice(0, 40).replace(/-+$/, '');
  const name = `E2E ${label} ${slug.slice(-6)}`;
  const r = await invite(tPlatform, { action: 'create_restaurant', name, slug, ownerEmail });
  expect(r.status, JSON.stringify(r.body)).toBe(200);
  await waitMails(ownerEmail, 1);
  const [link] = await inviteLinks(ownerEmail);
  const f = await followLink(link.link);
  await setPassword(f.accessToken, ownerEmail);
  const token = await login(ownerEmail);
  const mine = (await rpc(token, 'my_invitations')).body as { id: string }[];
  await rpc(token, 'invitation_accept', { p_invitation_id: mine[0].id });
  sql(`update public.restaurants set active = true where id = '${r.body.restaurantId}'`);
  return { id: r.body.restaurantId as string, name, ownerEmail, token };
}

async function uiLogin(page: Page, mail: string) {
  await page.goto('#panel');
  await page.locator('#login-email').fill(mail);
  await page.locator('#login-password').fill(password(mail));
  await page.locator('button[type=submit]').click();
  await expect(page.locator('.session__who')).toBeAttached();
}
const options = (page: Page) => page.locator('#rest-select option').allTextContents();

test('cuenta nueva: el propietario invita, la persona activa su cuenta desde el correo y acepta', async ({ page }) => {
  const A = await restaurantWithOwner('nueva');
  await uiLogin(page, A.ownerEmail);
  await page.goto('#admin');
  await page.getByRole('tab', { name: 'Equipo' }).click();
  await expect(page.locator('#invite-role option')).toHaveText(['Encargado', 'Sala', 'Cocina']);
  const nueva = email('e2e-nueva');
  await page.locator('#invite-email').fill(nueva);
  await page.locator('#invite-role').selectOption({ label: 'Sala' });
  await page.getByRole('button', { name: 'Invitar', exact: true }).click();
  await expect(page.locator('.notice--ok')).toContainText('Si la persona ya tiene cuenta');
  await expect(page.locator('.team__row', { hasText: nueva })).toContainText('Pendiente');
  await page.getByRole('button', { name: 'Salir' }).click();

  // Correo real en el buzón local de Supabase; el navegador sigue el enlace como lo haría la persona.
  expect((await waitMails(nueva, 1)).length).toBe(1);
  const [link] = await inviteLinks(nueva);
  await page.goto(link.link);
  await expect(page.getByRole('heading', { name: 'Elige tu contraseña' })).toBeVisible();
  await expect(page.getByText('ya está confirmado')).toBeVisible();
  await expect(page.locator('.appnav').getByText('Panel')).toHaveCount(0); // nada más hasta elegir contraseña
  await page.locator('#recovery-new').fill(password(nueva));
  await page.locator('#recovery-repeat').fill(password(nueva));
  await page.getByRole('button', { name: 'Activar mi cuenta' }).click();
  await expect(page).toHaveURL(/#invitaciones$/);
  const card = page.locator('[data-invitation]', { hasText: A.name });
  await expect(card).toContainText('Sala');
  await expect(card.locator('select')).toHaveCount(0); // la función no se elige
  await card.getByRole('button', { name: 'Aceptar' }).click();
  await expect(page.getByText(`Ya formas parte de ${A.name} como Sala`)).toBeVisible();
  await expect(page).toHaveURL(/#panel$/);
  expect(await options(page)).toEqual([`${A.name} · Sala`]);
  // Y puede volver a entrar con su contraseña
  await page.getByRole('button', { name: 'Salir' }).click();
  await uiLogin(page, nueva);
  expect(await options(page)).toEqual([`${A.name} · Sala`]);
});

test('cuenta existente en dos restaurantes: aviso, aceptar y permisos distintos en cada uno', async ({ page }) => {
  const A = await restaurantWithOwner('doble-a');
  const B = await restaurantWithOwner('doble-b');
  const doble = email('e2e-doble');
  await createConfirmedUser(doble);
  expect((await invite(A.token, { action: 'create', restaurantId: A.id, email: doble, role: 'waiter' })).status).toBe(200);
  expect((await invite(B.token, { action: 'create', restaurantId: B.id, email: doble, role: 'kitchen' })).status).toBe(200);
  await uiLogin(page, doble);
  await expect(page.getByText('Tienes 2 invitaciones pendientes').first()).toBeVisible();
  expect((await mailsTo(doble)).length).toBe(0); // cuenta existente: sin correo, lo ve en la app
  await page.getByRole('link', { name: 'Ver invitaciones' }).click();
  for (const name of [A.name, B.name]) {
    await page.locator('[data-invitation]', { hasText: name }).getByRole('button', { name: 'Aceptar' }).click();
    await expect(page.getByText(`Ya formas parte de ${name}`)).toBeVisible();
    if (name === A.name) await page.goto('#invitaciones');
  }
  await page.goto('#panel');
  await expect.poll(() => options(page)).toEqual(expect.arrayContaining([`${A.name} · Sala`, `${B.name} · Cocina`]));
  await page.locator('#rest-select').selectOption({ label: `${B.name} · Cocina` });
  await expect(page.locator('.appnav').getByText('Cocina')).toBeVisible();
  await expect(page.locator('.appnav').getByText('Panel')).toHaveCount(0);
  await page.locator('#rest-select').selectOption({ label: `${A.name} · Sala` });
  await expect(page.locator('.appnav').getByText('Panel')).toBeVisible();
  await expect(page.locator('.appnav').getByText('Admin')).toHaveCount(0);
});

test('rechazar una invitación y revocar otra', async ({ page }) => {
  const A = await restaurantWithOwner('rechazo');
  const persona = email('e2e-rechaza');
  await createConfirmedUser(persona);
  const iR = await invite(A.token, { action: 'create', restaurantId: A.id, email: persona, role: 'kitchen' });
  const revEmail = email('e2e-revocada');
  await invite(A.token, { action: 'create', restaurantId: A.id, email: revEmail, role: 'waiter' });
  await uiLogin(page, persona);
  await page.goto('#invitaciones');
  const card = page.locator('[data-invitation]', { hasText: A.name });
  await card.getByRole('button', { name: 'Rechazar…' }).click();
  await card.getByRole('button', { name: 'Sí, rechazar' }).click();
  await expect(page.getByText(`Has rechazado la invitación de ${A.name}`)).toBeVisible();
  await expect(page.locator('[data-invitation]')).toHaveCount(0);
  await page.getByRole('button', { name: 'Salir' }).click();

  await uiLogin(page, A.ownerEmail);
  await page.goto('#admin');
  await page.getByRole('tab', { name: 'Equipo' }).click();
  await expect(page.locator(`[data-invitation="${iR.body.invitationId}"]`)).toContainText('Rechazada');
  const row = page.locator('.team__row', { hasText: revEmail });
  await row.getByRole('button', { name: 'Revocar…' }).click();
  await row.getByRole('button', { name: 'Revocar', exact: true }).click();
  await expect(row).toContainText('Revocada');
});

test('restricciones: encargado y plataforma; mismo mensaje tenga o no cuenta el correo', async ({ page }) => {
  const A = await restaurantWithOwner('roles');
  const mgr = email('e2e-encargado');
  await createConfirmedUser(mgr);
  const iM = await invite(A.token, { action: 'create', restaurantId: A.id, email: mgr, role: 'manager' });
  await rpc(await login(mgr), 'invitation_accept', { p_invitation_id: iM.body.invitationId });

  await uiLogin(page, mgr);
  await page.goto('#admin');
  await page.getByRole('tab', { name: 'Equipo' }).click();
  await expect(page.locator('#invite-role option')).toHaveText(['Sala', 'Cocina']);
  // Mismo mensaje para un correo sin cuenta, una cuenta existente sin restaurante y el propietario de otro restaurante.
  const otro = await restaurantWithOwner('roles-otro');
  const existente = email('e2e-existente');
  await createConfirmedUser(existente);
  const notices: string[] = [];
  for (const target of [email('e2e-sin-cuenta'), existente, otro.ownerEmail]) {
    await page.locator('#invite-email').fill(target);
    await page.getByRole('button', { name: 'Invitar', exact: true }).click();
    await expect(page.locator('#invite-email')).toHaveValue('');
    await expect(page.locator('.notice--ok')).toBeVisible();
    notices.push((await page.locator('.notice--ok').textContent()) ?? '');
  }
  expect(notices).toHaveLength(3);
  expect(new Set(notices).size).toBe(1);
  await page.getByRole('button', { name: 'Salir' }).click();

  // Plataforma: alta de restaurante con propietario desde la interfaz
  const platformEmail = email('e2e-plataforma-ui');
  const pid = await createConfirmedUser(platformEmail);
  sql(`insert into public.platform_admins (user_id) values ('${pid}')`);
  await uiLogin(page, platformEmail);
  await page.goto('#admin');
  await page.getByRole('button', { name: 'Nuevo restaurante' }).click();
  const nombre = `E2E Plataforma ${email('n').slice(2, 8)}`;
  const duena = email('e2e-duena');
  await page.locator('#nr-name').fill(nombre);
  await page.locator('#nr-owner').fill(duena);
  await page.getByRole('button', { name: 'Crear restaurante' }).click();
  await expect(page.getByText(`${nombre} creado`)).toBeVisible();
  expect((await waitMails(duena, 1)).length).toBe(1);
  await page.goto('#invitaciones');
  await expect(page.getByText('Las cuentas de la plataforma no pueden ser personal')).toBeVisible();
});
