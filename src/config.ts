const env = import.meta.env;

export const config = {
  dataBackend: env.VITE_DATA_BACKEND === 'supabase' ? 'supabase' : 'mock',
  supabaseUrl: env.VITE_SUPABASE_URL ?? '',
  supabaseAnonKey: env.VITE_SUPABASE_ANON_KEY ?? '',
  paymentProvider: env.VITE_PAYMENT_PROVIDER === 'stripe' ? 'stripe' : 'simulado',
  publicBaseUrl: (env.VITE_PUBLIC_BASE_URL ?? 'https://turestaurante.app').replace(/\/$/, ''),
} as const;

export const isDemo = config.dataBackend === 'mock' || config.paymentProvider === 'simulado';
