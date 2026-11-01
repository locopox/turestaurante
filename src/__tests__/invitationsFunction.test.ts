import { describe, expect, it } from 'vitest';
import {
  classifyInviteError, createInvitationsHandler, createRecoveryHandler, RECOVERY_HEADER, sameSecret, INVITATION_MESSAGE, MAX_BODY_BYTES, parseAction, parseAppUrl, parseOrigins,
  sqlErrorResponse, type AdminApi, type AuthError, type ClaimRow, type FinishResult, type InvitationsDeps, type RpcResult, type UserRpc,
} from '../../supabase/functions/_shared/invitations';

// ---------- Cola de entregas simulada (mismas reglas que las funciones SQL invitation_delivery_*) ----------
const MIN = 60_000;
type Account = 'nueva' | 'sin_confirmar' | 'confirmada';
interface QRow {
  status: 'pendiente' | 'revocada'; email: string; account: Account; createdAt: number; expiresAt: number;
  send: 'sin_enviar' | 'enviando' | 'enviada' | 'fallida' | 'no_necesario'; attempts: number;
  claim: string | null; claimedAt: number | null; nextAt: number | null;
}
class FakeQueue {
  now = 1_000 * MIN;
  rows = new Map<string, QRow>();
  private seq = 0;
  add(id: string, account: Account = 'nueva', over: Partial<QRow> = {}) {
    this.rows.set(id, { status: 'pendiente', email: `${id}@ejemplo.test`, account, createdAt: this.now, expiresAt: this.now + 7 * 24 * 60 * MIN,
      send: 'sin_enviar', attempts: 0, claim: null, claimedAt: null, nextAt: null, ...over });
  }
  claim(id: string): ClaimRow[] {
    const r = this.rows.get(id);
    if (!r || r.status !== 'pendiente' || r.expiresAt <= this.now || r.attempts >= 3) return [];
    const free = r.send === 'sin_enviar' && (r.nextAt === null || r.nextAt <= this.now);
    const stale = r.send === 'enviando' && r.claimedAt! <= this.now - 10 * MIN;
    if (!free && !stale) return [];
    Object.assign(r, { send: 'enviando', claim: `claim-${++this.seq}`, claimedAt: this.now, attempts: r.attempts + 1 });
    return [{ claim: r.claim!, attempt: r.attempts, email: r.email, role: 'waiter', restaurant_name: 'La Piazza',
      account_exists: r.account !== 'nueva', account_confirmed: r.account === 'confirmada' }];
  }
  finish(id: string, claim: string, result: FinishResult): boolean {
    const r = this.rows.get(id);
    if (!r || r.send !== 'enviando' || r.claim !== claim) return false;
    if (result !== 'reintentar') r.send = result;
    else if (r.attempts >= 3 || r.status !== 'pendiente') r.send = 'fallida';
    else { r.send = 'sin_enviar'; r.nextAt = this.now + (r.attempts === 1 ? 5 : 30) * MIN; }
    r.claim = null; r.claimedAt = null;
    return true;
  }
  pending(limit: number): string[] {
    for (const r of this.rows.values())
      if (r.send === 'enviando' && r.claimedAt! <= this.now - 10 * MIN && (r.attempts >= 3 || r.status !== 'pendiente' || r.expiresAt <= this.now))
        Object.assign(r, { send: 'fallida', claim: null, claimedAt: null });
    return [...this.rows.entries()]
      .filter(([, r]) => r.status === 'pendiente' && r.expiresAt > this.now && r.attempts < 3
        && ((r.send === 'sin_enviar' && (r.nextAt ?? r.createdAt + 2 * MIN) <= this.now) || (r.send === 'enviando' && r.claimedAt! <= this.now - 10 * MIN)))
      .sort(([, a], [, b]) => Number(b.send === 'enviando') - Number(a.send === 'enviando') || (a.nextAt ?? a.createdAt) - (b.nextAt ?? b.createdAt))
      .slice(0, Math.max(1, Math.min(limit, 10))).map(([id]) => id);
  }
  state(id: string) { const r = this.rows.get(id)!; return `${r.send}/${r.attempts}`; }
}

// ---------- Función con clientes simulados ----------
const APP = 'https://app.turestaurante.test/';
const ORIGIN = 'https://app.turestaurante.test';
const JWT = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1In0.firma-de-prueba';
const RID = '5e5e0000-0000-4000-8000-000000000001';
const INV = '11111111-1111-4111-8111-111111111111';
const INV2 = '22222222-2222-4222-8222-222222222222';
type InviteReply = AuthError | null | 'throw' | 'never';

