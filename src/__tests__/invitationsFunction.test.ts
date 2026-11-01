import { describe, expect, it } from 'vitest';
import {
  createInvitationsHandler, INVITATION_MESSAGE, MAX_BODY_BYTES, parseAction, parseAppUrl, parseOrigins, sqlErrorResponse,
  type AdminApi, type AuthError, type DeliveryRow, type InvitationsDeps, type RpcResult, type SendResult, type UserRpc,
} from '../../supabase/functions/invitations/handler';

// ---------- Clientes simulados ----------
const APP = 'https://app.turestaurante.test/';
const ORIGIN = 'https://app.turestaurante.test';
const JWT = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1In0.firma-de-prueba';
const RID = '5e5e0000-0000-4000-8000-000000000001';
const INV = '11111111-1111-4111-8111-111111111111';
const INV2 = '22222222-2222-4222-8222-222222222222';

type Account = 'nueva' | 'sin_confirmar' | 'confirmada';
const row = (account: Account, over: Partial<DeliveryRow> = {}): DeliveryRow => ({
  email: 'persona@ejemplo.test', role: 'waiter', restaurant_name: 'La Piazza', expires_at: '2026-11-09T10:00:00Z',
  account_exists: account !== 'nueva', account_confirmed: account === 'confirmada', state: 'pendiente', ...over,
});

interface Setup {
  user?: { id: string; isAnonymous: boolean } | null | 'throw';
  rpc?: Partial<Record<UserRpc, RpcResult<unknown>>>;
  delivery?: RpcResult<DeliveryRow[]> | 'throw';
  invite?: (AuthError | null | 'throw')[];
  markSent?: RpcResult<unknown> | 'throw';
  minResponseMs?: number;
}

function setup(s: Setup = {}) {
  const calls: { who: 'user' | 'admin'; fn: string; args: unknown }[] = [];
  const logs: { event: string; data: Record<string, unknown> }[] = [];
  const sleeps: number[] = [];
  let clock = 1000;
  const jwts: string[] = [];
  const invites = [...(s.invite ?? [null])];
  const admin: AdminApi = {
    async delivery(id) {
      calls.push({ who: 'admin', fn: 'invitation_delivery', args: id });
      if (s.delivery === 'throw') throw new Error('red');
      return s.delivery ?? { data: [row('nueva')], error: null };
    },
    async markSent(id, result: SendResult) {
      calls.push({ who: 'admin', fn: 'invitation_mark_sent', args: { id, result } });
      if (s.markSent === 'throw') throw new Error('red');
      return s.markSent ?? { data: null, error: null };
    },
    async inviteUserByEmail(email, redirectTo) {
      calls.push({ who: 'admin', fn: 'inviteUserByEmail', args: { email, redirectTo } });
      const next = invites.length > 1 ? invites.shift()! : invites[0];
      if (next === 'throw') throw new Error('red');
      return { error: next };
    },
  };
  // Un objeto congelado: si el código intentara usar otra operación con la clave secreta, fallaría.
  Object.freeze(admin);
  const deps: InvitationsDeps = {
    config: { appUrl: APP, allowedOrigins: [ORIGIN], minResponseMs: s.minResponseMs ?? 1500, retryDelayMs: 800 },
    admin,
    forUser(jwt) {
      jwts.push(jwt);
      return {
        async getUser() {
          if (s.user === 'throw') throw new Error('red');
          return s.user === undefined ? { id: 'u1', isAnonymous: false } : s.user;
        },
        async rpc(fn, args) {
          calls.push({ who: 'user', fn, args });
          clock += 40; // la consulta SQL tarda
          const def: Record<UserRpc, RpcResult<unknown>> = {
            invitation_create: { data: INV, error: null },
            invitation_resend: { data: INV2, error: null },
            platform_create_restaurant: { data: { restaurantId: RID, invitationId: INV }, error: null },
          };
          return (s.rpc?.[fn] ?? def[fn]) as never;
        },
      };
    },
    now: () => clock,
    sleep: async (ms) => { sleeps.push(ms); clock += ms; },
    log: (event, data) => logs.push({ event, data }),
  };
  const handle = createInvitationsHandler(deps);
  const post = (body: unknown, headers: Record<string, string> = {}) =>
    handle(new Request('https://fn.test/invitations', {
      method: 'POST',
      headers: { origin: ORIGIN, authorization: `Bearer ${JWT}`, 'content-type': 'application/json', ...headers },
      body: typeof body === 'string' ? body : JSON.stringify(body),
    }));
  const adminCalls = () => calls.filter((c) => c.who === 'admin');
  const sent = () => calls.find((c) => c.fn === 'invitation_mark_sent')?.args as { result: SendResult } | undefined;
  return { handle, post, calls, adminCalls, logs, sleeps, jwts, sent, elapsed: () => clock - 1000 };
}

