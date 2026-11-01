import { describe, expect, it } from 'vitest';
import { friendlyAuthError, parseAuthRedirect, staffGate, validateNewPassword } from '../lib/authRedirect';

describe('parseAuthRedirect (enlaces del correo)', () => {
  it('detecta un enlace de recuperación válido', () => {
    expect(parseAuthRedirect('#access_token=abc&expires_in=3600&refresh_token=def&token_type=bearer&type=recovery'))
      .toEqual({ kind: 'recovery' });
  });
  it('no confunde otros enlaces con una recuperación', () => {
    expect(parseAuthRedirect('#access_token=abc&type=magiclink')).toEqual({ kind: 'none' });
    expect(parseAuthRedirect('#access_token=abc&type=signup')).toEqual({ kind: 'none' });
    expect(parseAuthRedirect('#type=recovery')).toEqual({ kind: 'none' }); // sin token no hay sesión
    expect(parseAuthRedirect('#panel')).toEqual({ kind: 'none' });
    expect(parseAuthRedirect('')).toEqual({ kind: 'none' });
  });
  it('detecta un enlace caducado o ya usado', () => {
    const r = parseAuthRedirect('#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired');
    expect(r).toMatchObject({ kind: 'error', code: 'otp_expired' });
    expect(r.kind === 'error' && r.message).toContain('caducado');
  });
  it('detecta errores que llegan en la parte «?…»', () => {
    expect(parseAuthRedirect('', '?error=access_denied&error_code=otp_expired')).toMatchObject({ kind: 'error', code: 'otp_expired' });
  });
  it('un error tiene prioridad sobre cualquier token', () => {
    expect(parseAuthRedirect('#access_token=abc&type=recovery&error=server_error').kind).toBe('error');
  });
});

describe('validateNewPassword', () => {
  it('acepta una contraseña válida repetida igual', () => expect(validateNewPassword('una frase larga', 'una frase larga')).toBeNull());
  it('exige longitud mínima, que no esté vacía y que coincidan', () => {
    expect(validateNewPassword('', '')).toContain('Escribe');
    expect(validateNewPassword('        ', '        ')).toContain('Escribe');
    expect(validateNewPassword('corta', 'corta')).toContain('al menos 8');
    expect(validateNewPassword('una frase larga', 'otra frase')).toContain('no coinciden');
  });
  it('rechaza más de 72 bytes (límite de Supabase Auth)', () => {
    expect(validateNewPassword('ñ'.repeat(37), 'ñ'.repeat(37))).toContain('72');
  });
});

describe('friendlyAuthError', () => {
  it('traduce los códigos de Supabase Auth', () => {
    expect(friendlyAuthError({ code: 'weak_password' })).toContain('débil');
    expect(friendlyAuthError({ code: 'same_password' })).toContain('distinta');
    expect(friendlyAuthError({ code: 'reauthentication_needed' })).toContain('vuelve a iniciar sesión');
    expect(friendlyAuthError({ code: 'over_email_send_rate_limit' })).toContain('demasiados correos');
    expect(friendlyAuthError({ message: 'Auth session missing!' })).toContain('sesión ha caducado');
  });
});

describe('staffGate (qué puede verse durante una recuperación)', () => {
  const base = { isStaffView: true, requiresLogin: true, sessionLoading: false, hasSession: true, recoveryPending: false };
  it('con recuperación pendiente solo se puede fijar la contraseña, también en administración', () => {
    expect(staffGate({ ...base, recoveryPending: true })).toBe('set-password');
    expect(staffGate({ ...base, recoveryPending: true, isStaffView: false })).toBe('set-password');
  });
  it('una recuperación sin sesión no da acceso: pide iniciar sesión', () => {
    expect(staffGate({ ...base, recoveryPending: true, hasSession: false })).toBe('login');
  });
  it('sin recuperación, todo sigue igual', () => {
    expect(staffGate(base)).toBe('open');
    expect(staffGate({ ...base, hasSession: false })).toBe('login');
    expect(staffGate({ ...base, hasSession: false, sessionLoading: true })).toBe('loading');
    expect(staffGate({ ...base, hasSession: false, isStaffView: false })).toBe('open'); // vistas de cliente
  });
  it('el modo demo nunca pide contraseña', () => {
    expect(staffGate({ ...base, requiresLogin: false, recoveryPending: true })).toBe('open');
  });
});
