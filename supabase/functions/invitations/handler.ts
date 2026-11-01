/**
 * Lógica de la Edge Function «invitations» (fase 6). Sin dependencias de Deno ni de npm:
 * index.ts le pasa los clientes de Supabase ya creados. Así se prueba con Vitest y clientes
 * simulados (src/__tests__/invitationsFunction.test.ts).
 *
 * Reglas:
 *  - Identidad: el JWT de quien llama se verifica con Supabase Auth (getUser).
 *  - Permisos: TODA la decisión la toma SQL (invitation_create, platform_create_restaurant,
 *    invitation_resend) ejecutado CON EL JWT DE QUIEN LLAMA. La clave secreta no decide nada.
 *  - Clave secreta: solo para `auth.admin.inviteUserByEmail` y las funciones de entrega
 *    (invitation_delivery_claim / _finish / _pending). AdminApi no expone nada más.
 *  - La respuesta a quien invita es la MISMA tenga o no cuenta el correo, sea de otro restaurante
 *    o de la plataforma. Se da en cuanto SQL crea la invitación: el correo se envía DESPUÉS, en
 *    segundo plano (EdgeRuntime.waitUntil), así que ni la respuesta ni su duración dependen del envío.
 *  - Entrega fiable: el estado vive en la base de datos (reserva con caducidad, intentos y espera
 *    entre reintentos). Si la función se interrumpe, la entrega queda pendiente y la recupera la
 *    siguiente llamada a la función (como mucho `sweepLimit` por llamada).
 *  - La dirección de vuelta del correo es APP_URL (secreto de la función). Nunca se lee del
 *    navegador.
 *  - Los registros (logs) no incluyen correos, JWT ni claves.
 */

export type StaffRole = 'owner' | 'manager' | 'waiter' | 'kitchen';
/** Resultado que se anota con invitation_delivery_finish. */
export type FinishResult = 'enviada' | 'no_necesario' | 'reintentar' | 'fallida';

export interface RpcError {
  code?: string;
  message?: string;
}
export interface RpcResult<T> {
  data: T | null;
  error: RpcError | null;
}
export interface AuthError {
  status?: number;
  code?: string;
  message?: string;
}

/** Funciones SQL que se llaman con el JWT de quien invita. */
export type UserRpc = 'invitation_create' | 'platform_create_restaurant' | 'invitation_resend';

/** Cliente con el JWT de quien llama (clave pública + Authorization: Bearer <jwt>). */
export interface UserApi {
  /** Verifica el JWT con Supabase Auth. null si no es válido. */
  getUser(): Promise<{ id: string; isAnonymous: boolean } | null>;
  rpc<T>(fn: UserRpc, args: Record<string, unknown>): Promise<RpcResult<T>>;
}

/** Fila de invitation_delivery_claim (solo el servidor la ve). Vacía si no se pudo reservar. */
export interface ClaimRow {
  claim: string;
  attempt: number;
  email: string;
  role: StaffRole;
  restaurant_name: string;
  account_exists: boolean;
  account_confirmed: boolean;
}

/** Operaciones con la clave secreta. SOLO estas cuatro. */
export interface AdminApi {
  /** Reserva atómica de la entrega (dos procesos nunca reservan la misma). */
  claim(invitationId: string): Promise<RpcResult<ClaimRow[]>>;
  /** Anota el resultado; false si la reserva ya no es la vigente. */
  finish(invitationId: string, claim: string, result: FinishResult): Promise<RpcResult<boolean>>;
  /** Entregas atrasadas o interrumpidas (como mucho 10). */
  pending(limit: number): Promise<RpcResult<string[]>>;
  inviteUserByEmail(email: string, redirectTo: string): Promise<{ error: AuthError | null }>;
}

export interface InvitationsConfig {
  /** Dirección fija de la app a la que vuelve el enlace del correo (APP_URL). */
  appUrl: string;
  /** Orígenes del navegador admitidos (CORS). */
  allowedOrigins: string[];
  /** Entregas atrasadas o interrumpidas que recupera cada llamada (1-10). */
  sweepLimit: number;
}

export interface InvitationsDeps {
  config: InvitationsConfig;
  forUser(jwt: string): UserApi;
  admin: AdminApi;
  /** Ejecuta la tarea después de responder (EdgeRuntime.waitUntil). La tarea nunca lanza. */
  background(task: Promise<void>): void;
  /** Registro de eventos. Nunca recibe correos, JWT ni claves. */
  log?: (event: string, data: Record<string, unknown>) => void;
}