interface Setup {
  user?: { id: string; isAnonymous: boolean } | null | 'throw';
  rpc?: Partial<Record<UserRpc, RpcResult<unknown>>>;
  /** Cuenta del correo de la invitación que crea SQL (INV o INV2). */
  account?: Account;
  invite?: InviteReply[];
  fail?: Partial<Record<'claim' | 'finish' | 'pending', 'throw' | 'error'>>;
  queue?: FakeQueue;
  sweepLimit?: number;
  /** La reserva no avanza hasta que se abra esta compuerta (base de datos lenta o bloqueada). */
  claimGate?: Promise<void>;
}

function setup(s: Setup = {}) {
  const q = s.queue ?? new FakeQueue();
  const calls: { who: 'user' | 'admin'; fn: string; args: unknown }[] = [];
  const logs: { event: string; data: Record<string, unknown> }[] = [];
  const jwts: string[] = [];
  const tasks: Promise<void>[] = [];
  const invites = [...(s.invite ?? [null])];
  const err = (k: 'claim' | 'finish' | 'pending') => {
    if (s.fail?.[k] === 'throw') throw new Error('red');
    return s.fail?.[k] === 'error' ? { code: 'XX000', message: 'fallo' } : null;
  };
  const admin: AdminApi = {
    async claim(id) {
      calls.push({ who: 'admin', fn: 'claim', args: id });
      if (s.claimGate) await s.claimGate;
      const e = err('claim');
      return e ? { data: null, error: e } : { data: q.claim(id), error: null };
    },
    async finish(id, claim, result) {
      calls.push({ who: 'admin', fn: 'finish', args: { id, result } });
      const e = err('finish');
      return e ? { data: null, error: e } : { data: q.finish(id, claim, result), error: null };
    },
    async pending(limit) {
      calls.push({ who: 'admin', fn: 'pending', args: limit });
      const e = err('pending');
      return e ? { data: null, error: e } : { data: q.pending(limit), error: null };
    },
    async inviteUserByEmail(email, redirectTo) {
      calls.push({ who: 'admin', fn: 'inviteUserByEmail', args: { email, redirectTo } });
      const next = invites.length > 1 ? invites.shift()! : invites[0];
      if (next === 'throw') throw new Error('red');
      if (next === 'never') return new Promise(() => {});
      return { error: next };
    },
  };
  Object.freeze(admin); // si el código usara otra operación con la clave secreta, fallaría
  const deps: InvitationsDeps = {
    config: { appUrl: APP, allowedOrigins: [ORIGIN], sweepLimit: s.sweepLimit ?? 5 },
    admin,
    background: (t) => { tasks.push(t); },
    forUser(jwt) {
      jwts.push(jwt);
      return {
        async getUser() {
          if (s.user === 'throw') throw new Error('red');
          return s.user === undefined ? { id: 'u1', isAnonymous: false } : s.user;
        },
        async rpc(fn, args) {
          calls.push({ who: 'user', fn, args });
          const def: Record<UserRpc, RpcResult<unknown>> = {
            invitation_create: { data: INV, error: null },
            invitation_resend: { data: INV2, error: null },
            platform_create_restaurant: { data: { restaurantId: RID, invitationId: INV }, error: null },
          };
          const r = (s.rpc?.[fn] ?? def[fn]) as RpcResult<unknown>;
          // SQL guarda la invitación nueva como «sin_enviar»: es la entrega pendiente.
          if (!r.error) { const id = fn === 'invitation_resend' ? INV2 : INV; if (!q.rows.has(id)) q.add(id, s.account ?? 'nueva'); }
          return r as never;
        },
      };
    },
    log: (event, data) => logs.push({ event, data }),
  };
  const handle = createInvitationsHandler(deps);
  const post = (body: unknown, headers: Record<string, string> = {}) =>
    handle(new Request('https://fn.test/invitations', {
      method: 'POST',
      headers: { origin: ORIGIN, authorization: `Bearer ${JWT}`, 'content-type': 'application/json', ...headers },
      body: typeof body === 'string' ? body : JSON.stringify(body),
    }));
  const flush = async () => { await Promise.all(tasks.splice(0)); };
  const invitesSent = () => calls.filter((c) => c.fn === 'inviteUserByEmail');
  const adminCalls = () => calls.filter((c) => c.who === 'admin');
  return { handle, post, flush, q, calls, adminCalls, invitesSent, logs, jwts, tasks };
}

const create = { action: 'create', restaurantId: RID, email: 'persona@ejemplo.test', role: 'waiter' };

// ---------- Configuración y entrada ----------
describe('invitations: configuración', () => {
  it('APP_URL debe ser https fija (http solo en localhost), sin «?» ni «#»', () => {
    expect(parseAppUrl('https://app.ejemplo.com')).toBe('https://app.ejemplo.com/');
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
    expect(t.tasks).toEqual([]);
  });
  it('JWT no válido o de sesión anónima: 401/403 sin consultas ni tareas', async () => {
    for (const [user, status] of [[null, 401], ['throw', 401], [{ id: 'a', isAnonymous: true }, 403]] as const) {
      const t = setup({ user });
      expect((await t.post(create)).status).toBe(status);
      expect(t.calls).toEqual([]);
      expect(t.tasks).toEqual([]);
    }
  });
  it('lee solo los campos de cada acción', () => {
    expect(parseAction({ ...create, redirectTo: 'https://malo.test', p_role: 'owner', extra: 1 }))
      .toEqual({ action: 'create', restaurantId: RID, email: 'persona@ejemplo.test', role: 'waiter' });
  });
});

