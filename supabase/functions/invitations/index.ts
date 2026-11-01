// Edge Function «invitations» (Deno, Supabase Edge Runtime). Solo crea los clientes y lee la
// configuración; la lógica está en handler.ts. NO se ejecuta en el navegador: la clave secreta
// (SUPABASE_SERVICE_ROLE_KEY) existe solo aquí, en el servidor de Supabase.
//
// Variables (Supabase inyecta las tres primeras en sus Edge Functions; APP_URL hay que darla):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//   APP_URL          dirección fija de la app (destino del enlace del correo)
//   ALLOWED_ORIGINS  opcional: orígenes del navegador admitidos, separados por comas
//   MIN_RESPONSE_MS  opcional: tiempo mínimo de respuesta (por defecto 1500)
import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import {
  createInvitationsHandler, parseAppUrl, parseOrigins,
  type AdminApi, type DeliveryRow, type RpcResult, type SendResult, type UserApi, type UserRpc,
} from './handler.ts';

const env = (k: string) => Deno.env.get(k)?.trim() || undefined;
const supabaseUrl = env('SUPABASE_URL');
const publicKey = env('SUPABASE_ANON_KEY');
const secretKey = env('SUPABASE_SERVICE_ROLE_KEY');
const appUrl = parseAppUrl(env('APP_URL'));
const minResponseMs = Number(env('MIN_RESPONSE_MS') ?? '1500');

const noSession = { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false };

function misconfigured(): (req: Request) => Promise<Response> {
  // Falla cerrado: sin configuración completa no se invita a nadie.
  console.error(JSON.stringify({ event: 'configuracion_incompleta', supabaseUrl: !!supabaseUrl, publicKey: !!publicKey,
    secretKey: !!secretKey, appUrl: !!appUrl }));
  return async () => new Response(JSON.stringify({ ok: false, error: 'La función de invitaciones no está configurada' }),
    { status: 500, headers: { 'Content-Type': 'application/json; charset=utf-8' } });
}

function handler(): (req: Request) => Promise<Response> {
  if (!supabaseUrl || !publicKey || !secretKey || !appUrl || !Number.isFinite(minResponseMs) || minResponseMs < 0) {
    return misconfigured();
  }
  const service = createClient(supabaseUrl, secretKey, { auth: noSession });
  // Lo ÚNICO que se hace con la clave secreta.
  const admin: AdminApi = {
    async delivery(id) {
      const { data, error } = await service.rpc('invitation_delivery', { p_invitation_id: id });
      return { data: (data as DeliveryRow[] | null) ?? null, error: error ? { code: error.code, message: error.message } : null };
    },
    async markSent(id, result: SendResult) {
      const { error } = await service.rpc('invitation_mark_sent', { p_invitation_id: id, p_result: result });
      return { data: null, error: error ? { code: error.code, message: error.message } : null };
    },
    async inviteUserByEmail(email, redirectTo) {
      const { error } = await service.auth.admin.inviteUserByEmail(email, { redirectTo });
      return { error: error ? { status: error.status, code: error.code, message: error.message } : null };
    },
  };
  const forUser = (jwt: string): UserApi => {
    // Clave pública + JWT de quien llama: la base de datos aplica SUS permisos.
    const client = createClient(supabaseUrl, publicKey, {
      auth: noSession,
      global: { headers: { Authorization: `Bearer ${jwt}` } },
    });
    return {
      async getUser() {
        const { data, error } = await client.auth.getUser(jwt);
        if (error || !data.user) return null;
        return { id: data.user.id, isAnonymous: data.user.is_anonymous === true };
      },
      async rpc<T>(fn: UserRpc, args: Record<string, unknown>): Promise<RpcResult<T>> {
        const { data, error } = await client.rpc(fn, args);
        return { data: (data as T | null) ?? null, error: error ? { code: error.code, message: error.message } : null };
      },
    };
  };
  return createInvitationsHandler({
    config: { appUrl, allowedOrigins: parseOrigins(env('ALLOWED_ORIGINS'), appUrl), minResponseMs, retryDelayMs: 800 },
    forUser,
    admin,
    // Solo identificadores y códigos de error: nunca correos, JWT ni claves.
    log: (event, data) => console.log(JSON.stringify({ event, ...data })),
  });
}

Deno.serve(handler());
