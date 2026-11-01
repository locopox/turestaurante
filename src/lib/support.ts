import type { SupportDenial, SupportDenialReason, SupportGrant, SupportStatus } from '../types';

export const supportStatusLabel: Record<SupportStatus, string> = {
  pendiente: 'Pendiente de aprobación',
  aprobada: 'Acceso activo',
  rechazada: 'Rechazada',
  revocada: 'Revocada',
  cancelada: 'Cancelada',
  caducada: 'Acceso caducado (2 h)',
  solicitud_caducada: 'Caducada sin respuesta (24 h)',
};

export const denialReasonLabel: Record<SupportDenialReason, string> = {
  sin_sesion: 'Sin sesión',
  no_es_plataforma: 'No es una cuenta de plataforma',
  restaurante_inexistente: 'Restaurante inexistente',
  sin_solicitud: 'Sin solicitud de soporte',
  pendiente: 'Solicitud aún sin aprobar',
  solicitud_caducada: 'Solicitud caducada (24 h)',
  rechazada: 'Solicitud rechazada',
  revocada: 'Acceso revocado',
  cancelada: 'Acceso cancelado',
  caducada: 'Acceso caducado (2 h)',
  otro_restaurante: 'Intento sobre otro restaurante',
  limite_superado: 'Demasiados intentos (agrupados)',
};

const operationLabel: Record<SupportDenial['operation'], string> = {
  estado: 'estado del restaurante', pedidos: 'pedidos', avisos_pago: 'avisos de pago', varias: 'varias consultas',
};

/** «3 intentos de consultar pedidos» */
export function denialSummary(d: Pick<SupportDenial, 'attempts' | 'operation'>): string {
  return `${d.attempts} ${d.attempts === 1 ? 'intento' : 'intentos'} de consultar ${operationLabel[d.operation] ?? d.operation}`;
}

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