// ---------- Permisos en SQL con el JWT de quien llama ----------
describe('invitations: los permisos los decide SQL con el JWT de quien invita', () => {
  it('usa el JWT recibido y llama a la función SQL con los datos', async () => {
    const t = setup();
    await t.post(create);
    expect(t.jwts).toEqual([JWT]);
    expect(t.calls[0]).toEqual({ who: 'user', fn: 'invitation_create', args: { p_restaurant_id: RID, p_email: 'persona@ejemplo.test', p_role: 'waiter' } });
  });
  it('si SQL lo deniega: error, ninguna tarea en segundo plano y la clave secreta no se usa', async () => {
    const t = setup({ rpc: { invitation_create: { data: null, error: { code: '42501', message: 'No puedes invitar a esa función en este restaurante' } } } });
    const r = await t.post({ ...create, role: 'owner' });
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ ok: false, error: 'No puedes invitar a esa función en este restaurante' });
    expect(t.tasks).toEqual([]);
    expect(t.adminCalls()).toEqual([]);
  });
  it('traduce los errores de SQL sin filtrar detalles internos', () => {
    expect(sqlErrorResponse({ code: '54000', message: 'Has alcanzado el límite de 20 invitaciones por hora. Inténtalo más tarde' }).status).toBe(429);
    expect(sqlErrorResponse({ code: '22023', message: 'Ya hay una invitación pendiente para ese correo. Puedes reenviarla o revocarla' }).status).toBe(400);
    expect(sqlErrorResponse({ code: '23505', message: 'duplicate key value violates unique constraint "restaurants_slug_key"' }))
      .toEqual({ status: 409, error: 'Ya existe un restaurante con esa dirección web' });
    expect(sqlErrorResponse({ code: '23514', message: 'new row violates check constraint "restaurants_name_check"' }).status).toBe(400);
    const otro = sqlErrorResponse({ code: 'XX000', message: 'detalle interno de la base de datos' });
    expect(otro.status).toBe(500);
    expect(otro.error).not.toMatch(/interno|base de datos/);
  });
  it('límites de SQL (20/hora, 30 pendientes, reenvíos): 429 y sin envío', async () => {
    for (const [fn, body] of [['invitation_create', create], ['invitation_resend', { action: 'resend', invitationId: INV }]] as const) {
      const t = setup({ rpc: { [fn]: { data: null, error: { code: '54000', message: 'Espera al menos 5 minutos entre reenvíos' } } } });
      expect((await t.post(body)).status).toBe(429);
      expect(t.tasks).toEqual([]);
    }
  });
});

// ---------- Segundo plano: la respuesta no espera al correo ----------
describe('invitations: el correo se envía después de responder', () => {
  it('responde sin esperar a la entrega; el envío ocurre en la tarea de segundo plano', async () => {
    let open!: () => void;
    const t = setup({ claimGate: new Promise<void>((r) => { open = r; }) });
    const r = await t.post(create); // la reserva está bloqueada y aun así responde
    expect(r.status).toBe(200);
    expect(t.tasks).toHaveLength(1);
    expect(t.invitesSent()).toHaveLength(0);
    expect(t.q.state(INV)).toBe('sin_enviar/0');
    open();
    await t.flush();
    expect(t.invitesSent()).toHaveLength(1);
    expect(t.q.state(INV)).toBe('enviada/1');
  });
  it('la respuesta llega aunque Supabase Auth no conteste nunca', async () => {
    const t = setup({ invite: ['never'] });
    const r = await t.post(create);
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ ok: true, invitationId: INV, message: INVITATION_MESSAGE });
  });
  it('misma respuesta (estado, cuerpo y cabeceras) para cuentas nuevas, sin confirmar, confirmadas y envíos fallidos', async () => {
    const seen = new Set<string>();
    for (const s of [{ account: 'nueva' }, { account: 'sin_confirmar' }, { account: 'confirmada' },
      { invite: [{ status: 429, code: 'over_email_send_rate_limit' }] }, { invite: [{ status: 400, code: 'email_address_not_authorized' }] },
      { invite: ['never'] }, { fail: { claim: 'throw' } }] as Setup[]) {
      const t = setup(s);
      const r = await t.post(create);
      seen.add(JSON.stringify([r.status, await r.json(), [...r.headers.entries()].sort()]));
    }
    expect(seen.size).toBe(1);
  });
});

