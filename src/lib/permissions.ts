import type { StaffRole, StaffSession } from '../types';

/**
 * Permisos de la interfaz por rol. Solo deciden qué botones se muestran: quien manda de
 * verdad es la base de datos (RLS y funciones de supabase/schema.sql).
 *
 * La cuenta de plataforma NO tiene rol operativo en los restaurantes: administra restaurantes,
 * propietarios y suspensiones, pero no ve pedidos, cocina ni carta (modo soporte: fase posterior).
 */
export type Action =
  | 'orders.view'        // panel de pedidos
  | 'orders.prep'        // avanzar la preparación (pantalla de cocina)
  | 'orders.cancel'
  | 'orders.collect'     // marcar cobrado en caja
  | 'menu.edit'          // carta y precios
  | 'restaurant.edit'    // configuración del restaurante (solo owner y plataforma)
  | 'staff.manage'       // equipo (owner: manager/sala/cocina · manager: sala/cocina · plataforma: todos)
  | 'audit.view'         // registro de auditoría (owner y plataforma)
  | 'restaurant.create'  // alta de restaurantes (plataforma)
  | 'platform.manage';   // dirección web (slug) y suspensión (plataforma)

const matrix: Record<StaffRole, Action[]> = {
  owner: ['orders.view', 'orders.prep', 'orders.cancel', 'orders.collect', 'menu.edit', 'restaurant.edit', 'staff.manage', 'audit.view'],
  manager: ['orders.view', 'orders.prep', 'orders.cancel', 'orders.collect', 'menu.edit', 'staff.manage'],
  waiter: ['orders.view', 'orders.prep', 'orders.cancel', 'orders.collect'],
  kitchen: ['orders.prep'],
};

/** Acciones que la plataforma puede hacer en cualquier restaurante (ninguna es operativa). */
const platformActions: Action[] = ['restaurant.create', 'platform.manage', 'restaurant.edit', 'staff.manage', 'audit.view'];

/** Rol del usuario en el restaurante, solo por pertenencia. La plataforma no tiene rol. */
export function roleIn(session: StaffSession | null, restaurantId: string | undefined): StaffRole | null {
  if (!session || !restaurantId) return null;
  return session.memberships.find((m) => m.restaurantId === restaurantId)?.role ?? null;
}

export function can(session: StaffSession | null, restaurantId: string | undefined, action: Action): boolean {
  if (session?.isPlatformAdmin && platformActions.includes(action)) return true;
  if (action === 'restaurant.create' || action === 'platform.manage') return false;
  const role = roleIn(session, restaurantId);
  return !!role && matrix[role].includes(action);
}

/** Funciones que el usuario puede asignar, cambiar o quitar en ese restaurante. */
export function manageableRoles(session: StaffSession | null, restaurantId: string | undefined): StaffRole[] {
  if (session?.isPlatformAdmin) return ['owner', 'manager', 'waiter', 'kitchen'];
  const role = roleIn(session, restaurantId);
  if (role === 'owner') return ['manager', 'waiter', 'kitchen'];
  if (role === 'manager') return ['waiter', 'kitchen'];
  return [];
}

/** ¿Tiene algo que hacer en la pantalla de administración de ese restaurante? */
export function canOpenAdmin(session: StaffSession | null, restaurantId: string | undefined): boolean {
  return (['restaurant.edit', 'menu.edit', 'staff.manage', 'audit.view'] as Action[]).some((a) => can(session, restaurantId, a));
}

export const roleLabel: Record<StaffRole, string> = {
  owner: 'Propietario', manager: 'Encargado', waiter: 'Sala', kitchen: 'Cocina',
};
