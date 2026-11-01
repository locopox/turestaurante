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
 *    (invitation_delivery, invitation_mark_sent). AdminApi no expone nada más.
 *  - La respuesta a quien invita es la MISMA tenga o no cuenta el correo, sea de otro restaurante
 *    o de la plataforma, y se haya enviado o no el correo. Tampoco depende del tiempo de envío
 *    (tiempo mínimo de respuesta).
 *  - La dirección de vuelta del correo es APP_URL (secreto de la función). Nunca se lee del
 *    navegador.
 *  - Los registros (logs) no incluyen correos, JWT ni claves.
 */

export type StaffRole = 'owner' | 'manager' | 'waiter' | 'kitchen';
export type SendResult = 'enviada' | 'fallida' | 'no_necesario';

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

/** Fila de invitation_delivery (solo el servidor la ve). */
export interface DeliveryRow {
  email: string;
  role: StaffRole;
  restaurant_name: string;
  expires_at: string;
  account_exists: boolean;
  account_confirmed: boolean;
  state: string;
}

/** Operaciones con la clave secreta. SOLO estas tres. */
export interface AdminApi {
  delivery(invitationId: string): Promise<RpcResult<DeliveryRow[]>>;
  markSent(invitationId: string, result: SendResult): Promise<RpcResult<unknown>>;
  inviteUserByEmail(email: string, redirectTo: string): Promise<{ error: AuthError | null }>;
}

export interface InvitationsConfig {
  /** Dirección fija de la app a la que vuelve el enlace del correo (APP_URL). */
  appUrl: string;
  /** Orígenes del navegador admitidos (CORS). */
  allowedOrigins: string[];
  /** Tiempo mínimo de respuesta tras autenticar (ms), para que no se note si hubo envío. */
  minResponseMs: number;
  /** Espera antes del único reintento de envío ante un fallo temporal (ms). */
  retryDelayMs: number;
}

export interface InvitationsDeps {
  config: InvitationsConfig;
  forUser(jwt: string): UserApi;
  admin: AdminApi;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  /** Registro de eventos. Nunca recibe correos, JWT ni claves. */
  log?: (event: string, data: Record<string, unknown>) => void;
}

export const MAX_BODY_BYTES = 4096;
/** Intentos de envío como máximo (1 reintento) ante fallos temporales del servidor de Auth. */
export const MAX_SEND_ATTEMPTS = 2;

/** Mismo texto en todos los casos: no revela si el correo tiene cuenta ni si se envió. */
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

const defaultSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export function createInvitationsHandler(deps: InvitationsDeps): (req: Request) => Promise<Response> {
  const { config, admin } = deps;
  const now = deps.now ?? (() => Date.now());
  const sleep = deps.sleep ?? defaultSleep;
  const log = deps.log ?? (() => {});

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

  /** Envía (o no) el correo de una invitación ya creada. Nunca lanza: el resultado no cambia la
   *  respuesta a quien invita. */
  async function deliver(invitationId: string): Promise<SendResult | 'sin_datos' | 'omitida'> {
    let row: DeliveryRow | undefined;
    try {
      const r = await admin.delivery(invitationId);
      if (r.error) {
        log('entrega_sin_datos', { invitationId, code: r.error.code ?? null });
        return 'sin_datos';
      }
      row = r.data?.[0];
    } catch {
      log('entrega_sin_datos', { invitationId, code: 'excepcion' });
      return 'sin_datos';
    }
    if (!row || row.state !== 'pendiente') {
      log('entrega_omitida', { invitationId, state: row?.state ?? null });
      return 'omitida';
    }

    let result: SendResult;
    if (row.account_confirmed) {
      // Cuenta confirmada: la verá dentro de TuRestaurante (por ahora sin aviso por correo).
      result = 'no_necesario';
    } else {
      // Sin cuenta: Supabase la crea y envía la invitación. Cuenta invitada sin confirmar:
      // Supabase vuelve a enviar el enlace (no crea otra). Si el envío falla, no crea nada.
      result = 'fallida';
      for (let attempt = 1; attempt <= MAX_SEND_ATTEMPTS; attempt++) {
        let error: AuthError | null;
        try {
          ({ error } = await admin.inviteUserByEmail(row.email, config.appUrl));
        } catch {
          error = { status: 0, code: 'red' };
        }
        if (!error) {
          result = 'enviada';
          break;
        }
        if (error.code === 'email_exists') {
          // Confirmó su cuenta entre la consulta y el envío: la verá dentro de la app.
          result = 'no_necesario';
          break;
        }
        log('envio_fallido', { invitationId, attempt, status: error.status ?? null, code: error.code ?? null });
        // Solo se reintenta un fallo temporal (red o error 5xx). Límite de correos (429), correo
        // no autorizado por el SMTP (400) u otros 4xx: no, se anota como fallido.
        const temporary = !error.status || error.status >= 500;
        if (!temporary || attempt === MAX_SEND_ATTEMPTS) break;
        await sleep(config.retryDelayMs);
      }
    }
    try {
      const m = await admin.markSent(invitationId, result);
      if (m.error) log('anotacion_fallida', { invitationId, code: m.error.code ?? null });
    } catch {
      log('anotacion_fallida', { invitationId, code: 'excepcion' });
    }
    log('entrega', { invitationId, result });
    return result;
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

    const start = now();
    /** Tiempo mínimo de respuesta: que no se note si hubo envío de correo o no. */
    const settle = async () => {
      const left = config.minResponseMs - (now() - start);
      if (left > 0) await sleep(left);
    };

    // 1) Permisos y datos: SQL con el JWT de quien llama.
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
      await settle();
      return json(status, { ok: false, error }, corsHeaders);
    }

    // 2) Envío del correo (clave secreta). Su resultado NO cambia la respuesta.
    await deliver(invitationId);
    await settle();
    return json(200, { ok: true, invitationId, ...(restaurantId ? { restaurantId } : {}), message: INVITATION_MESSAGE }, corsHeaders);
  };
}