// ---------- Envíos correctos ----------
describe('invitations: envíos correctos', () => {
  it('cuenta nueva: Supabase la crea y envía el enlace a APP_URL; queda «enviada»', async () => {
    const t = setup({ account: 'nueva' });
    await t.post(create);
    await t.flush();
    expect(t.invitesSent()[0].args).toEqual({ email: `${INV}@ejemplo.test`, redirectTo: APP });
    expect(t.q.state(INV)).toBe('enviada/1');
  });
  it('cuenta invitada sin confirmar: se le reenvía el enlace; queda «enviada»', async () => {
    const t = setup({ account: 'sin_confirmar' });
    await t.post(create);
    await t.flush();
    expect(t.invitesSent()).toHaveLength(1);
    expect(t.q.state(INV)).toBe('enviada/1');
  });
  it('cuenta confirmada: sin correo (la verá en la app); queda «no_necesario»', async () => {
    const t = setup({ account: 'confirmada' });
    await t.post(create);
    await t.flush();
    expect(t.invitesSent()).toHaveLength(0);
    expect(t.q.state(INV)).toBe('no_necesario/1');
  });
  it('confirmó justo antes del envío (email_exists): «no_necesario»', async () => {
    const t = setup({ account: 'sin_confirmar', invite: [{ status: 422, code: 'email_exists' }] });
    await t.post(create);
    await t.flush();
    expect(t.q.state(INV)).toBe('no_necesario/1');
  });
  it('el correo es el que guarda SQL y la dirección de vuelta es APP_URL (nunca la del navegador)', async () => {
    const t = setup();
    await t.post({ ...create, email: '  PERSONA@Ejemplo.TEST ', redirectTo: 'https://malo.test/robar', redirect_to: 'https://malo.test' });
    await t.flush();
    expect(t.invitesSent()[0].args).toEqual({ email: `${INV}@ejemplo.test`, redirectTo: APP });
    expect(JSON.stringify(t.calls.filter((c) => c.who === 'admin'))).not.toContain('malo.test');
  });
  it('crear restaurante y reenviar: se entrega la invitación que devuelve SQL', async () => {
    const t = setup();
    const r = await t.post({ action: 'create_restaurant', name: 'Tercer Sitio', slug: 'tercer-sitio', ownerEmail: 'dueno@ejemplo.test' });
    expect(await r.json()).toEqual({ ok: true, invitationId: INV, restaurantId: RID, message: INVITATION_MESSAGE });
    expect(t.calls[0]).toEqual({ who: 'user', fn: 'platform_create_restaurant', args: { p_name: 'Tercer Sitio', p_slug: 'tercer-sitio', p_owner_email: 'dueno@ejemplo.test' } });
    await t.flush();
    expect(t.q.state(INV)).toBe('enviada/1');
    const r2 = await t.post({ action: 'resend', invitationId: INV });
    expect(await r2.json()).toEqual({ ok: true, invitationId: INV2, message: INVITATION_MESSAGE });
    await t.flush();
    expect(t.calls.filter((c) => c.fn === 'claim').map((c) => c.args)).toContain(INV2);
    expect(t.q.state(INV2)).toBe('enviada/1');
  });
});

