// Edge Function «invitations» (Deno, Supabase Edge Runtime). Solo crea los clientes y lee la
// configuración; la lógica está en ../_shared/invitations.ts. NO se ejecuta en el navegador: la clave secreta
// (SUPABASE_SERVICE_ROLE_KEY) existe solo aquí, en el servidor de Supabase.
//
// Variables (Supabase inyecta las tres primeras en sus Edge Functions; APP_URL hay que darla):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//   APP_URL          dirección fija de la app (destino del enlace del correo)
//   ALLOWED_ORIGINS  opcional: orígenes del navegador admitidos, separados por comas
//   SWEEP_LIMIT      opcional: entregas atrasadas que recupera cada llamada (1-10, por defecto 5)
//
// El correo se envía DESPUÉS de responder, con EdgeRuntime.waitUntil. waitUntil no garantiza que
// la tarea termine (la función puede detenerse por tiempo o por reinicio): por eso el estado de la
// entrega se guarda en la base de datos y la siguiente llamada recupera lo que quedó a medias.
import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import {
  createInvitationsHandler, parseAppUrl, parseOrigins,
  type AdminApi, type ClaimRow, type FinishResult, type RpcResult, type UserApi, type UserRpc,
} from '../_shared/invitations.ts';

const env = (k: string) => Deno.env.get(k)?.trim() || undefined;
const supabaseUrl = env('SUPABASE_URL');
const publicKey = env('SUPABASE_ANON_KEY');
const secretKey = env('SUPABASE_SERVICE_ROLE_KEY');
const appUrl = parseAppUrl(env('APP_URL'));
const sweepLimit = Number(env('SWEEP_LIMIT') ?? '5');

const noSession = { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false };

function misconfigured(): (req: Request) => Promise<Response> {
  // Falla cerrado: sin configuración completa no se invita a nadie.
  console.error(JSON.stringify({ event: 'configuracion_incompleta', supabaseUrl: !!supabaseUrl, publicKey: !!publicKey,
    secretKey: !!secretKey, appUrl: !!appUrl }));
  return async () => new Response(JSON.stringify({ ok: false, error: 'La función de invitaciones no está configurada' }),
    { status: 500, headers: { 'Content-Type': 'application/json; charset=utf-8' } });
}

function handler(): (req: Request) => Promise<Response> {
  if (!supabaseUrl || !publicKey || !secretKey || !appUrl || !Number.isInteger(sweepLimit) || sweepLimit < 1 || sweepLimit > 10) {
    return misconfigured();
  }
  const service = createClient(supabaseUrl, secretKey, { auth: noSession });
  // Lo ÚNICO que se hace con la clave secreta.
  const rpcError = (e: { code?: string; message?: string } | null) => (e ? { code: e.code, message: e.message } : null);
  const admin: AdminApi = {
    async claim(id) {
      const { data, error } = await service.rpc('invitation_delivery_claim', { p_invitation_id: id });
      return { data: (data as ClaimRow[] | null) ?? null, error: rpcError(error) };
    },
    async finish(id, claim, result: FinishResult) {
      const { data, error } = await service.rpc('invitation_delivery_finish', { p_invitation_id: id, p_claim: claim, p_result: result });
      return { data: (data as boolean | null) ?? null, error: rpcError(error) };
    },
    async pending(limit) {
      const { data, error } = await service.rpc('invitation_delivery_pending', { p_limit: limit });
      return { data: (data as string[] | null) ?? null, error: rpcError(error) };
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
        return { data: (data as T | null) ?? null, error: rpcError(error) };
      },
    };
  };
  return createInvitationsHandler({
    config: { appUrl, allowedOrigins: parseOrigins(env('ALLOWED_ORIGINS'), appUrl), sweepLimit },
    forUser,
    admin,
    background,
    // Solo identificadores y códigos de error: nunca correos, JWT ni claves.
    log: (event, data) => console.log(JSON.stringify({ event, ...data })),
  });
}

// Tarea en segundo plano: EdgeRuntime.waitUntil en Supabase. Fuera de Supabase (p. ej. `deno run`
// en local) la tarea sigue ejecutándose igualmente, sin esperar a que termine.
type EdgeRuntimeLike = { waitUntil(p: Promise<unknown>): void };
function background(task: Promise<void>): void {
  const runtime = (globalThis as { EdgeRuntime?: EdgeRuntimeLike }).EdgeRuntime;
  if (runtime && typeof runtime.waitUntil === 'function') runtime.waitUntil(task);
  else task.catch(() => {});
}

// Si el trabajador se detiene con tareas a medias, quedan registradas (la recuperación las retoma).
addEventListener('beforeunload', (ev) => {
  console.log(JSON.stringify({ event: 'apagado', reason: (ev as Event & { detail?: { reason?: string } }).detail?.reason ?? null }));
});

Deno.serve(handler());