const create = { action: 'create', restaurantId: RID, email: 'persona@ejemplo.test', role: 'waiter' };

// ---------- Configuración ----------
describe('invitations: configuración', () => {
  it('APP_URL debe ser https fija (http solo en localhost), sin «?» ni «#»', () => {
    expect(parseAppUrl('https://app.ejemplo.com')).toBe('https://app.ejemplo.com/');
    expect(parseAppUrl('https://app.ejemplo.com/panel/')).toBe('https://app.ejemplo.com/panel/');
    expect(parseAppUrl('http://localhost:5173/')).toBe('http://localhost:5173/');
    expect(parseAppUrl('http://127.0.0.1:5173')).toBe('http://127.0.0.1:5173/');
    for (const bad of ['', undefined, null, 'app.ejemplo.com', 'http://app.ejemplo.com', 'javascript:alert(1)',
      'https://app.ejemplo.com/#/invitacion', 'https://app.ejemplo.com/?next=x', 'https://user:pw@app.ejemplo.com/', 'ftp://x.com'])
      expect(parseAppUrl(bad)).toBeNull();
  });
  it('orígenes admitidos: los configurados o el de APP_URL', () => {
    expect(parseOrigins(undefined, APP)).toEqual([ORIGIN]);
    expect(parseOrigins(' https://a.test , https://b.test/ ,no-es-url', APP)).toEqual(['https://a.test', 'https://b.test']);
  });
});

// ---------- Entrada ----------
describe('invitations: peticiones rechazadas antes de tocar la base de datos', () => {
  it('preflight CORS solo para orígenes admitidos', async () => {
    const t = setup();
    const ok = await t.handle(new Request('https://fn.test', { method: 'OPTIONS', headers: { origin: ORIGIN } }));
    expect(ok.status).toBe(204);
    expect(ok.headers.get('access-control-allow-origin')).toBe(ORIGIN);
    const no = await t.handle(new Request('https://fn.test', { method: 'OPTIONS', headers: { origin: 'https://malo.test' } }));
    expect(no.status).toBe(403);
    expect(no.headers.get('access-control-allow-origin')).toBeNull();
  });
  it('origen no admitido, otro método, sin sesión, cuerpo inválido o enorme: nada llega a SQL ni a Auth', async () => {
    const t = setup();
    expect((await t.post(create, { origin: 'https://malo.test' })).status).toBe(403);
    expect((await t.handle(new Request('https://fn.test', { method: 'GET', headers: { origin: ORIGIN } }))).status).toBe(405);
    expect((await t.post(create, { authorization: '' })).status).toBe(401);
    expect((await t.post(create, { authorization: 'Basic abc' })).status).toBe(401);
    expect((await t.post('{no es json')).status).toBe(400);
    expect((await t.post({ ...create, pad: 'x'.repeat(MAX_BODY_BYTES) })).status).toBe(400);
    expect((await t.post({ ...create, action: 'borrar' })).status).toBe(400);
    expect((await t.post({ ...create, role: 'admin' })).status).toBe(400);
    expect((await t.post({ ...create, restaurantId: 'x' })).status).toBe(400);
    expect((await t.post({ ...create, email: 'sin-arroba' })).status).toBe(400);
    expect((await t.post({ action: 'resend', invitationId: '1 or 1=1' })).status).toBe(400);
    expect(t.calls).toEqual([]);
    expect(t.jwts).toEqual([]);
  });
  it('JWT no válido o de sesión anónima: 401/403 sin consultas', async () => {
    for (const [user, status] of [[null, 401], ['throw', 401], [{ id: 'a', isAnonymous: true }, 403]] as const) {
      const t = setup({ user });
      expect((await t.post(create)).status).toBe(status);
      expect(t.calls).toEqual([]);
    }
  });
  it('lee solo los campos de cada acción', () => {
    expect(parseAction({ ...create, redirectTo: 'https://malo.test', p_role: 'owner', extra: 1 }))
      .toEqual({ action: 'create', restaurantId: RID, email: 'persona@ejemplo.test', role: 'waiter' });
  });
});