// ---------- Envíos fallidos y reintentos ----------
describe('invitations: envíos fallidos y reintentos', () => {
  it('clasifica las respuestas de Supabase Auth', () => {
    expect(classifyInviteError(null)).toEqual({ result: 'enviada', rateLimited: false });
    expect(classifyInviteError({ status: 422, code: 'email_exists' })).toEqual({ result: 'no_necesario', rateLimited: false });
    expect(classifyInviteError({ status: 429, code: 'over_email_send_rate_limit' })).toEqual({ result: 'reintentar', rateLimited: true });
    expect(classifyInviteError({ status: 500 })).toEqual({ result: 'reintentar', rateLimited: false });
    expect(classifyInviteError({ status: 0, code: 'red' })).toEqual({ result: 'reintentar', rateLimited: false });
    expect(classifyInviteError({ status: 400, code: 'email_address_not_authorized' })).toEqual({ result: 'fallida', rateLimited: false });
  });
  it('fallo temporal: «sin_enviar» con espera de 5 min; no se reintenta antes', async () => {
    const t = setup({ invite: [{ status: 503 }] });
    await t.post(create);
    await t.flush();
    expect(t.q.state(INV)).toBe('sin_enviar/1');
    expect(t.q.rows.get(INV)!.nextAt! - t.q.now).toBe(5 * MIN);
    // Otra invitación llega 1 minuto después: la recuperación todavía no la toca.
    t.q.now += MIN;
    await t.post({ action: 'resend', invitationId: INV });
    await t.flush();
    expect(t.invitesSent().filter((c) => (c.args as { email: string }).email.startsWith(INV))).toHaveLength(1);
  });
  it('reintentos con espera y como mucho 3 intentos: después queda «fallida» y no se envía más', async () => {
    const q = new FakeQueue();
    q.add(INV2, 'nueva', { createdAt: q.now - 3 * MIN });
    const t = setup({ queue: q, invite: [{ status: 500 }] });
    for (let i = 0; i < 6; i++) {
      await t.post(create); // cada llamada recupera entregas atrasadas
      await t.flush();
      q.now += 31 * MIN;
    }
    expect(q.state(INV2)).toBe('fallida/3');
    expect(t.invitesSent().filter((c) => (c.args as { email: string }).email.startsWith(INV2))).toHaveLength(3);
  });
  it('fallo definitivo (4xx): «fallida» al primer intento, sin reintentos', async () => {
    const t = setup({ invite: [{ status: 400, code: 'email_address_not_authorized' }] });
    await t.post(create);
    await t.flush();
    expect(t.q.state(INV)).toBe('fallida/1');
  });
  it('límite de correos de Supabase (429): se reintentará más tarde y se para la recuperación', async () => {
    const q = new FakeQueue();
    for (let i = 0; i < 4; i++) q.add(`atrasada${i}`, 'nueva', { createdAt: q.now - 5 * MIN });
    const t = setup({ queue: q, invite: [{ status: 429, code: 'over_email_send_rate_limit' }] });
    await t.post(create);
    await t.flush();
    expect(q.state(INV)).toBe('sin_enviar/1');
    expect(t.invitesSent()).toHaveLength(1);
    expect(t.calls.some((c) => c.fn === 'pending')).toBe(false);
  });
  it('si la base de datos falla durante la entrega, la tarea no rompe nada y la respuesta ya se dio', async () => {
    for (const fail of [{ claim: 'throw' }, { claim: 'error' }, { finish: 'throw' }, { finish: 'error' }, { pending: 'throw' }, { pending: 'error' }] as const) {
      const t = setup({ fail });
      expect((await t.post(create)).status).toBe(200);
      await expect(t.flush()).resolves.toBeUndefined();
    }
  });
});

// ---------- Duplicados ----------
describe('invitations: sin envíos duplicados', () => {
  it('dos tareas simultáneas sobre la misma entrega: un solo correo', async () => {
    const q = new FakeQueue();
    q.add(INV2, 'nueva', { createdAt: q.now - 3 * MIN }); // atrasada: la ven la tarea propia y la recuperación
    const t = setup({ queue: q, rpc: { invitation_create: { data: INV2, error: null } } });
    await Promise.all([t.post(create), t.post(create), t.post(create)]);
    await t.flush();
    expect(t.invitesSent()).toHaveLength(1);
    expect(q.state(INV2)).toBe('enviada/1');
  });
  it('una entrega ya enviada no se vuelve a enviar en recuperaciones posteriores', async () => {
    const t = setup();
    await t.post(create);
    await t.flush();
    for (let i = 0; i < 3; i++) { t.q.now += 60 * MIN; await t.post({ action: 'resend', invitationId: INV }); await t.flush(); }
    expect(t.invitesSent().filter((c) => (c.args as { email: string }).email.startsWith(INV))).toHaveLength(1);
  });
  it('un proceso que perdió su reserva no sobrescribe el resultado de otro', async () => {
    const q = new FakeQueue();
    q.add(INV, 'nueva');
    const old = q.claim(INV)[0].claim; // proceso A reserva y se queda colgado
    q.now += 11 * MIN; // su reserva caduca
    const t = setup({ queue: q, rpc: { invitation_create: { data: INV2, error: null } } });
    await t.post(create); // B recupera la entrega de A
    await t.flush();
    expect(q.state(INV)).toBe('enviada/2');
    expect(q.finish(INV, old, 'fallida')).toBe(false); // A despierta tarde: no cambia nada
    expect(q.state(INV)).toBe('enviada/2');
  });
});