export const MAX_BODY_BYTES = 4096;

/** Mismo texto en todos los casos: no revela si el correo tiene cuenta ni si se enviará correo. */
export const INVITATION_MESSAGE =
  'Invitación creada. Si la persona ya tiene cuenta, la verá al entrar en TuRestaurante; si no, recibirá un correo para crearla. Si no le llega, podrás reenviarla dentro de unos minutos.';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ROLES: readonly StaffRole[] = ['owner', 'manager', 'waiter', 'kitchen'];

/**
 * Valida APP_URL. Debe ser https (o http solo en localhost / 127.0.0.1, para pruebas locales),
 * sin usuario, sin «?» ni «#»: Supabase añade tras «#» los datos de la sesión del enlace.
 * Devuelve la URL normalizada o null.
 */
export function parseAppUrl(raw: string | undefined | null): string | null {
  if (!raw) return null;
  let url: URL;
  try {
    url = new URL(raw.trim());
  } catch {
    return null;
  }
  const local = url.hostname === 'localhost' || url.hostname === '127.0.0.1';
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && local)) return null;
  if (url.username || url.password || url.search || url.hash || raw.includes('#') || raw.includes('?')) return null;
  return url.href;
}

/** ALLOWED_ORIGINS (separados por comas) o, si no hay, el origen de APP_URL. */
export function parseOrigins(raw: string | undefined | null, appUrl: string): string[] {
  const list = (raw ?? '').split(',').map((o) => o.trim()).filter(Boolean);
  const origins = list.length ? list : [new URL(appUrl).origin];
  return origins.flatMap((o) => {
    try {
      const u = new URL(o);
      return u.origin === o.replace(/\/$/, '') ? [u.origin] : [];
    } catch {
      return [];
    }
  });
}

type Action =
  | { action: 'create'; restaurantId: string; email: string; role: StaffRole }
  | { action: 'create_restaurant'; name: string; slug: string; ownerEmail: string }
  | { action: 'resend'; invitationId: string };

class BadRequest extends Error {}

function str(v: unknown, field: string, max: number): string {
  if (typeof v !== 'string' || !v.trim() || v.length > max) throw new BadRequest(`Falta o no es válido: ${field}`);
  return v;
}
function uuid(v: unknown, field: string): string {
  if (typeof v !== 'string' || !UUID_RE.test(v)) throw new BadRequest(`Falta o no es válido: ${field}`);
  return v.toLowerCase();
}
function email(v: unknown, field: string): string {
  const e = str(v, field, 320);
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e.trim())) throw new BadRequest('El correo electrónico no es válido');
  return e;
}

/** Solo se leen los campos de cada acción. Cualquier otro (por ejemplo «redirectTo») se ignora. */
export function parseAction(body: unknown): Action {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new BadRequest('Petición no válida');
  const b = body as Record<string, unknown>;
  switch (b.action) {
    case 'create': {
      const role = b.role;
      if (typeof role !== 'string' || !ROLES.includes(role as StaffRole)) throw new BadRequest('Falta o no es válido: role');
      return { action: 'create', restaurantId: uuid(b.restaurantId, 'restaurantId'), email: email(b.email, 'email'), role: role as StaffRole };
    }
    case 'create_restaurant':
      return {
        action: 'create_restaurant',
        name: str(b.name, 'name', 80),
        slug: str(b.slug, 'slug', 40),
        ownerEmail: email(b.ownerEmail, 'ownerEmail'),
      };
    case 'resend':
      return { action: 'resend', invitationId: uuid(b.invitationId, 'invitationId') };
    default:
      throw new BadRequest('Acción no válida');
  }
}

function bearer(header: string | null): string | null {
  const m = /^Bearer\s+([A-Za-z0-9._~+/=-]+)$/.exec(header ?? '');
  return m ? m[1] : null;
}

/** Errores de SQL → respuesta. Los mensajes de las funciones SQL están escritos para el usuario
 *  y no revelan si un correo tiene cuenta; los demás errores se ocultan. */
