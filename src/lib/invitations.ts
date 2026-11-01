import type { Invitation, InvitationState, Restaurant, StaffRole, StaffSession } from '../types';
import { manageableRoles, roleIn, roleLabel } from './permissions';

/**
 * Reglas de la interfaz para las invitaciones (fase 6). Solo deciden qué se muestra: los límites y
 * permisos de verdad los aplica la base de datos (invitation_create / _resend / _revoke / _accept).
 * Los valores coinciden con supabase/schema.sql.
 */
export const INVITATION_DAYS = 7;
export const MAX_RESENDS = 3;
export const RESEND_WAIT_MS = 5 * 60 * 1000;

export const invitationStateLabel: Record<InvitationState, string> = {
  pendiente: 'Pendiente',
  aceptada: 'Aceptada',
  rechazada: 'Rechazada',
  revocada: 'Revocada',
  reemplazada: 'Reenviada (sustituida)',
  caducada: 'Caducada',
};

export const invitationStateTone: Record<InvitationState, 'ok' | 'warn' | 'danger' | 'neutral'> = {
  pendiente: 'warn', aceptada: 'ok', rechazada: 'neutral', revocada: 'danger', reemplazada: 'neutral', caducada: 'neutral',
};

/** Funciones a las que puede invitar quien ha iniciado sesión. Solo la plataforma invita propietarios. */
export function invitableRoles(session: StaffSession | null, restaurantId: string | undefined): StaffRole[] {
  return manageableRoles(session, restaurantId);
}

/** ¿Se puede reenviar ya? Si no, por qué (texto para el usuario). */
export function resendStatus(inv: Pick<Invitation, 'state' | 'canManage' | 'resendCount' | 'createdAt'>, now: number):
  { allowed: true } | { allowed: false; reason: string } {
  if (!inv.canManage) return { allowed: false, reason: 'No puedes gestionar esta invitación.' };
  if (inv.state === 'caducada') return { allowed: false, reason: 'Ha caducado: crea una invitación nueva.' };
  if (inv.state !== 'pendiente') return { allowed: false, reason: 'Ya no está pendiente.' };
  if (inv.resendCount >= MAX_RESENDS) return { allowed: false, reason: `Ya se ha reenviado ${MAX_RESENDS} veces. Revócala y crea una nueva si hace falta.` };
  const next = Date.parse(inv.createdAt) + RESEND_WAIT_MS;
  if (now < next) {
    const t = new Date(next).toLocaleTimeString('es-ES', { hour: '2-digit', minute: '2-digit' });
    return { allowed: false, reason: `Podrás reenviarla a partir de las ${t}.` };
  }
  return { allowed: true };
}

/** Lista para mostrar: sin las sustituidas por un reenvío (su sucesora ya aparece), las pendientes primero. */
export function visibleInvitations(list: Invitation[]): Invitation[] {
  const order: Record<InvitationState, number> = { pendiente: 0, caducada: 1, aceptada: 2, rechazada: 3, revocada: 4, reemplazada: 5 };
  return list
    .filter((i) => i.state !== 'reemplazada')
    .sort((a, b) => order[a.state] - order[b.state] || Date.parse(b.createdAt) - Date.parse(a.createdAt));
}

/** Texto bajo cada invitación. Nunca dice nada del correo (si se envió o si la persona tiene cuenta). */
export function invitationDetail(inv: Pick<Invitation, 'state' | 'expiresAt' | 'decidedAt' | 'resendCount' | 'invitedByLabel'>): string {
  const day = (iso: string) => new Date(iso).toLocaleString('es-ES', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
  const parts = [`Invitó: ${inv.invitedByLabel}`];
  if (inv.state === 'pendiente') parts.push(`caduca el ${day(inv.expiresAt)}`);
  if (inv.state === 'caducada') parts.push(`caducó el ${day(inv.expiresAt)}`);
  if (inv.decidedAt && ['aceptada', 'rechazada', 'revocada'].includes(inv.state)) parts.push(`${invitationStateLabel[inv.state].toLowerCase()} el ${day(inv.decidedAt)}`);
  if (inv.resendCount > 0) parts.push(`reenviada ${inv.resendCount} de ${MAX_RESENDS}`);
  return parts.join(' · ');
}

/** Lo que verá quien invita, sea cual sea el caso (no revela si la persona ya tiene cuenta). */
export const INVITE_HINT =
  'Si la persona ya tiene cuenta en TuRestaurante, verá la invitación al entrar; si no, recibirá un correo para crearla. ' +
  'No te diremos cuál de los dos casos es. Si no le llega, podrás reenviarla pasados 5 minutos.';

/** Resultado de cada intento de entrega (solo la plataforma lo ve, en el registro sin restaurante). */
export const deliveryResultLabel: Record<string, string> = {
  enviada: 'Correo enviado',
  no_necesario: 'Sin correo: ya tenía cuenta (la verá en la app)',
  reintento: 'Fallo temporal: se reintentará',
  fallida: 'No se pudo enviar',
};

// ---------- Selección del restaurante activo ----------

/**
 * Restaurantes entre los que puede elegir el usuario. En las vistas del personal, solo aquellos
 * donde tiene una función (cada uno con SUS permisos); la plataforma ve todos solo en Administración.
 */
export function selectableRestaurants(restaurants: Restaurant[], session: StaffSession | null,
  opts: { staffView: boolean; requiresLogin: boolean; adminView: boolean }): Restaurant[] {
  if (!opts.staffView || !opts.requiresLogin) return restaurants;
  return restaurants.filter((r) => roleIn(session, r.id) || (opts.adminView && session?.isPlatformAdmin));
}

/** Restaurante activo: el elegido si sigue disponible; si no, el primero. */
export function resolveSelected(selectable: Restaurant[], preferredId: string | null | undefined): Restaurant | undefined {
  return selectable.find((r) => r.id === preferredId) ?? selectable[0];
}

/** Texto de cada opción del selector: «La Piazza · Encargado». */
export function restaurantOptionLabel(r: Pick<Restaurant, 'id' | 'name'>, session: StaffSession | null): string {
  const role = roleIn(session, r.id);
  return role ? `${r.name} · ${roleLabel[role]}` : r.name;
}
