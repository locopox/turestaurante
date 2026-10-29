const env = import.meta.env;

export const config = {
  dataBackend: env.VITE_DATA_BACKEND === 'supabase' ? 'supabase' : 'mock',
  supabaseUrl: (env.VITE_SUPABASE_URL ?? '').trim(),
  supabaseAnonKey: (env.VITE_SUPABASE_ANON_KEY ?? '').trim(),
  paymentProvider: 'simulado',
  publicBaseUrl: (env.VITE_PUBLIC_BASE_URL ?? 'https://turestaurante.app').replace(/\/$/, ''),
} as const;

/**
 * Pagos online: solo en el modo demo (pasarela simulada). Con Supabase quedan desactivados
 * hasta integrar un proveedor real con webhook verificado en el servidor.
 */
export const onlinePaymentsAvailable = config.dataBackend === 'mock';

export const isDemo = config.dataBackend === 'mock';

export interface ConfigIssue {
  blocking: boolean;
  message: string;
}

/** Lee el campo "role" de una clave JWT antigua de Supabase (anon / service_role). */
function jwtRole(key: string): string | null {
  const part = key.split('.')[1];
  if (!part) return null;
  try {
    const json = atob(part.replace(/-/g, '+').replace(/_/g, '/'));
    return (JSON.parse(json) as { role?: string }).role ?? null;
  } catch {
    return null;
  }
}

/** Revisa las variables de entorno. Exportada para poder probarla. */
export function checkConfig(e: Partial<ImportMetaEnv>): ConfigIssue[] {
  const issues: ConfigIssue[] = [];
  const backend = e.VITE_DATA_BACKEND;
  if (backend && backend !== 'mock' && backend !== 'supabase')
    issues.push({ blocking: true, message: `VITE_DATA_BACKEND="${backend}" no es válido. Usa "mock" o "supabase".` });

  if (e.VITE_PAYMENT_PROVIDER && e.VITE_PAYMENT_PROVIDER !== 'simulado')
    issues.push({ blocking: false, message: 'Los pagos reales todavía no están integrados: se ignora VITE_PAYMENT_PROVIDER y el pago online queda desactivado.' });

  if (backend !== 'supabase') return issues;

  const url = (e.VITE_SUPABASE_URL ?? '').trim();
  const key = (e.VITE_SUPABASE_ANON_KEY ?? '').trim();
  if (!url) issues.push({ blocking: true, message: 'Falta VITE_SUPABASE_URL (Project URL de Supabase, en Project Settings → API).' });
  else if (!/^https:\/\/[^/\s]+$/.test(url) && !/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(url))
    issues.push({ blocking: true, message: 'VITE_SUPABASE_URL debe tener la forma https://xxxx.supabase.co, sin rutas al final.' });

  if (!key) issues.push({ blocking: true, message: 'Falta VITE_SUPABASE_ANON_KEY (clave pública "anon" o "publishable").' });
  else if (key.startsWith('sb_secret_') || jwtRole(key) === 'service_role')
    issues.push({
      blocking: true,
      message: 'VITE_SUPABASE_ANON_KEY contiene una clave SECRETA. Nunca la pongas en la web: cualquiera podría leerla. Usa la clave pública y, si la secreta se ha publicado, regenérala en Supabase.',
    });
  else if (!key.startsWith('sb_publishable_') && jwtRole(key) !== 'anon')
    issues.push({ blocking: true, message: 'VITE_SUPABASE_ANON_KEY no parece una clave pública de Supabase ("anon" o "sb_publishable_…").' });

  return issues;
}

export const configIssues = checkConfig(env);
export const configBlocked = configIssues.some((i) => i.blocking);
