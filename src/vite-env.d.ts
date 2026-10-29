/// <reference types="vite/client" />
interface ImportMetaEnv {
  readonly VITE_DATA_BACKEND?: string;
  readonly VITE_SUPABASE_URL?: string;
  readonly VITE_SUPABASE_ANON_KEY?: string;
  readonly VITE_PAYMENT_PROVIDER?: string;
  readonly VITE_PUBLIC_BASE_URL?: string;
}
interface ImportMeta {
  readonly env: ImportMetaEnv;
}