export function sqlErrorResponse(err: RpcError): { status: number; error: string } {
  const msg = err.message ?? '';
  switch (err.code) {
    case '42501':
      return { status: 403, error: msg || 'No tienes permiso para esta operación' };
    case '54000':
      return { status: 429, error: msg || 'Has alcanzado un límite. Inténtalo más tarde' };
    case '22023':
      return { status: 400, error: msg || 'Datos no válidos' };
    case '23505':
      return { status: 409, error: 'Ya existe un restaurante con esa dirección web' };
    case '23514':
      return { status: 400, error: 'Los datos del restaurante no son válidos (nombre o dirección web)' };
    default:
      return { status: 500, error: 'No se ha podido completar la invitación. Inténtalo de nuevo' };
  }
}

/** Qué anotar según la respuesta de Supabase Auth a inviteUserByEmail. */
export function classifyInviteError(error: AuthError | null): { result: FinishResult; rateLimited: boolean } {
  if (!error) return { result: 'enviada', rateLimited: false };
  // Confirmó su cuenta entre la reserva y el envío: la verá dentro de la app.
  if (error.code === 'email_exists') return { result: 'no_necesario', rateLimited: false };
  // Límite de correos de Supabase: se reintenta más tarde (con espera) y se para la recuperación.
  if (error.status === 429 || error.code === 'over_email_send_rate_limit') return { result: 'reintentar', rateLimited: true };
  // Fallo temporal (red o error del servidor): se reintenta más tarde.
  if (!error.status || error.status >= 500) return { result: 'reintentar', rateLimited: false };
  // Otro 4xx (p. ej. correo no autorizado por el SMTP de pruebas): no se reintenta.
  return { result: 'fallida', rateLimited: false };
}

