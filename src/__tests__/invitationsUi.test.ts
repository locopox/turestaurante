import { describe, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { parseAuthRedirect, staffGate } from '../lib/authRedirect';
import { auditActionLabel } from '../lib/audit';
import {
  deliveryResultLabel, INVITE_HINT, invitableRoles, invitationDetail, invitationStateLabel, MAX_RESENDS, resendStatus,
  RESEND_WAIT_MS, resolveSelected, restaurantOptionLabel, selectableRestaurants, visibleInvitations,
} from '../lib/invitations';
import { can, canOpenAdmin } from '../lib/permissions';
import { SupabaseDataService, type BrowserEnv } from '../services/supabase/supabaseDataService';
import type { Invitation, Restaurant, StaffRole, StaffSession } from '../types';

vi.stubGlobal('BroadcastChannel', undefined);
const { MockDataService } = await import('../services/mock/mockDataService');

const R = (id: string, name: string): Restaurant => ({
  id, slug: id, name, tagline: '', address: '', phone: '', active: true, tables: 4, pickupEnabled: true,
  onlinePaymentEnabled: false, counterPaymentEnabled: true, prepMinutes: 15, createdAt: '2026-01-01', suspended: false,
});
const A = R('A', 'La Piazza'), B = R('B', 'Otro Sitio'), C = R('C', 'Tercer Sitio');
const staff = (...m: [string, StaffRole][]): StaffSession => ({
  userId: 'u', email: 'u@x.test', isPlatformAdmin: false, memberships: m.map(([restaurantId, role]) => ({ restaurantId, role })),
});
const platform: StaffSession = { userId: 'p', email: 'p@x.test', isPlatformAdmin: true, memberships: [] };
const inv = (o: Partial<Invitation> = {}): Invitation => ({
  id: 'i1', email: 'persona@x.test', role: 'waiter', state: 'pendiente', createdAt: '2026-11-02T10:00:00Z',
  expiresAt: '2026-11-09T10:00:00Z', invitedByLabel: 'owner@x.test', decidedAt: null, resendCount: 0, canManage: true, ...o,
});

// ---------- Roles: quién puede invitar a qué ----------
describe('invitaciones: funciones que ofrece la interfaz a cada rol', () => {
  it('plataforma: todas (solo ella invita propietarios); owner: encargado, sala, cocina; manager: sala y cocina', () => {
    expect(invitableRoles(platform, 'A')).toEqual(['owner', 'manager', 'waiter', 'kitchen']);
    expect(invitableRoles(staff(['A', 'owner']), 'A')).toEqual(['manager', 'waiter', 'kitchen']);
    expect(invitableRoles(staff(['A', 'manager']), 'A')).toEqual(['waiter', 'kitchen']);
  });
  it('sala, cocina, sin rol u otro restaurante: ninguna', () => {
    expect(invitableRoles(staff(['A', 'waiter']), 'A')).toEqual([]);
    expect(invitableRoles(staff(['A', 'kitchen']), 'A')).toEqual([]);
    expect(invitableRoles(staff(), 'A')).toEqual([]);
    expect(invitableRoles(staff(['B', 'owner']), 'A')).toEqual([]);
    expect(invitableRoles(null, 'A')).toEqual([]);
  });
  it('la pestaña Equipo (y con ella las invitaciones) solo la ven quienes gestionan personal', () => {
    for (const [role, ok] of [['owner', true], ['manager', true], ['waiter', false], ['kitchen', false]] as const)
      expect(can(staff(['A', role]), 'A', 'staff.manage')).toBe(ok);
    expect(can(platform, 'A', 'staff.manage')).toBe(true);
    expect(canOpenAdmin(staff(['A', 'kitchen']), 'A')).toBe(false);
  });
});

// ---------- Estados, reenvíos y textos ----------
describe('invitaciones: estados y reenvíos (mismos límites que SQL)', () => {
  const now = Date.parse('2026-11-02T10:10:00Z');
  it('nombra todos los estados', () => {
    for (const s of ['pendiente', 'aceptada', 'rechazada', 'revocada', 'reemplazada', 'caducada'] as const) expect(invitationStateLabel[s]).toBeTruthy();
  });
  it('reenviar: solo pendiente, gestionable, con menos de 3 reenvíos y pasados 5 minutos', () => {
    expect(resendStatus(inv(), now)).toEqual({ allowed: true });
    expect(resendStatus(inv({ canManage: false }), now).allowed).toBe(false);
    expect(resendStatus(inv({ state: 'caducada' }), now)).toEqual({ allowed: false, reason: 'Ha caducado: crea una invitación nueva.' });
    for (const s of ['aceptada', 'rechazada', 'revocada', 'reemplazada'] as const) expect(resendStatus(inv({ state: s }), now).allowed).toBe(false);
    const limite = resendStatus(inv({ resendCount: MAX_RESENDS }), now);
    expect(limite.allowed).toBe(false);
    expect(!limite.allowed && limite.reason).toMatch(/3 veces/);
    const pronto = resendStatus(inv({ createdAt: new Date(now - RESEND_WAIT_MS + 60_000).toISOString() }), now);
    expect(pronto.allowed).toBe(false);
    expect(!pronto.allowed && pronto.reason).toMatch(/Podrás reenviarla a partir de las/);
    expect(resendStatus(inv({ createdAt: new Date(now - RESEND_WAIT_MS).toISOString() }), now).allowed).toBe(true);
  });
  it('lista: oculta las sustituidas por un reenvío y pone primero las pendientes', () => {
    const list = visibleInvitations([
      inv({ id: 'acept', state: 'aceptada', createdAt: '2026-11-01T00:00:00Z' }),
      inv({ id: 'vieja', state: 'reemplazada' }),
      inv({ id: 'pend', state: 'pendiente', createdAt: '2026-10-30T00:00:00Z' }),
      inv({ id: 'cad', state: 'caducada' }),
    ]);
    expect(list.map((i) => i.id)).toEqual(['pend', 'cad', 'acept']);
  });
  it('los textos para quien invita no dicen nada del correo ni de si la persona tiene cuenta', () => {
    // Lo que se muestra de CADA invitación (estado y detalle) no depende de la cuenta ni del envío.
    const textos = [...Object.values(invitationStateLabel),
      ...(['pendiente', 'aceptada', 'rechazada', 'revocada', 'caducada'] as const).map((s) => invitationDetail(inv({ state: s, decidedAt: '2026-11-03T10:00:00Z', resendCount: 1 })))];
    for (const t of textos) expect(t).not.toMatch(/ya tiene cuenta|no tiene cuenta|tenía cuenta|correo enviado|no se pudo enviar|entregad/i);
    // La ayuda general explica los dos casos en condicional, igual para todos, y aclara que no se dirá cuál es.
    expect(INVITE_HINT).toMatch(/Si la persona ya tiene cuenta.*; si no, /);
    expect(INVITE_HINT).toMatch(/No te diremos cuál de los dos casos es/);
  });
  it('las entregas (solo plataforma) sí se describen y el registro nombra cada acción', () => {
    expect(deliveryResultLabel.no_necesario).toMatch(/ya tenía cuenta/);
    for (const a of ['invitacion.creada', 'invitacion.reenviada', 'invitacion.aceptada', 'invitacion.rechazada', 'invitacion.revocada', 'invitacion.entrega'])
      expect(auditActionLabel[a]).toBeTruthy();
  });
});

// ---------- Varios restaurantes: selección y permisos separados ----------
describe('varios restaurantes con la misma cuenta', () => {
  const opts = (view: 'panel' | 'admin' | 'inicio', requiresLogin = true) =>
    ({ staffView: view !== 'inicio', requiresLogin, adminView: view === 'admin' });
  const doble = staff(['A', 'waiter'], ['B', 'owner']);
  it('en las vistas del personal solo aparecen los restaurantes donde tiene función', () => {
    expect(selectableRestaurants([A, B, C], doble, opts('panel')).map((r) => r.id)).toEqual(['A', 'B']);
    expect(selectableRestaurants([A, B, C], staff(), opts('panel'))).toEqual([]);
  });
  it('la plataforma ve todos solo en Administración (sin acceso operativo)', () => {
    expect(selectableRestaurants([A, B, C], platform, opts('admin')).length).toBe(3);
    expect(selectableRestaurants([A, B, C], platform, opts('panel'))).toEqual([]);
  });
  it('fuera de las vistas del personal, o en la demo, se ven todos', () => {
    expect(selectableRestaurants([A, B, C], null, opts('inicio')).length).toBe(3);
    expect(selectableRestaurants([A, B, C], null, opts('panel', false)).length).toBe(3);
  });
  it('restaurante activo: el elegido si sigue disponible; si no (p. ej. tras salir de él), el primero', () => {
    const sel = selectableRestaurants([A, B, C], doble, opts('panel'));
    expect(resolveSelected(sel, 'B')?.id).toBe('B');
    expect(resolveSelected(sel, 'C')?.id).toBe('A');
    expect(resolveSelected(sel, null)?.id).toBe('A');
    expect(resolveSelected([], 'A')).toBeUndefined();
  });
  it('el selector muestra la función en cada restaurante', () => {
    expect(restaurantOptionLabel(A, doble)).toBe('La Piazza · Sala');
    expect(restaurantOptionLabel(B, doble)).toBe('Otro Sitio · Propietario');
    expect(restaurantOptionLabel(C, doble)).toBe('Tercer Sitio');
  });
  it('los permisos son los de cada restaurante: owner en B no da nada en A', () => {
    expect(can(doble, 'B', 'staff.manage')).toBe(true);
    expect(can(doble, 'A', 'staff.manage')).toBe(false);
    expect(can(doble, 'A', 'orders.view')).toBe(true);
    expect(can(doble, 'C', 'orders.view')).toBe(false);
    expect(invitableRoles(doble, 'A')).toEqual([]);
    expect(invitableRoles(doble, 'B')).toEqual(['manager', 'waiter', 'kitchen']);
  });
});

// ---------- Enlace del correo de invitación ----------
describe('enlace de invitación (cuenta nueva)', () => {
  it('reconoce type=invite (con sesión) y no lo confunde con otros enlaces', () => {
    expect(parseAuthRedirect('#access_token=a&refresh_token=b&type=invite')).toEqual({ kind: 'invite' });
    expect(parseAuthRedirect('#type=invite')).toEqual({ kind: 'none' });
    expect(parseAuthRedirect('#access_token=a&type=recovery')).toEqual({ kind: 'recovery' });
  });
  it('un enlace caducado explica que se puede pedir otra invitación', () => {
    const r = parseAuthRedirect('#error=access_denied&error_code=otp_expired');
    expect(r.kind === 'error' && r.message).toMatch(/reenvíen/);
  });
  it('hasta elegir la contraseña, todo queda bloqueado (también las invitaciones)', () => {
    expect(staffGate({ isStaffView: true, requiresLogin: true, sessionLoading: false, hasSession: true, recoveryPending: true })).toBe('set-password');
    expect(staffGate({ isStaffView: false, requiresLogin: true, sessionLoading: false, hasSession: true, recoveryPending: true })).toBe('set-password');
  });
});

// ---------- Servicio de Supabase (cliente simulado) ----------
type Invoke = { name: string; body: unknown };
function fake(opts: { invoke?: (name: string, body: unknown) => { data: unknown; error: unknown }; rpc?: Record<string, { data?: unknown; error?: { message: string } }>; hash?: string } = {}) {
  const invokes: Invoke[] = [];
  const rpcs: { fn: string; args: unknown }[] = [];
  const listeners: ((e: string, s: unknown) => void)[] = [];
  const client = {
    auth: {
      onAuthStateChange(cb: (e: string, s: unknown) => void) { listeners.push(cb); return { data: { subscription: { unsubscribe() {} } } }; },
      async updateUser() { return { data: { user: {} }, error: null }; },
    },
    functions: {
      async invoke(name: string, o: { body: unknown }) {
        invokes.push({ name, body: o.body });
        return opts.invoke ? opts.invoke(name, o.body) : { data: { ok: true, invitationId: 'inv-1', message: 'Mensaje del servidor' }, error: null };
      },
    },
    async rpc(fn: string, args: unknown) {
      rpcs.push({ fn, args });
      const r = opts.rpc?.[fn];
      return { data: r?.data ?? null, error: r?.error ?? null };
    },
  } as unknown as SupabaseClient;
  const store = new Map<string, string>();
  const env: BrowserEnv | null = opts.hash !== undefined ? {
    location: { hash: opts.hash, search: '', origin: 'https://app.test', pathname: '/' },
    history: { state: null, replaceState() {} },
    storage: { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => void store.set(k, v), removeItem: (k) => void store.delete(k) },
  } : null;
  const svc = new SupabaseDataService('https://x.supabase.co', 'sb_publishable_x', { createClient: async () => client, env });
  return { svc, invokes, rpcs, emit: (e: string, s: unknown) => listeners.forEach((l) => l(e, s)) };
}
const httpError = (status: number, body: unknown) => ({
  data: null, error: { name: 'FunctionsHttpError', message: 'Edge Function returned a non-2xx status code', context: new Response(JSON.stringify(body), { status }) },
});

describe('servicio de Supabase: invitaciones', () => {
  it('crear y reenviar pasan por la Edge Function «invitations» (nunca por tablas ni con otra clave)', async () => {
    const t = fake();
    expect(await t.svc.inviteStaff('A', '  persona@x.test ', 'waiter')).toEqual({ invitationId: 'inv-1', message: 'Mensaje del servidor' });
    await t.svc.resendInvitation('inv-1');
    await t.svc.createRestaurantWithOwner({ name: ' Nuevo Sitio ', slug: 'nuevo-sitio', ownerEmail: ' duena@x.test ' });
    expect(t.invokes).toEqual([
      { name: 'invitations', body: { action: 'create', restaurantId: 'A', email: 'persona@x.test', role: 'waiter' } },
      { name: 'invitations', body: { action: 'resend', invitationId: 'inv-1' } },
      { name: 'invitations', body: { action: 'create_restaurant', name: 'Nuevo Sitio', slug: 'nuevo-sitio', ownerEmail: 'duena@x.test' } },
    ]);
    expect(t.rpcs).toEqual([]);
  });
  it('muestra el mensaje de error del servidor (permisos, límites) tal cual', async () => {
    for (const [status, error] of [[403, 'No puedes invitar a esa función en este restaurante'], [429, 'Has alcanzado el límite de 20 invitaciones por hora. Inténtalo más tarde'],
      [429, 'Espera al menos 5 minutos entre reenvíos'], [400, 'Ya hay una invitación pendiente para ese correo. Puedes reenviarla o revocarla']] as const) {
      const t = fake({ invoke: () => httpError(status, { ok: false, error }) });
      await expect(t.svc.inviteStaff('A', 'x@y.test', 'waiter')).rejects.toThrow(error);
    }
  });
  it('sin conexión o con una respuesta inesperada: mensaje general (sin detalles técnicos)', async () => {
    const red = fake({ invoke: () => ({ data: null, error: { name: 'FunctionsFetchError', message: 'Failed to send a request to the Edge Function' } }) });
    await expect(red.svc.resendInvitation('i')).rejects.toThrow('No hay conexión con el servidor');
    const raro = fake({ invoke: () => ({ data: { ok: false }, error: null }) });
    await expect(raro.svc.inviteStaff('A', 'x@y.test', 'waiter')).rejects.toThrow('No se ha podido completar la invitación');
    const html = fake({ invoke: () => ({ data: null, error: { name: 'FunctionsHttpError', message: 'x', context: new Response('<html>', { status: 502 }) } }) });
    await expect(html.svc.inviteStaff('A', 'x@y.test', 'waiter')).rejects.toThrow('No se ha podido completar la invitación');
  });
  it('lista las invitaciones con invitation_list y no arrastra datos de entrega', async () => {
    const t = fake({ rpc: { invitation_list: { data: [{ id: 'i1', email: 'p@x.test', role: 'kitchen', state: 'caducada', created_at: 'c', expires_at: 'e',
      invited_by_label: 'TuRestaurante (plataforma)', decided_at: null, resend_count: 2, can_manage: false, send_status: 'enviada', account_exists: true }] } } });
    const list = await t.svc.listInvitations('A');
    expect(list).toEqual([{ id: 'i1', email: 'p@x.test', role: 'kitchen', state: 'caducada', createdAt: 'c', expiresAt: 'e',
      invitedByLabel: 'TuRestaurante (plataforma)', decidedAt: null, resendCount: 2, canManage: false }]);
    expect(t.rpcs).toEqual([{ fn: 'invitation_list', args: { p_restaurant_id: 'A' } }]);
  });
  it('mis invitaciones, aceptar, rechazar y revocar: funciones SQL con la sesión del usuario', async () => {
    const t = fake({ rpc: {
      my_invitations: { data: [{ id: 'i1', restaurant_id: 'B', restaurant_name: 'Otro Sitio', role: 'waiter', expires_at: 'e', invited_by_label: 'Equipo de Otro Sitio' }] },
      invitation_accept: { data: 'B' },
    } });
    expect(await t.svc.myInvitations()).toEqual([{ id: 'i1', restaurantId: 'B', restaurantName: 'Otro Sitio', role: 'waiter', expiresAt: 'e', invitedByLabel: 'Equipo de Otro Sitio' }]);
    expect(await t.svc.acceptInvitation('i1')).toBe('B');
    await t.svc.declineInvitation('i2');
    await t.svc.revokeInvitation('i3');
    expect(t.rpcs.map((r) => [r.fn, r.args])).toEqual([
      ['my_invitations', undefined], ['invitation_accept', { p_invitation_id: 'i1' }],
      ['invitation_decline', { p_invitation_id: 'i2' }], ['invitation_revoke', { p_invitation_id: 'i3' }],
    ]);
  });
  it('aceptar: la sesión se vuelve a leer SOLO cuando el servidor lo confirma; la función no se elige', async () => {
    const ok = fake({ rpc: { invitation_accept: { data: 'B' } } });
    const avisos: string[] = [];
    ok.svc.onAuthChange(() => avisos.push('sesión'));
    await ok.svc.acceptInvitation('i1');
    expect(avisos).toEqual(['sesión']);
    expect(ok.rpcs[0].args).toEqual({ p_invitation_id: 'i1' }); // sin función ni restaurante
    const ko = fake({ rpc: { invitation_accept: { error: { message: 'Esta invitación ha caducado. Pide una nueva a quien te invitó' } } } });
    const avisos2: string[] = [];
    ko.svc.onAuthChange(() => avisos2.push('sesión'));
    await expect(ko.svc.acceptInvitation('i1')).rejects.toThrow('ha caducado');
    expect(avisos2).toEqual([]);
  });
  it('enlace de invitación: pide la contraseña antes de nada, como cuenta nueva', async () => {
    const t = fake({ hash: '#access_token=a&refresh_token=b&type=invite' });
    expect(t.svc.getAuthRedirect()).toEqual({ kind: 'invite' });
    expect(t.svc.isPasswordRecoveryPending()).toBe(true);
    expect(t.svc.getPasswordSetupKind()).toBe('invite');
    await new Promise((r) => setTimeout(r, 0));
    t.emit('PASSWORD_RECOVERY', {}); // no la convierte en una recuperación
    expect(t.svc.getPasswordSetupKind()).toBe('invite');
    await t.svc.setNewPassword('una-contraseña-larga');
    expect(t.svc.getPasswordSetupKind()).toBeNull();
  });
  it('la recuperación de contraseña sigue igual', () => {
    const t = fake({ hash: '#access_token=a&type=recovery' });
    expect(t.svc.getPasswordSetupKind()).toBe('recovery');
  });
});

describe('modo demo: invitaciones', () => {
  it('no hay cuentas ni correo: las listas están vacías y las acciones lo explican', async () => {
    const svc = new MockDataService();
    expect(await svc.listInvitations()).toEqual([]);
    expect(await svc.myInvitations()).toEqual([]);
    expect(svc.getPasswordSetupKind()).toBeNull();
    await expect(svc.inviteStaff()).rejects.toThrow('Supabase');
    await expect(svc.acceptInvitation()).rejects.toThrow('Supabase');
    await expect(svc.createRestaurantWithOwner()).rejects.toThrow('Supabase');
    const r = await svc.createRestaurant({ name: 'Demo Nuevo', slug: 'demo-nuevo' });
    expect(r.name).toBe('Demo Nuevo');
  });
});

describe('el navegador no puede dar permisos ni contiene secretos', () => {
  const files: string[] = [];
  const walk = (d: string) => readdirSync(d).forEach((f) => {
    const p = join(d, f);
    if (statSync(p).isDirectory()) { if (f !== '__tests__') walk(p); } else files.push(p);
  });
  walk('src');
  it('ningún archivo de la app escribe en restaurant_staff ni usa staff_add_member', () => {
    for (const f of files) expect(readFileSync(f, 'utf8'), f).not.toMatch(/staff_add_member|from\(['"]restaurant_staff['"]\)\s*\.(insert|update|upsert)/);
  });
  it('aceptar una invitación solo envía su identificador (la función la decide el servidor)', () => {
    const src = readFileSync('src/services/supabase/supabaseDataService.ts', 'utf8');
    expect(src).toMatch(/rpcData<string>\('invitation_accept', \{ p_invitation_id: invitationId \}\)/);
  });
  it('sin claves secretas ni la API de administración de Auth en la app', () => {
    for (const f of files) expect(readFileSync(f, 'utf8'), f).not.toMatch(/SUPABASE_SERVICE_ROLE_KEY|sb_secret_[A-Za-z0-9_-]{8,}|auth\.admin|inviteUserByEmail|INVITATIONS_RECOVERY_SECRET/);
  });
});

describe('tiempo real: un canal por suscripción', () => {
  it('dos pantallas que escuchan el catálogo a la vez no comparten canal', async () => {
    const names: string[] = [];
    const channel = (n: string) => { names.push(n); const ch = { on: () => ch, subscribe: () => ch }; return ch; };
    const client = { auth: { onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }) }, channel, removeChannel: async () => {} } as unknown as SupabaseClient;
    const svc = new SupabaseDataService('https://x.supabase.co', 'sb_publishable_x', { createClient: async () => client, env: null });
    const stop1 = svc.subscribeCatalog(() => {});
    const stop2 = svc.subscribeCatalog(() => {});
    await new Promise((r) => setTimeout(r, 0));
    stop1(); stop2();
    expect(names).toHaveLength(2);
    expect(new Set(names).size).toBe(2);
    expect(names.every((n) => n.startsWith('catalog:'))).toBe(true);
  });
});
