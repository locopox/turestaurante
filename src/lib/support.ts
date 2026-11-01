import type { SupportGrant, SupportStatus } from '../types';

export const supportStatusLabel: Record<SupportStatus, string> = {
  pendiente: 'Pendiente de aprobación',
  aprobada: 'Acceso activo',
  rechazada: 'Rechazada',
  revocada: 'Revocada',
  cancelada: 'Cancelada',
  caducada: 'Caducada',
};

/** ¿Está activo ahora? La base de datos lo comprueba en cada consulta; esto solo es para la pantalla. */
export function isSupportActive(g: Pick<SupportGrant, 'status' | 'expiresAt'>, now = Date.now()): boolean {
  return g.status === 'aprobada' && !!g.expiresAt && new Date(g.expiresAt).getTime() > now;
}

/** Tiempo restante legible («1 h 05 min», «12 min», «menos de 1 min»). */
export function remainingLabel(expiresAt: string, now = Date.now()): string {
  const min = Math.floor((new Date(expiresAt).getTime() - now) / 60000);
  if (min < 1) return 'menos de 1 min';
  const h = Math.floor(min / 60);
  return h > 0 ? `${h} h ${String(min % 60).padStart(2, '0')} min` : `${min} min`;
}