// ---------- Permisos en SQL con el JWT de quien llama ----------
describe('invitations: los permisos los decide SQL con el JWT de quien invita', () => {
  it('usa el JWT recibido para el cliente de usuario y llama a la función SQL con los datos', async () => {
    const t = setup();
    await t.post(create);
    expect(t.jwts).toEqual([JWT]);
    expect(t.calls[0]).toEqual({ who: 'user', fn: 'invitation_create', args: { p_restaurant_id: RID, p_email: 'persona@ejemplo.test', p_role: 'waiter' } });
  });
  it('si SQL lo deniega, no se usa la clave secreta para nada', async () => {
    const t = setup({ rpc: { invitation_create: { data: null, error: { code: '42501', message: 'No puedes invitar a esa función en este restaurante' } } } });
    const r = await t.post({ ...create, role: 'owner' });
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ ok: false, error: 'No puedes invitar a esa función en este restaurante' });
    expect(t.adminCalls()).toEqual([]);
  });
  it('la clave secreta solo se usa DESPUÉS de que SQL acepte, y solo para la entrega', async () => {
    const t = setup();
    await t.post(create);
    expect(t.calls.map((c) => `${c.who}:${c.fn}`)).toEqual(['user:invitation_create', 'admin:invitation_delivery', 'admin:inviteUserByEmail', 'admin:invitation_mark_sent']);
  });
  it('traduce los errores de SQL sin filtrar detalles internos', () => {
    expect(sqlErrorResponse({ code: '54000', message: 'Has alcanzado el límite de 20 invitaciones por hora. Inténtalo más tarde' }))
      .toEqual({ status: 429, error: 'Has alcanzado el límite de 20 invitaciones por hora. Inténtalo más tarde' });
    expect(sqlErrorResponse({ code: '22023', message: 'Ya hay una invitación pendiente para ese correo. Puedes reenviarla o revocarla' }).status).toBe(400);
    expect(sqlErrorResponse({ code: '23505', message: 'duplicate key value violates unique constraint "restaurants_slug_key"' }))
      .toEqual({ status: 409, error: 'Ya existe un restaurante con esa dirección web' });
    expect(sqlErrorResponse({ code: '23514', message: 'new row violates check constraint "restaurants_name_check"' }).status).toBe(400);
    const otro = sqlErrorResponse({ code: 'XX000', message: 'detalle interno de la base de datos' });
    expect(otro.status).toBe(500);
    expect(otro.error).not.toMatch(/interno|base de datos/);
  });
  it('límites de SQL (20/hora, 30 pendientes): 429 y sin envío', async () => {
    const t = setup({ rpc: { invitation_create: { data: null, error: { code: '54000', message: 'El restaurante ya tiene 30 invitaciones pendientes. Revoca alguna antes de crear otra' } } } });
    const r = await t.post(create);
    expect(r.status).toBe(429);
    expect(t.adminCalls()).toEqual([]);
  });
});

// ---------- Cuentas nuevas, sin confirmar y existentes ----------
describe('invitations: entrega según la cuenta', () => {
  it('cuenta nueva: Supabase la crea y envía la invitación con APP_URL', async () => {
    const t = setup({ delivery: { data: [row('nueva')], error: null } });
    expect((await t.post(create)).status).toBe(200);
    expect(t.calls.find((c) => c.fn === 'inviteUserByEmail')?.args).toEqual({ email: 'persona@ejemplo.test', redirectTo: APP });
    expect(t.sent()?.result).toBe('enviada');
  });
  it('cuenta invitada sin confirmar: se le reenvía el enlace (Supabase no crea otra cuenta)', async () => {
    const t = setup({ delivery: { data: [row('sin_confirmar')], error: null } });
    await t.post(create);
    expect(t.calls.filter((c) => c.fn === 'inviteUserByEmail')).toHaveLength(1);
    expect(t.sent()?.result).toBe('enviada');
  });
  it('cuenta confirmada: no se envía correo (la verá en la app) y no se toca su cuenta', async () => {
    const t = setup({ delivery: { data: [row('confirmada')], error: null } });
    await t.post(create);
    expect(t.calls.some((c) => c.fn === 'inviteUserByEmail')).toBe(false);
    expect(t.sent()?.result).toBe('no_necesario');
  });
  it('confirmó entre la consulta y el envío (email_exists): no se envía y queda «no_necesario»', async () => {
    const t = setup({ delivery: { data: [row('sin_confirmar')], error: null }, invite: [{ status: 422, code: 'email_exists' }] });
    await t.post(create);
    expect(t.calls.filter((c) => c.fn === 'inviteUserByEmail')).toHaveLength(1);
    expect(t.sent()?.result).toBe('no_necesario');
  });
  it('el correo de destino es el que guarda SQL (normalizado), no el que envía el navegador', async () => {
    const t = setup({ delivery: { data: [row('nueva', { email: 'persona@ejemplo.test' })], error: null } });
    await t.post({ ...create, email: '  PERSONA@Ejemplo.TEST ' });
    expect((t.calls.find((c) => c.fn === 'inviteUserByEmail')?.args as { email: string }).email).toBe('persona@ejemplo.test');
  });
  it('nunca usa una dirección de vuelta enviada por el navegador', async () => {
    const t = setup();
    await t.post({ ...create, redirectTo: 'https://malo.test/robar', redirect_to: 'https://malo.test', emailRedirectTo: 'https://malo.test' });
    const invite = t.calls.find((c) => c.fn === 'inviteUserByEmail')?.args as { redirectTo: string };
    expect(invite.redirectTo).toBe(APP);
    expect(JSON.stringify(t.calls)).not.toContain('malo.test');
  });
  it('invitación que ya no está pendiente: no se envía nada', async () => {
    const t = setup({ delivery: { data: [row('nueva', { state: 'revocada' })], error: null } });
    expect((await t.post(create)).status).toBe(200);
    expect(t.adminCalls().map((c) => c.fn)).toEqual(['invitation_delivery']);
  });
});

