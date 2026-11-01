import { describe, expect, it } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { SupabaseDataService, type BrowserEnv } from '../services/supabase/supabaseDataService';

/** Cliente de Supabase simulado: registra las llamadas, no conecta con nada. */
function fakeClient(opts: { currentPassword?: string; updateError?: { message: string; code?: string }; resetError?: { message: string; code?: string } } = {}) {
  const listeners: ((event: string, session: unknown) => void)[] = [];
  const calls = { updateUser: [] as unknown[], signIn: [] as unknown[], signOut: [] as unknown[], reset: [] as unknown[] };
  const auth = {
    onAuthStateChange(cb: (event: string, session: unknown) => void) {
      listeners.push(cb);
      return { data: { subscription: { unsubscribe() {} } } };
    },
    async getSession() {
      return { data: { session: { user: { id: 'u1', email: 'admin@prueba.test' } } } };
    },
    async updateUser(attrs: unknown) {
      calls.updateUser.push(attrs);
      return opts.updateError ? { data: { user: null }, error: opts.updateError } : { data: { user: {} }, error: null };
    },
    async signInWithPassword(c: { email: string; password: string }) {
      calls.signIn.push(c);
      return c.password === (opts.currentPassword ?? 'actual-correcta')
        ? { data: {}, error: null }
        : { data: {}, error: { message: 'Invalid login credentials', code: 'invalid_credentials' } };
    },
    async signOut(o: unknown) {
      calls.signOut.push(o);
      return { error: null };
    },
    async resetPasswordForEmail(email: string, o: unknown) {
      calls.reset.push({ email, o });
      return { data: {}, error: opts.resetError ?? null };
    },
  };
  return {
    client: { auth } as unknown as SupabaseClient,
    calls,
    emit: (event: string, session: unknown) => listeners.forEach((l) => l(event, session)),
  };
}

function fakeEnv(hash = '', search = '') {
  const store = new Map<string, string>();
  const replaced: string[] = [];
  const env: BrowserEnv = {
    location: { hash, search, origin: 'http://localhost:5173', pathname: '/' },
    history: { state: null, replaceState: (_d, _u, url) => void replaced.push(String(url)) },
    storage: { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => void store.set(k, v), removeItem: (k) => void store.delete(k) },
  };
  return { env, store, replaced };
}

const tick = () => new Promise((r) => setTimeout(r, 0));
function service(hash = '', opts: Parameters<typeof fakeClient>[0] = {}) {
  const fc = fakeClient(opts);
  const fe = fakeEnv(hash);
  const svc = new SupabaseDataService('https://x.supabase.co', 'sb_publishable_prueba', { createClient: async () => fc.client, env: fe.env });
  return { svc, ...fc, ...fe };
}
const RECOVERY_HASH = '#access_token=abc&refresh_token=def&type=recovery';

