// Edge Function «invitations-recovery» (Deno, Supabase Edge Runtime): recuperación PROGRAMADA de
// entregas de invitaciones atrasadas o interrumpidas. La llama cada 5 minutos la tarea de pg_cron
// (con pg_net) definida en supabase/migrations/20261105120000_fase6_recuperacion_programada.sql.
//
// Autenticación de servidor: cabecera «x-turestaurante-recovery» con un secreto propio (no es la
// clave secreta de Supabase). La función lo lee de INVITATIONS_RECOVERY_SECRET (secreto de Edge
// Functions) y la base de datos, de Supabase Vault. Sin él, la función no hace nada. No acepta JWT
// de usuarios: se despliega con verify_jwt = false porque la tarea no tiene sesión.
//
// Variables: SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY (las pone Supabase), APP_URL (la misma que la
// función «invitations»), INVITATIONS_RECOVERY_SECRET y, opcional, RECOVERY_LIMIT (1-10, por defecto 10).
import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import { createRecoveryHandler, parseAppUrl, type AdminApi, type ClaimRow, type FinishResult } from '../_shared/invitations.ts';

const env = (k: string) => Deno.env.get(k)?.trim() || undefined;
const supabaseUrl = env('SUPABASE_URL');
const secretKey = env('SUPABASE_SERVICE_ROLE_KEY');
const appUrl = parseAppUrl(env('APP_URL'));
const limit = Number(env('RECOVERY_LIMIT') ?? '10');

function handler(): (req: Request) => Promise<Response> {
  if (!supabaseUrl || !secretKey || !appUrl || !Number.isInteger(limit) || limit < 1 || limit > 10) {
    console.error(JSON.stringify({ event: 'configuracion_incompleta', supabaseUrl: !!supabaseUrl, secretKey: !!secretKey, appUrl: !!appUrl }));
    return async () => new Response(JSON.stringify({ ok: false, error: 'La recuperación no está configurada' }),
      { status: 500, headers: { 'Content-Type': 'application/json; charset=utf-8' } });
  }
  const service = createClient(supabaseUrl, secretKey, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } });
  const rpcError = (e: { code?: string; message?: string } | null) => (e ? { code: e.code, message: e.message } : null);
  // Lo ÚNICO que se hace con la clave secreta (lo mismo que en «invitations»).
  const admin: AdminApi = {
    async claim(id) {
      const { data, error } = await service.rpc('invitation_delivery_claim', { p_invitation_id: id });
      return { data: (data as ClaimRow[] | null) ?? null, error: rpcError(error) };
    },
    async finish(id, claim, result: FinishResult) {
      const { data, error } = await service.rpc('invitation_delivery_finish', { p_invitation_id: id, p_claim: claim, p_result: result });
      return { data: (data as boolean | null) ?? null, error: rpcError(error) };
    },
    async pending(n) {
      const { data, error } = await service.rpc('invitation_delivery_pending', { p_limit: n });
      return { data: (data as string[] | null) ?? null, error: rpcError(error) };
    },
    async inviteUserByEmail(email, redirectTo) {
      const { error } = await service.auth.admin.inviteUserByEmail(email, { redirectTo });
      return { error: error ? { status: error.status, code: error.code, message: error.message } : null };
    },
  };
  return createRecoveryHandler({
    secret: env('INVITATIONS_RECOVERY_SECRET') ?? null,
    admin,
    appUrl,
    limit,
    // Solo identificadores, recuentos y códigos de error: nunca correos, el secreto ni claves.
    log: (event, data) => console.log(JSON.stringify({ event, ...data })),
  });
}

Deno.serve(handler());