// ---------- Interrupciones ----------
describe('invitations: interrupciones de la función', () => {
  it('se interrumpe ANTES de reservar: la entrega sigue pendiente y otra llamada la recupera (pasados 2 min)', async () => {
    const t = setup({ fail: { claim: 'throw' } }); // la función se detiene antes de reservar
    await t.post(create);
    await t.flush();
    expect(t.q.state(INV)).toBe('sin_enviar/0');
    t.q.now += MIN;
    const t2 = setup({ queue: t.q, rpc: { invitation_create: { data: INV2, error: null } } });
    await t2.post(create);
    await t2.flush();
    expect(t.q.state(INV)).toBe('sin_enviar/0'); // aún en su margen de 2 minutos
    t.q.now += 2 * MIN;
    await t2.post(create);
    await t2.flush();
    expect(t.q.state(INV)).toBe('enviada/1');
  });
  it('se interrumpe DESPUÉS de reservar: la reserva caduca a los 10 min y otra llamada la retoma', async () => {
    const t = setup({ invite: ['never'] }); // Auth no contesta y el trabajador se detiene
    await t.post(create);
    void t.tasks.splice(0); // tarea abandonada a medias
    await new Promise((r) => setTimeout(r, 0));
    expect(t.q.state(INV)).toBe('enviando/1');
    const t2 = setup({ queue: t.q, rpc: { invitation_create: { data: INV2, error: null } } });
    t.q.now += 5 * MIN;
    await t2.post(create);
    await t2.flush();
    expect(t.q.state(INV)).toBe('enviando/1'); // reserva aún vigente: nadie la toca
    t.q.now += 6 * MIN;
    await t2.post(create);
    await t2.flush();
    expect(t.q.state(INV)).toBe('enviada/2');
  });
  it('interrumpida en el 3.er intento: se cierra como «fallida», no queda reservada para siempre', async () => {
    const q = new FakeQueue();
    q.add(INV, 'nueva', { attempts: 2 });
    q.claim(INV); // 3.er intento, el proceso muere
    q.now += 11 * MIN;
    const t = setup({ queue: q, rpc: { invitation_create: { data: INV2, error: null } } });
    await t.post(create);
    await t.flush();
    expect(q.state(INV)).toBe('fallida/3');
    expect(t.invitesSent().filter((c) => (c.args as { email: string }).email.startsWith(INV))).toHaveLength(0);
  });
  it('cada llamada recupera como mucho sweepLimit entregas (sin envíos en masa); primero las interrumpidas', async () => {
    const q = new FakeQueue();
    for (let i = 0; i < 20; i++) q.add(`vieja${String(i).padStart(2, '0')}`, 'nueva', { createdAt: q.now - 60 * MIN });
    q.add('colgada', 'nueva');
    q.claim('colgada');
    q.now += 11 * MIN;
    const t = setup({ queue: q, sweepLimit: 3 });
    await t.post(create);
    await t.flush();
    const sent = t.invitesSent().map((c) => (c.args as { email: string }).email.split('@')[0]);
    expect(sent).toEqual([INV, 'colgada', 'vieja00', 'vieja01']);
  });
});

// ---------- Registros ----------
describe('invitations: registros', () => {
  it('los registros no contienen correos ni el JWT', async () => {
    for (const s of [{}, { invite: [{ status: 500 }] }, { invite: [{ status: 429, code: 'over_email_send_rate_limit' }] },
      { fail: { finish: 'error' } }, { account: 'confirmada' }] as Setup[]) {
      const t = setup(s);
      await t.post({ ...create, email: 'secreto@ejemplo.test' });
      await t.flush();
      const text = JSON.stringify(t.logs);
      expect(text).not.toContain('@');
      expect(text).not.toContain(JWT);
    }
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
      expect(text, f).not.toMatch(/SUPABASE_SERVICE_ROLE_KEY|sb_secret_[A-Za-z0-9_-]{8,}|auth\.admin|inviteUserByEmail|invitation_delivery/);
    }
  });
});

// ---------- Recuperación programada (función «invitations-recovery») ----------
const SECRET = 'r'.repeat(20) + 'ecuperacion-secreta-de-prueba-0123456789';
function recovery(o: { queue?: FakeQueue; invite?: InviteReply[]; secret?: string | null; limit?: number; fail?: Setup['fail'] } = {}) {
  const q = o.queue ?? new FakeQueue();
  const calls: { fn: string; args: unknown }[] = [];
  const logs: { event: string; data: Record<string, unknown> }[] = [];
  const invites = [...(o.invite ?? [null])];
  const err = (k: 'claim' | 'finish' | 'pending') => {
    if (o.fail?.[k] === 'throw') throw new Error('red');
    return o.fail?.[k] === 'error' ? { code: 'XX000', message: 'fallo' } : null;
  };
  const admin: AdminApi = Object.freeze({
    async claim(id: string) { calls.push({ fn: 'claim', args: id }); const e = err('claim'); return e ? { data: null, error: e } : { data: q.claim(id), error: null }; },
    async finish(id: string, claim: string, result: FinishResult) { calls.push({ fn: 'finish', args: { id, result } }); const e = err('finish'); return e ? { data: null, error: e } : { data: q.finish(id, claim, result), error: null }; },
    async pending(limit: number) { calls.push({ fn: 'pending', args: limit }); const e = err('pending'); return e ? { data: null, error: e } : { data: q.pending(limit), error: null }; },
    async inviteUserByEmail(email: string, redirectTo: string) {
      calls.push({ fn: 'inviteUserByEmail', args: { email, redirectTo } });
      const next = invites.length > 1 ? invites.shift()! : invites[0];
      if (next === 'throw') throw new Error('red');
      if (next === 'never') return new Promise<{ error: AuthError | null }>(() => {});
      return { error: next };
    },
  });
  const handle = createRecoveryHandler({ secret: o.secret === undefined ? SECRET : o.secret, admin, appUrl: APP, limit: o.limit ?? 10, log: (event, data) => logs.push({ event, data }) });
  const run = (headers: Record<string, string> = { [RECOVERY_HEADER]: SECRET }, body: unknown = { action: 'recover' }, method = 'POST') =>
    handle(new Request('https://fn.test/invitations-recovery', { method, headers, body: method === 'GET' ? undefined : JSON.stringify(body) }));
  const sentTo = (prefix: string) => calls.filter((c) => c.fn === 'inviteUserByEmail' && (c.args as { email: string }).email.startsWith(prefix)).length;
  return { q, run, calls, logs, sentTo };
}