describe('Recuperación de contraseña (Supabase, cliente simulado)', () => {
  it('un enlace de recuperación deja la recuperación pendiente', async () => {
    const { svc } = service(RECOVERY_HASH);
    await tick();
    expect(svc.isPasswordRecoveryPending()).toBe(true);
    expect(svc.getAuthRedirect()).toEqual({ kind: 'recovery' });
  });
  it('el evento PASSWORD_RECOVERY también la activa', async () => {
    const { svc, emit } = service('');
    await tick();
    expect(svc.isPasswordRecoveryPending()).toBe(false);
    emit('PASSWORD_RECOVERY', { user: {} });
    expect(svc.isPasswordRecoveryPending()).toBe(true);
  });
  it('si el enlace no llega a abrir sesión, no queda nada pendiente ni tokens en la dirección', async () => {
    const { svc, emit, replaced } = service(RECOVERY_HASH);
    await tick();
    emit('INITIAL_SESSION', null);
    expect(svc.isPasswordRecoveryPending()).toBe(false);
    expect(replaced).toEqual(['/']);
  });
  it('un enlace caducado muestra el aviso, limpia la dirección y no abre recuperación', async () => {
    const { svc, replaced } = service('#error=access_denied&error_code=otp_expired&error_description=expired');
    await tick();
    expect(svc.getAuthRedirect()).toMatchObject({ kind: 'error', code: 'otp_expired' });
    expect(svc.isPasswordRecoveryPending()).toBe(false);
    expect(replaced).toEqual(['/']);
    svc.dismissAuthRedirect();
    expect(svc.getAuthRedirect()).toEqual({ kind: 'none' });
  });
  it('fijar la contraseña nueva usa la sesión del usuario y termina la recuperación sin cerrar sesión', async () => {
    const { svc, calls } = service(RECOVERY_HASH);
    await svc.setNewPassword('una frase larga');
    expect(calls.updateUser).toEqual([{ password: 'una frase larga' }]);
    expect(svc.isPasswordRecoveryPending()).toBe(false);
    expect(calls.signOut).toEqual([]);
  });
  it('si Supabase rechaza la contraseña, la recuperación sigue pendiente', async () => {
    const { svc } = service(RECOVERY_HASH, { updateError: { message: 'New password should be different from the old password.', code: 'same_password' } });
    await expect(svc.setNewPassword('una frase larga')).rejects.toThrow('distinta');
    expect(svc.isPasswordRecoveryPending()).toBe(true);
  });
  it('rechaza contraseñas cortas sin llamar a Supabase', async () => {
    const { svc, calls } = service(RECOVERY_HASH);
    await expect(svc.setNewPassword('corta')).rejects.toThrow('al menos 8');
    expect(calls.updateUser).toEqual([]);
  });
  it('«Ahora no» cierra solo la sesión de este navegador y termina la recuperación', async () => {
    const { svc, calls } = service(RECOVERY_HASH);
    await svc.cancelPasswordRecovery();
    expect(calls.signOut).toEqual([{ scope: 'local' }]);
    expect(svc.isPasswordRecoveryPending()).toBe(false);
  });
  it('iniciar sesión con contraseña termina una recuperación obsoleta', async () => {
    const { svc } = service(RECOVERY_HASH);
    svc.getSession = async () => ({ userId: 'u1', email: 'a@b.test', isPlatformAdmin: false, memberships: [] });
    await svc.signIn('a@b.test', 'actual-correcta');
    expect(svc.isPasswordRecoveryPending()).toBe(false);
  });
});

describe('Cambio de contraseña con sesión (Supabase, cliente simulado)', () => {
  it('con la contraseña actual incorrecta no cambia nada ni cierra la sesión', async () => {
    const { svc, calls } = service('');
    await expect(svc.changePassword('incorrecta', 'una frase larga', false)).rejects.toThrow('actual no es correcta');
    expect(calls.updateUser).toEqual([]);
    expect(calls.signOut).toEqual([]);
  });
  it('con la contraseña actual correcta la cambia y no cierra ninguna sesión', async () => {
    const { svc, calls } = service('');
    await svc.changePassword('actual-correcta', 'una frase larga', false);
    expect(calls.signIn).toEqual([{ email: 'admin@prueba.test', password: 'actual-correcta' }]);
    expect(calls.updateUser).toEqual([{ password: 'una frase larga' }]);
    expect(calls.signOut).toEqual([]);
  });
  it('si el usuario lo pide, cierra solo las OTRAS sesiones', async () => {
    const { svc, calls } = service('');
    await svc.changePassword('actual-correcta', 'una frase larga', true);
    expect(calls.signOut).toEqual([{ scope: 'others' }]);
  });
});

describe('Envío del correo de recuperación', () => {
  it('pide a Supabase que el enlace vuelva a esta app', async () => {
    const { svc, calls } = service('');
    await svc.requestPasswordReset('  admin@prueba.test ');
    expect(calls.reset).toEqual([{ email: 'admin@prueba.test', o: { redirectTo: 'http://localhost:5173/' } }]);
  });
  it('valida el email y traduce el límite de envíos', async () => {
    const { svc, calls } = service('');
    await expect(svc.requestPasswordReset('no-es-un-email')).rejects.toThrow('email válido');
    expect(calls.reset).toEqual([]);
    const limited = service('', { resetError: { message: 'email rate limit exceeded', code: 'over_email_send_rate_limit' } });
    await expect(limited.svc.requestPasswordReset('a@b.test')).rejects.toThrow('demasiados correos');
  });
});
