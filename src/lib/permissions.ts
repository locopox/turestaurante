import type { StaffRole, StaffSession } from '../types';

/**
 * Permisos de la interfaz por rol. Solo deciden qué botones se muestran: quien manda de
 * verdad es la base de datos (RLS y funciones de supabase/schema.sql).
 */
export type Action =
  | 'orders.view'        // panel de pedidos
  | 'orders.prep'        // avanzar la preparación
  | 'orders.cancel'
  | 'orders.collect'     // marcar cobrado en caja
  | 'menu.edit'          // carta y precios
  | 'restaurant.edit'    // configuración del restaurante
  | 'restaurant.create'; // alta de restaurantes (solo administradores de plataforma)

const matrix: Record<StaffRole, Action[]> = {
  owner: ['orders.view', 'orders.prep', 'orders.cancel', 'orders.collect', 'menu.edit', 'restaurant.edit'],
  manager: ['orders.view', 'orders.prep', 'orders.cancel', 'orders.collect', 'menu.edit', 'restaurant.edit'],
  waiter: ['orders.view', 'orders.prep', 'orders.cancel', 'orders.collect'],
  kitchen: ['orders.prep'],
};

export function roleIn(session: StaffSession | null, restaurantId: string | undefined): StaffRole | null {
  if (!session || !restaurantId) return null;
  if (session.isPlatformAdmin) return 'owner';
  return session.memberships.find((m) => m.restaurantId === restaurantId)?.role ?? null;
}

export function can(session: StaffSession | null, restaurantId: string | undefined, action: Action): boolean {
  if (action === 'restaurant.create') return !!session?.isPlatformAdmin;
  const role = roleIn(session, restaurantId);
  return !!role && matrix[role].includes(action);
}

export const roleLabel: Record<StaffRole, string> = {
  owner: 'Propietario', manager: 'Encargado', waiter: 'Sala', kitchen: 'Cocina',
};