describe('recuperación programada: autenticación de servidor', () => {
  it('compara el secreto sin atajos (mismo resultado para longitudes distintas)', async () => {
    expect(await sameSecret(SECRET, SECRET)).toBe(true);
    expect(await sameSecret(SECRET, SECRET.slice(0, -1) + 'x')).toBe(false);
    expect(await sameSecret(SECRET, SECRET + 'x')).toBe(false);
    expect(await sameSecret(SECRET, '')).toBe(false);
  });
  it('sin secreto configurado (o demasiado corto): falla cerrado y no toca la cola', async () => {
    for (const secret of [null, '', 'corto-de-menos-de-32-caracteres']) {
      const t = recovery({ secret });
      expect((await t.run()).status).toBe(500);
      expect(t.calls).toEqual([]);
    }
  });
  it('sin cabecera, con secreto erróneo, con un JWT de usuario o la clave pública: 401 y nada más', async () => {
    const t = recovery();
    t.q.add(INV, 'nueva', { createdAt: t.q.now - 5 * MIN });
    const attempts: Record<string, string>[] = [{}, { [RECOVERY_HEADER]: 'x' }, { [RECOVERY_HEADER]: SECRET.toUpperCase() },
      { [RECOVERY_HEADER]: SECRET.slice(0, -1) }, { [RECOVERY_HEADER]: SECRET + 'x' },
      { authorization: `Bearer ${JWT}` }, { authorization: `Bearer ${SECRET}` }, { apikey: SECRET }];
    for (const headers of attempts)
      expect((await t.run(headers)).status).toBe(401);
    expect(t.calls).toEqual([]);
    expect(t.q.state(INV)).toBe('sin_enviar/0');
  });
  it('navegadores (Origin) y otros métodos: rechazados aunque traigan el secreto', async () => {
    const t = recovery();
    expect((await t.run({ [RECOVERY_HEADER]: SECRET, origin: ORIGIN })).status).toBe(403);
    expect((await t.run({ [RECOVERY_HEADER]: SECRET }, undefined, 'GET')).status).toBe(405);
    expect((await t.run({ [RECOVERY_HEADER]: SECRET }, { action: 'create', email: 'x@y.z' })).status).toBe(400);
    expect(t.calls).toEqual([]);
  });
  it('los registros no contienen el secreto ni correos', async () => {
    const t = recovery({ invite: [{ status: 500 }] });
    t.q.add(INV, 'nueva', { createdAt: t.q.now - 5 * MIN });
    await t.run({ [RECOVERY_HEADER]: 'malo' });
    await t.run();
    const text = JSON.stringify(t.logs);
    expect(text).not.toContain(SECRET);
    expect(text).not.toContain('@');
  });
});

