import type { AuditEntry } from '../types';

/** Nombre legible de cada acción del registro de auditoría (supabase/schema.sql). */
export const auditActionLabel: Record<string, string> = {
  'personal.alta': 'Alta en el equipo',
  'personal.cambio_funcion': 'Cambio de función',
  'personal.baja': 'Baja del equipo',
  'carta.precio': 'Cambio de precio',
  'carta.alta_producto': 'Producto añadido',
  'carta.baja_producto': 'Producto retirado',
  'pedido.cancelacion': 'Pedido cancelado',
  'pedido.cobro_caja': 'Cobro en caja',
  'pedido.pasa_a_caja': 'El cliente pasa a pagar en caja',
  'pago.verificado': 'Pago online verificado',
  'restaurante.alta': 'Restaurante creado',
  'restaurante.suspension': 'Suspendido por la plataforma',
  'restaurante.reactivacion': 'Reactivado por la plataforma',
  'restaurante.slug': 'Dirección web cambiada',
  'restaurante.apertura': 'Abre o cierra pedidos',
  'restaurante.pago_online': 'Pago online activado o desactivado',
  'plataforma.consulta_equipo': 'La plataforma consultó el equipo',
  'plataforma.consulta_registro': 'La plataforma consultó el registro',
  'plataforma.alta_admin': 'Alta de administrador de plataforma',
  'plataforma.baja_admin': 'Baja de administrador de plataforma',
};

const actorKindLabel: Record<AuditEntry['actorKind'], string> = {
  plataforma: 'Plataforma', personal: 'Personal', cliente: 'Cliente', servidor: 'Servidor', sql_editor: 'SQL Editor',
};

/** Quién lo hizo: el email si lo hay; si no, el tipo (cliente, servidor, SQL Editor). */
export function auditActor(e: Pick<AuditEntry, 'actorEmail' | 'actorKind'>): string {
  const kind = actorKindLabel[e.actorKind] ?? e.actorKind;
  return e.actorEmail ? `${e.actorEmail} (${kind.toLowerCase()})` : kind;
}

/** Resumen de los detalles en una línea («antes: 1050 · después: 1100»). */
export function auditDetails(details: Record<string, unknown>): string {
  return Object.entries(details)
    .filter(([, v]) => v !== null && v !== '')
    .map(([k, v]) => `${k.replace(/_/g, ' ')}: ${typeof v === 'object' ? JSON.stringify(v) : String(v)}`)
    .join(' · ');
}