// ---------- Fallos de envío y reintentos ----------
describe('invitations: fallos de envío', () => {
  it('límite de correos de Supabase (429): no reintenta y queda «fallida»', async () => {
    const t = setup({ invite: [{ status: 429, code: 'over_email_send_rate_limit' }] });
    expect((await t.post(create)).status).toBe(200);
    expect(t.calls.filter((c) => c.fn === 'inviteUserByEmail')).toHaveLength(1);
    expect(t.sent()?.result).toBe('fallida');
  });
  it('correo no autorizado por el SMTP de pruebas (400): no reintenta', async () => {
    const t = setup({ invite: [{ status: 400, code: 'email_address_not_authorized' }] });
    await t.post(create);
    expect(t.calls.filter((c) => c.fn === 'inviteUserByEmail')).toHaveLength(1);
    expect(t.sent()?.result).toBe('fallida');
  });
  it('fallo temporal (5xx o red): un reintento tras una espera', async () => {
    const t = setup({ invite: [{ status: 500, code: 'unexpected_failure' }, null] });
    await t.post(create);
    expect(t.calls.filter((c) => c.fn === 'inviteUserByEmail')).toHaveLength(2);
    expect(t.sleeps[0]).toBe(800);
    expect(t.sent()?.result).toBe('enviada');
    const t2 = setup({ invite: ['throw', 'throw'] });
    await t2.post(create);
    expect(t2.calls.filter((c) => c.fn === 'inviteUserByEmail')).toHaveLength(2);
    expect(t2.sent()?.result).toBe('fallida');
  });
  it('si no hay datos de entrega o falla la anotación, la invitación sigue creada y la respuesta no cambia', async () => {
    for (const s of [{ delivery: { data: null, error: { code: 'XX000' } } }, { delivery: 'throw' as const }, { markSent: 'throw' as const },
      { markSent: { data: null, error: { code: '22023' } } }]) {
      const t = setup(s);
      const r = await t.post(create);
      expect(r.status).toBe(200);
      expect(await r.json()).toEqual({ ok: true, invitationId: INV, message: INVITATION_MESSAGE });
    }
  });
});

// ---------- No revelar nada a quien invita ----------
describe('invitations: quien invita no sabe si el correo tiene cuenta', () => {
  const cases: [string, Setup][] = [
    ['sin cuenta, enviada', { delivery: { data: [row('nueva')], error: null } }],
    ['sin confirmar, enviada', { delivery: { data: [row('sin_confirmar')], error: null } }],
    ['confirmada (otro restaurante o plataforma), sin correo', { delivery: { data: [row('confirmada')], error: null } }],
    ['envío fallido', { invite: [{ status: 429, code: 'over_email_send_rate_limit' }] }],
    ['envío fallido tras reintento', { invite: [{ status: 503 }, { status: 503 }] }],
    ['sin datos de entrega', { delivery: { data: null, error: { code: 'XX000' } } }],
  ];
  it('misma respuesta (estado, cuerpo y cabeceras) en todos los casos', async () => {
    const seen = new Set<string>();
    for (const [, s] of cases) {
      const r = await setup(s).post(create);
      seen.add(JSON.stringify([r.status, await r.json(), [...r.headers.entries()].sort()]));
    }
    expect(seen.size).toBe(1);
  });
  it('mismo tiempo de respuesta mínimo, haya o no envío (y reintento)', async () => {
    const times = new Set<number>();
    for (const [, s] of cases) {
      const t = setup(s);
      await t.post(create);
      times.add(t.elapsed());
    }
    expect([...times]).toEqual([1500]);
  });
  it('los registros no contienen correos ni el JWT', async () => {
    for (const [, s] of cases) {
      const t = setup(s);
      await t.post({ ...create, email: 'secreto@ejemplo.test' });
      const text = JSON.stringify(t.logs);
      expect(text).not.toContain('@');
      expect(text).not.toContain(JWT);
    }
  });
});