describe('recuperación programada: entregas', () => {
  it('recupera entregas pendientes SIN nuevas invitaciones y devuelve un resumen sin datos personales', async () => {
    const t = recovery();
    t.q.add(INV, 'nueva', { createdAt: t.q.now - 5 * MIN });          // su proceso nunca llegó a reservarla
    t.q.add(INV2, 'confirmada', { createdAt: t.q.now - 5 * MIN });
    t.q.add('colgada', 'sin_confirmar'); t.q.claim('colgada'); t.q.now += 11 * MIN; // interrumpida tras reservar
    const r = await t.run();
    expect(r.status).toBe(200);
    const body = await r.json();
    expect(body).toEqual({ ok: true, procesadas: 3, resultados: { enviada: 2, no_necesario: 1 }, limiteDeCorreos: false, errorDeCola: false });
    expect(JSON.stringify(body)).not.toContain('@');
    expect([t.q.state(INV), t.q.state(INV2), t.q.state('colgada')]).toEqual(['enviada/1', 'no_necesario/1', 'enviada/2']);
    expect(t.calls.filter((c) => c.fn === 'inviteUserByEmail').every((c) => (c.args as { redirectTo: string }).redirectTo === APP)).toBe(true);
  });
  it('no toca entregas recién creadas (2 min), en espera de reintento, enviadas ni cerradas', async () => {
    const t = recovery();
    t.q.add('fresca', 'nueva');
    t.q.add('espera', 'nueva', { createdAt: t.q.now - 60 * MIN, attempts: 1, nextAt: t.q.now + 4 * MIN });
    t.q.add('hecha', 'nueva', { createdAt: t.q.now - 60 * MIN, send: 'enviada', attempts: 1 });
    t.q.add('revocada', 'nueva', { createdAt: t.q.now - 60 * MIN, status: 'revocada' });
    const r = await t.run();
    expect((await r.json()).procesadas).toBe(0);
    expect(t.calls.some((c) => c.fn === 'inviteUserByEmail')).toBe(false);
  });
  it('como mucho `limit` entregas por ejecución (máximo 10), primero las interrumpidas', async () => {
    const t = recovery({ limit: 4 });
    for (let i = 0; i < 15; i++) t.q.add(`vieja${String(i).padStart(2, '0')}`, 'nueva', { createdAt: t.q.now - 60 * MIN });
    t.q.add('colgada', 'nueva'); t.q.claim('colgada'); t.q.now += 11 * MIN;
    await t.run();
    expect(t.calls.filter((c) => c.fn === 'pending').map((c) => c.args)).toEqual([4]);
    expect(t.calls.filter((c) => c.fn === 'inviteUserByEmail').map((c) => (c.args as { email: string }).email.split('@')[0]))
      .toEqual(['colgada', 'vieja00', 'vieja01', 'vieja02']);
    const t2 = recovery({ limit: 50 });
    await t2.run();
    expect(t2.calls.filter((c) => c.fn === 'pending').map((c) => c.args)).toEqual([10]);
  });
  it('reintentos: respeta las esperas (5 y 30 min) y el máximo de 3 intentos aunque se ejecute cada 5 minutos', async () => {
    const t = recovery({ invite: [{ status: 503 }] });
    t.q.add(INV, 'nueva', { createdAt: t.q.now - 5 * MIN });
    const log: string[] = [];
    for (let tick = 0; tick < 24; tick++) { // 2 horas de ejecuciones cada 5 minutos
      await t.run();
      log.push(t.q.state(INV));
      t.q.now += 5 * MIN;
    }
    expect(t.sentTo(INV)).toBe(3);
    expect(t.q.state(INV)).toBe('fallida/3');
    // 1.er intento en la ejecución 0; 2.º tras 5 min (ejecución 1); 3.º tras 30 min más (ejecución 7)
    expect(log.slice(0, 8)).toEqual(['sin_enviar/1', 'sin_enviar/2', 'sin_enviar/2', 'sin_enviar/2', 'sin_enviar/2', 'sin_enviar/2', 'sin_enviar/2', 'fallida/3']);
  });
  it('un fallo temporal no bloquea la cola: la siguiente ejecución tras la espera la envía', async () => {
    const t = recovery({ invite: [{ status: 500 }, null] });
    t.q.add(INV, 'nueva', { createdAt: t.q.now - 5 * MIN });
    await t.run();
    expect(t.q.state(INV)).toBe('sin_enviar/1');
    t.q.now += 5 * MIN;
    await t.run();
    expect(t.q.state(INV)).toBe('enviada/2');
  });
  it('si la base de datos falla, la ejecución termina y la siguiente lo reintenta', async () => {
    for (const fail of [{ pending: 'throw' }, { pending: 'error' }, { claim: 'throw' }, { finish: 'error' }] as const) {
      const t = recovery({ fail });
      t.q.add(INV, 'nueva', { createdAt: t.q.now - 5 * MIN });
      const r = await t.run();
      expect(r.status).toBe(200);
    }
    const t = recovery({ fail: { pending: 'error' } });
    expect((await (await t.run()).json()).errorDeCola).toBe(true);
  });
  it('límite de correos de Supabase (429): se detiene la ejecución y las demás esperan', async () => {
    const t = recovery({ invite: [{ status: 429, code: 'over_email_send_rate_limit' }] });
    for (let i = 0; i < 5; i++) t.q.add(`p${i}`, 'nueva', { createdAt: t.q.now - 60 * MIN });
    const body = await (await t.run()).json();
    expect(body.limiteDeCorreos).toBe(true);
    expect(t.calls.filter((c) => c.fn === 'inviteUserByEmail')).toHaveLength(1);
  });
  it('ejecuciones simultáneas (y una invitación a la vez) no duplican envíos', async () => {
    const q = new FakeQueue();
    for (let i = 0; i < 6; i++) q.add(`p${i}`, 'nueva', { createdAt: q.now - 60 * MIN });
    const a = recovery({ queue: q });
    const b = recovery({ queue: q });
    const c = setup({ queue: q });
    await Promise.all([a.run(), b.run(), a.run(), b.run(), c.post(create)]);
    await c.flush();
    for (let i = 0; i < 6; i++) expect(q.state(`p${i}`)).toBe('enviada/1');
    const total = [...a.calls, ...b.calls, ...c.calls].filter((x) => x.fn === 'inviteUserByEmail' && (x.args as { email: string }).email.startsWith('p'));
    expect(total).toHaveLength(6);
  });
});
