import { defineConfig, devices } from '@playwright/test';

/**
 * Pruebas de navegador (Playwright).
 *  - «demo»: la app en modo demo (sin base de datos). `npm run test:e2e:demo`
 *  - «supabase-local»: la app contra Supabase LOCAL (CLI + Docker) con las Edge Functions servidas.
 *    En la carpeta del Supabase local: eval "$(supabase status -o env)", y después `npm run test:e2e:local`.
 *    Nunca contra un proyecto remoto: se comprueba que la URL sea local.
 * La app de «supabase-local» se sirve en http://127.0.0.1:5173: debe coincidir con APP_URL de la función
 * «invitations» y con las Redirect URLs de Supabase Auth.
 */
const local = (u?: string) => !!u && /^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?\/?$/.test(u);
const wantsLocal = process.argv.some((a) => a.includes('supabase-local'));
if (wantsLocal && !local(process.env.API_URL)) {
  throw new Error('API_URL debe ser un Supabase LOCAL (eval "$(supabase status -o env)"). Nunca un proyecto remoto.');
}

export default defineConfig({
  testDir: './e2e',
  testMatch: '**/*.e2e.ts',
  fullyParallel: false,
  workers: 1,
  timeout: 90_000,
  expect: { timeout: 15_000 },
  reporter: [['list']],
  use: { trace: 'retain-on-failure', ...devices['Desktop Chrome'] },
  projects: [
    { name: 'demo', testMatch: 'demo.e2e.ts', use: { baseURL: 'http://127.0.0.1:5174/' } },
    { name: 'supabase-local', testMatch: 'invitations.local.e2e.ts', use: { baseURL: 'http://127.0.0.1:5173/' } },
  ],
  webServer: [
    {
      command: 'npx vite --host 127.0.0.1 --port 5174 --strictPort',
      url: 'http://127.0.0.1:5174/',
      env: { VITE_DATA_BACKEND: 'mock' },
      reuseExistingServer: false,
    },
    ...(wantsLocal ? [{
      command: 'npx vite --host 127.0.0.1 --port 5173 --strictPort',
      url: 'http://127.0.0.1:5173/',
      env: { VITE_DATA_BACKEND: 'supabase', VITE_SUPABASE_URL: process.env.API_URL ?? '', VITE_SUPABASE_ANON_KEY: process.env.ANON_KEY ?? '' },
      reuseExistingServer: false,
    }] : []),
  ],
});