export function createInvitationsHandler(deps: InvitationsDeps): (req: Request) => Promise<Response> {
  const { config, admin } = deps;
  const log = deps.log ?? (() => {});
  const sweepLimit = Math.max(1, Math.min(10, Math.floor(config.sweepLimit) || 1));

  function cors(origin: string | null): Record<string, string> | null {
    if (!origin || !config.allowedOrigins.includes(origin)) return null;
    return {
      'Access-Control-Allow-Origin': origin,
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
      'Access-Control-Max-Age': '600',
      Vary: 'Origin',
    };
  }
  function json(status: number, body: unknown, headers: Record<string, string> | null): Response {
    return new Response(JSON.stringify(body), {
      status,
      headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...(headers ?? {}) },
    });
  }

  /** Una entrega: reservar → enviar (o no) → anotar. Nunca lanza. */
  async function deliverOne(invitationId: string): Promise<{ result: FinishResult | 'sin_reserva' | 'error'; rateLimited: boolean }> {
    let row: ClaimRow | undefined;
    try {
      const r = await admin.claim(invitationId);
      if (r.error) {
        log('reserva_fallida', { invitationId, code: r.error.code ?? null });
        return { result: 'error', rateLimited: false };
      }
      row = r.data?.[0];
    } catch {
      log('reserva_fallida', { invitationId, code: 'excepcion' });
      return { result: 'error', rateLimited: false };
    }
    // Ya enviada, reservada por otro proceso, esperando reintento, cerrada o caducada: nada que hacer.
    if (!row) return { result: 'sin_reserva', rateLimited: false };

    let outcome: { result: FinishResult; rateLimited: boolean };
    if (row.account_confirmed) {
      // Cuenta confirmada: la verá dentro de TuRestaurante (por ahora sin aviso por correo).
      outcome = { result: 'no_necesario', rateLimited: false };
    } else {
      // Sin cuenta: Supabase la crea y envía el enlace. Invitada sin confirmar: Supabase vuelve a
      // enviar el enlace sin crear otra cuenta. Si el envío falla, Supabase no crea nada.
      let error: AuthError | null;
      try {
        ({ error } = await admin.inviteUserByEmail(row.email, config.appUrl));
      } catch {
        error = { status: 0, code: 'red' };
      }
      outcome = classifyInviteError(error);
      if (error && error.code !== 'email_exists') {
        log('envio_fallido', { invitationId, attempt: row.attempt, status: error.status ?? null, code: error.code ?? null });
      }
    }
    try {
      const f = await admin.finish(invitationId, row.claim, outcome.result);
      if (f.error) log('anotacion_fallida', { invitationId, code: f.error.code ?? null });
      // La reserva caducó y otro proceso la retomó: su resultado manda. (Solo pasa si este proceso
      // tardó más de 10 minutos.)
      else if (f.data === false) log('resultado_descartado', { invitationId, attempt: row.attempt });
    } catch {
      log('anotacion_fallida', { invitationId, code: 'excepcion' });
    }
    log('entrega', { invitationId, attempt: row.attempt, result: outcome.result });
    return outcome;
  }

  /** En segundo plano: la entrega de la invitación recién creada y la recuperación de entregas
   *  atrasadas o interrumpidas (como mucho sweepLimit). Se para si Supabase limita los correos. */
  async function processDeliveries(invitationId: string): Promise<void> {
    try {
      const first = await deliverOne(invitationId);
      if (first.rateLimited) return;
      let ids: string[] = [];
      try {
        const p = await admin.pending(sweepLimit);
        if (p.error) log('recuperacion_fallida', { code: p.error.code ?? null });
        ids = (p.data ?? []).filter((id) => id !== invitationId).slice(0, sweepLimit);
      } catch {
        log('recuperacion_fallida', { code: 'excepcion' });
      }
      for (const id of ids) {
        const r = await deliverOne(id);
        if (r.rateLimited) break;
      }
    } catch {
      log('segundo_plano_fallido', { invitationId });
    }
  }

  return async function handle(req: Request): Promise<Response> {
    const origin = req.headers.get('origin');
    const corsHeaders = cors(origin);
    if (req.method === 'OPTIONS') {
      return corsHeaders ? new Response(null, { status: 204, headers: corsHeaders }) : new Response(null, { status: 403 });
    }
    if (origin && !corsHeaders) return json(403, { ok: false, error: 'Origen no permitido' }, null);
    if (req.method !== 'POST') return json(405, { ok: false, error: 'Método no permitido' }, corsHeaders);

    const jwt = bearer(req.headers.get('authorization'));
    if (!jwt) return json(401, { ok: false, error: 'Inicia sesión para invitar' }, corsHeaders);

    let action: Action;
    try {
      const text = await req.text();
      if (new TextEncoder().encode(text).length > MAX_BODY_BYTES) throw new BadRequest('Petición demasiado grande');
      let body: unknown;
      try {
        body = JSON.parse(text);
      } catch {
        throw new BadRequest('Petición no válida');
      }
      action = parseAction(body);
    } catch (e) {
      const error = e instanceof BadRequest ? e.message : 'Petición no válida';
      return json(400, { ok: false, error }, corsHeaders);
    }

    const user = deps.forUser(jwt);
    let who: { id: string; isAnonymous: boolean } | null = null;
    try {
      who = await user.getUser();
    } catch {
      who = null;
    }
    if (!who) return json(401, { ok: false, error: 'Tu sesión no es válida. Vuelve a iniciar sesión' }, corsHeaders);
    if (who.isAnonymous) return json(403, { ok: false, error: 'Inicia sesión con tu cuenta para invitar' }, corsHeaders);

    // 1) Permisos y datos: SQL con el JWT de quien llama. (No consulta si el correo tiene cuenta:
    //    su duración no depende de eso.)
    let invitationId: string;
    let restaurantId: string | undefined;
    try {
      if (action.action === 'create') {
        const r = await user.rpc<string>('invitation_create', {
          p_restaurant_id: action.restaurantId, p_email: action.email, p_role: action.role,
        });
        if (r.error || !r.data) throw r.error ?? {};
        invitationId = r.data;
      } else if (action.action === 'create_restaurant') {
        const r = await user.rpc<{ restaurantId: string; invitationId: string }>('platform_create_restaurant', {
          p_name: action.name, p_slug: action.slug, p_owner_email: action.ownerEmail,
        });
        if (r.error || !r.data?.invitationId) throw r.error ?? {};
        invitationId = r.data.invitationId;
        restaurantId = r.data.restaurantId;
      } else {
        const r = await user.rpc<string>('invitation_resend', { p_invitation_id: action.invitationId });
        if (r.error || !r.data) throw r.error ?? {};
        invitationId = r.data;
      }
    } catch (e) {
      const err = (e && typeof e === 'object' ? e : {}) as RpcError;
      const { status, error } = sqlErrorResponse(err);
      if (status === 500) log('sql_error', { action: action.action, code: err.code ?? null });
      return json(status, { ok: false, error }, corsHeaders);
    }

    // 2) El correo, DESPUÉS de responder. La entrega ya está guardada como pendiente en la base de
    //    datos: si esta tarea no llega a terminar, se recupera en otra llamada.
    deps.background(processDeliveries(invitationId));
    return json(200, { ok: true, invitationId, ...(restaurantId ? { restaurantId } : {}), message: INVITATION_MESSAGE }, corsHeaders);
  };
}
