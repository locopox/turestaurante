/**
 * Enlaces de Supabase Auth (recuperación de contraseña) y reglas de contraseña.
 * Funciones puras: no usan Supabase ni el navegador, para poder probarlas.
 */

export type AuthRedirect =
  | { kind: 'none' }
  /** Enlace de recuperación válido: Supabase abrirá una sesión y hay que pedir la contraseña nueva. */
  | { kind: 'recovery' }
  /** Enlace de invitación (cuenta nueva o sin confirmar): Supabase confirma el correo y abre una
   *  sesión; hay que pedir la contraseña antes de nada. NO da ningún permiso: la invitación se acepta
   *  después, de forma explícita. */
  | { kind: 'invite' }
  /** Enlace caducado, ya usado o rechazado. */
  | { kind: 'error'; code: string; message: string };

const EXPIRED_MESSAGE = 'El enlace ha caducado o ya se ha usado. Pide uno nuevo desde «¿Has olvidado tu contraseña?» o, si era una invitación, pide que te la reenvíen.';

/**
 * Lee la dirección con la que Supabase devuelve al usuario a la app tras pulsar el enlace del
 * correo. Con el flujo «implicit» (el predeterminado) los datos llegan tras el «#»:
 *   #access_token=…&refresh_token=…&type=recovery
 *   #error=access_denied&error_code=otp_expired&error_description=…
 * Los errores también pueden llegar en la parte «?…».
 */
export function parseAuthRedirect(hash: string, search = ''): AuthRedirect {
  const fromHash = new URLSearchParams(hash.replace(/^#/, ''));
  const fromSearch = new URLSearchParams(search.replace(/^\?/, ''));
  const pick = (key: string) => fromHash.get(key) ?? fromSearch.get(key);

  const errorCode = pick('error_code');
  const error = pick('error');
  if (errorCode || error) {
    const code = errorCode ?? error ?? 'error';
    const message = code === 'otp_expired' || error === 'access_denied'
      ? EXPIRED_MESSAGE
      : 'No se ha podido completar el enlace. Pide uno nuevo desde «¿Has olvidado tu contraseña?».';
    return { kind: 'error', code, message };
  }
  if (fromHash.get('type') === 'recovery' && fromHash.get('access_token')) return { kind: 'recovery' };
  if (fromHash.get('type') === 'invite' && fromHash.get('access_token')) return { kind: 'invite' };
  return { kind: 'none' };
}

/** Límites de la app. Supabase puede exigir más según la configuración del proyecto. */
export const PASSWORD_MIN = 8;
/** Supabase Auth guarda las contraseñas con bcrypt, que solo usa los primeros 72 bytes. */
export const PASSWORD_MAX_BYTES = 72;

export function validateNewPassword(password: string, repeat: string): string | null {
  if (password.trim().length === 0) return 'Escribe una contraseña nueva.';
  if (password.length < PASSWORD_MIN) return `La contraseña debe tener al menos ${PASSWORD_MIN} caracteres.`;
  if (new TextEncoder().encode(password).length > PASSWORD_MAX_BYTES) return 'La contraseña es demasiado larga (máximo 72 bytes).';
  if (password !== repeat) return 'Las dos contraseñas no coinciden.';
  return null;
}

/** Traduce los errores de Supabase Auth a mensajes comprensibles. */
export function friendlyAuthError(error: { message?: string; code?: string } | null | undefined): string {
  const code = error?.code ?? '';
  const message = error?.message ?? '';
  if (code === 'weak_password' || /weak|should be at least/i.test(message))
    return 'La contraseña es demasiado débil. Usa una más larga y que no sea fácil de adivinar.';
  if (code === 'same_password' || /different from the old/i.test(message))
    return 'La contraseña nueva debe ser distinta de la actual.';
  if (code === 'reauthentication_needed')
    return 'Por seguridad, vuelve a iniciar sesión antes de cambiar la contraseña.';
  if (code === 'over_email_send_rate_limit' || /rate limit/i.test(message))
    return 'Se han enviado demasiados correos. Espera unos minutos y vuelve a intentarlo.';
  if (code === 'session_not_found' || /session missing|not authenticated|JWT/i.test(message))
    return 'Tu sesión ha caducado. Pide un enlace nuevo o vuelve a iniciar sesión.';
  if (code === 'invalid_credentials' || /invalid login credentials/i.test(message))
    return 'Email o contraseña incorrectos.';
  if (/Failed to fetch|NetworkError|fetch failed/i.test(message)) return 'No hay conexión con el servidor. Inténtalo de nuevo.';
  return message || 'No se ha podido completar la operación.';
}

export type StaffGate = 'set-password' | 'loading' | 'login' | 'open';

/**
 * Qué mostrar según la sesión. Con una recuperación o una invitación pendiente de contraseña,
 * NADA del personal (panel, cocina, administración, invitaciones) es accesible hasta fijarla: la
 * sesión abierta por el enlace sirve solo para eso. Después, los permisos de cada rol se aplican
 * como siempre.
 */
export function staffGate(s: {
  isStaffView: boolean;
  requiresLogin: boolean;
  sessionLoading: boolean;
  hasSession: boolean;
  recoveryPending: boolean;
}): StaffGate {
  if (!s.requiresLogin) return 'open';
  if (s.recoveryPending && s.hasSession) return 'set-password';
  if (!s.isStaffView) return 'open';
  if (s.sessionLoading && !s.hasSession) return 'loading';
  if (!s.hasSession) return 'login';
  return 'open';
}