// ---------- Crear restaurante y reenviar ----------
describe('invitations: restaurante nuevo y reenvío', () => {
  it('crear restaurante: SQL de la plataforma y entrega de la invitación del propietario', async () => {
    const t = setup();
    const r = await t.post({ action: 'create_restaurant', name: 'Tercer Sitio', slug: 'tercer-sitio', ownerEmail: 'dueno@ejemplo.test' });
    expect(await r.json()).toEqual({ ok: true, invitationId: INV, restaurantId: RID, message: INVITATION_MESSAGE });
    expect(t.calls[0]).toEqual({ who: 'user', fn: 'platform_create_restaurant', args: { p_name: 'Tercer Sitio', p_slug: 'tercer-sitio', p_owner_email: 'dueno@ejemplo.test' } });
    expect(t.calls[1]).toEqual({ who: 'admin', fn: 'invitation_delivery', args: INV });
  });
  it('crear restaurante sin ser plataforma o con dirección repetida: error y sin envío', async () => {
    for (const [error, status] of [[{ code: '42501', message: 'Solo la plataforma puede crear restaurantes' }, 403], [{ code: '23505', message: 'dup' }, 409]] as const) {
      const t = setup({ rpc: { platform_create_restaurant: { data: null, error } } });
      expect((await t.post({ action: 'create_restaurant', name: 'X Sitio', slug: 'x-sitio', ownerEmail: 'd@e.test' })).status).toBe(status);
      expect(t.adminCalls()).toEqual([]);
    }
  });
  it('reenviar: SQL crea la nueva y se entrega LA NUEVA (a una cuenta sin confirmar se le reenvía el enlace)', async () => {
    const t = setup({ delivery: { data: [row('sin_confirmar')], error: null } });
    const r = await t.post({ action: 'resend', invitationId: INV });
    expect(await r.json()).toEqual({ ok: true, invitationId: INV2, message: INVITATION_MESSAGE });
    expect(t.calls[0]).toEqual({ who: 'user', fn: 'invitation_resend', args: { p_invitation_id: INV } });
    expect(t.calls[1].args).toBe(INV2);
    expect(t.sent()?.result).toBe('enviada');
  });
  it('reenviar antes de 5 minutos o más de 3 veces: 429 de SQL y sin envío', async () => {
    const t = setup({ rpc: { invitation_resend: { data: null, error: { code: '54000', message: 'Espera al menos 5 minutos entre reenvíos' } } } });
    const r = await t.post({ action: 'resend', invitationId: INV });
    expect(r.status).toBe(429);
    expect(await r.json()).toEqual({ ok: false, error: 'Espera al menos 5 minutos entre reenvíos' });
    expect(t.adminCalls()).toEqual([]);
  });
});

// ---------- El código del navegador no contiene la clave secreta ----------
describe('invitations: la clave secreta no está en el navegador', () => {
  it('ningún archivo de src/ menciona la clave secreta ni la API de administración de Auth', async () => {
    const { readdirSync, readFileSync, statSync } = await import('node:fs');
    const { join } = await import('node:path');
    const files: string[] = [];
    const walk = (d: string) => readdirSync(d).forEach((f) => {
      const p = join(d, f);
      if (statSync(p).isDirectory()) { if (f !== '__tests__') walk(p); } else files.push(p);
    });
    walk('src');
    for (const f of files) {
      const text = readFileSync(f, 'utf8');
      expect(text, f).not.toMatch(/SUPABASE_SERVICE_ROLE_KEY|sb_secret_[A-Za-z0-9_-]{8,}|auth\.admin|inviteUserByEmail|invitation_delivery|invitation_mark_sent/);
    }
  });
});
