import { describe, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { createSeed } from '../data/seed';
import { auditActionLabel, auditActor, auditDetails } from '../lib/audit';
import { newAccessToken, validateOrder } from '../lib/orderRules';
import { can, canOpenAdmin, manageableRoles, roleIn } from '../lib/permissions';
import { SupabaseDataService } from '../services/supabase/supabaseDataService';
import type { StaffRole, StaffSession } from '../types';

vi.stubGlobal('BroadcastChannel', undefined);
const { MockDataService } = await import('../services/mock/mockDataService');

const staff = (role: StaffRole): StaffSession => ({ userId: 'u', email: 'u@x', isPlatformAdmin: false, memberships: [{ restaurantId: 'A', role }] });
const platform: StaffSession = { userId: 'p', email: 'p@x', isPlatformAdmin: true, memberships: [] };

describe('permisos de la interfaz (fase 3)', () => {
  it('la plataforma no tiene rol operativo en ningún restaurante', () => {
    expect(roleIn(platform, 'A')).toBeNull();
    for (const a of ['orders.view', 'orders.prep', 'orders.cancel', 'orders.collect', 'menu.edit'] as const)
      expect(can(platform, 'A', a)).toBe(false);
  });
  it('la plataforma administra restaurantes, propietarios, suspensión y registro', () => {
    for (const a of ['restaurant.create', 'platform.manage', 'restaurant.edit', 'staff.manage', 'audit.view'] as const)
      expect(can(platform, 'A', a)).toBe(true);
    expect(manageableRoles(platform, 'A')).toEqual(['owner', 'manager', 'waiter', 'kitchen']);
  });
  it('owner: todo en su restaurante salvo funciones de plataforma; gestiona encargados, sala y cocina', () => {
    expect(can(staff('owner'), 'A', 'restaurant.edit')).toBe(true);
    expect(can(staff('owner'), 'A', 'audit.view')).toBe(true);
    expect(can(staff('owner'), 'A', 'platform.manage')).toBe(false);
    expect(manageableRoles(staff('owner'), 'A')).toEqual(['manager', 'waiter', 'kitchen']);
  });
  it('manager: carta, pedidos, caja y equipo de sala/cocina; no configuración ni registro', () => {
    const m = staff('manager');
    for (const a of ['menu.edit', 'orders.view', 'orders.collect', 'orders.cancel', 'staff.manage'] as const) expect(can(m, 'A', a)).toBe(true);
    for (const a of ['restaurant.edit', 'audit.view', 'platform.manage', 'restaurant.create'] as const) expect(can(m, 'A', a)).toBe(false);
    expect(manageableRoles(m, 'A')).toEqual(['waiter', 'kitchen']);
    expect(canOpenAdmin(m, 'A')).toBe(true);
  });
  it('sala y cocina no gestionan equipo ni abren administración', () => {
    for (const r of ['waiter', 'kitchen'] as const) {
      expect(manageableRoles(staff(r), 'A')).toEqual([]);
      expect(canOpenAdmin(staff(r), 'A')).toBe(false);
    }
  });
  it('nadie tiene permisos en otro restaurante', () => {
    expect(can(staff('owner'), 'B', 'orders.view')).toBe(false);
    expect(manageableRoles(staff('owner'), 'B')).toEqual([]);
    expect(canOpenAdmin(staff('manager'), 'B')).toBe(false);
  });
});

describe('suspensión', () => {
  const db = createSeed(0);
  const piazza = db.restaurants.find((r) => r.id === 'r-piazza')!;
  const input = { restaurantId: 'r-piazza', mode: 'mesa' as const, table: 1, paymentMethod: 'caja' as const, accessToken: newAccessToken(), items: [{ productId: 'p-mar', quantity: 1 }] };
  it('un restaurante suspendido no acepta pedidos aunque esté abierto', () => {
    expect(() => validateOrder(input, { ...piazza, active: true, suspended: true }, db.products)).toThrow('no acepta pedidos');
  });
  it('modo demo: suspender bloquea pedidos y guardar el formulario no la levanta', async () => {
    const svc = new MockDataService();
    await svc.setRestaurantSuspension('r-piazza', true, 'Prueba');
    await expect(svc.createOrder({ ...input, accessToken: newAccessToken() })).rejects.toThrow('no acepta pedidos');
    const [r] = (await svc.listRestaurants()).filter((x) => x.id === 'r-piazza');
    await svc.saveRestaurant({ ...r, suspended: false, active: true });
    expect((await svc.listRestaurants()).find((x) => x.id === 'r-piazza')?.suspended).toBe(true);
    await expect(svc.setRestaurantSuspension('r-piazza', true, '')).rejects.toThrow('motivo');
  });
});

describe('cocina sin datos personales (modo demo)', () => {
  it('las comandas no incluyen teléfono, importes ni pago, ni pedidos online pendientes', async () => {
    const svc = new MockDataService();
    const pend = await svc.createOrder({ restaurantId: 'r-piazza', mode: 'recoger', customerName: 'Eva', customerPhone: '600 111 222', paymentMethod: 'online', accessToken: newAccessToken(), items: [{ productId: 'p-mar', quantity: 1 }] });
    const tickets = await svc.listKitchenOrders('r-piazza');
    expect(tickets.length).toBeGreaterThan(0);
    for (const t of tickets) {
      expect(Object.keys(t)).not.toEqual(expect.arrayContaining(['customerPhone']));
      expect(t).not.toHaveProperty('total');
      expect(t).not.toHaveProperty('paymentStatus');
    }
    expect(tickets.some((t) => t.id === pend.id)).toBe(false);
    const pickup = tickets.find((t) => t.mode === 'recoger');
    expect(pickup?.customerName).toBeTruthy();
    expect(tickets.filter((t) => t.mode === 'mesa').every((t) => t.customerName === null)).toBe(true);
  });
  it('la demo sigue siendo plataforma y owner de todos los restaurantes', async () => {
    const s = await new MockDataService().getSession();
    expect(s.isPlatformAdmin).toBe(true);
    expect(s.memberships.map((m) => m.role)).toEqual(['owner', 'owner', 'owner']);
  });
});

describe('servicio de Supabase: funciones de equipo, cocina y plataforma (cliente simulado)', () => {
  function service(results: Record<string, unknown> = {}) {
    const calls: { fn: string; args: unknown }[] = [];
    const client = {
      auth: { onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }) },
      rpc: async (fn: string, args: unknown) => {
        calls.push({ fn, args });
        return { data: results[fn] ?? null, error: null };
      },
    } as unknown as SupabaseClient;
    const svc = new SupabaseDataService('https://x.supabase.co', 'sb_publishable_x', { createClient: async () => client, env: null });
    return { svc, calls };
  }
  it('gestiona el equipo solo con las funciones staff_* (nunca escribe la tabla) y sin altas directas', async () => {
    const { svc, calls } = service();
    await svc.changeStaffRole('A', 'u2', 'kitchen');
    await svc.removeStaff('A', 'u2');
    expect(calls).toEqual([
      { fn: 'staff_change_role', args: { p_restaurant_id: 'A', p_user_id: 'u2', p_role: 'kitchen' } },
      { fn: 'staff_remove_member', args: { p_restaurant_id: 'A', p_user_id: 'u2' } },
    ]);
    // Fase 6: ya no existe ninguna forma de añadir a alguien sin invitación aceptada.
    expect('addStaff' in svc).toBe(false);
  });
  it('la cocina usa kitchen_orders y la suspensión platform_set_suspension', async () => {
    const { svc, calls } = service({ kitchen_orders: [{ id: 'o1', number: 101, createdAt: 'x', mode: 'mesa', table: 3, prepStatus: 'nuevo', notes: '', items: [{ name: 'Pizza', quantity: 2 }] }] });
    const t = await svc.listKitchenOrders('A');
    expect(t[0]).toMatchObject({ number: 101, table: 3, customerName: null, items: [{ name: 'Pizza', quantity: 2 }] });
    await svc.setRestaurantSuspension('A', true, 'Impago');
    expect(calls.map((c) => c.fn)).toEqual(['kitchen_orders', 'platform_set_suspension']);
  });
});

describe('registro de auditoría (textos)', () => {
  it('traduce acciones, autor y detalles', () => {
    expect(auditActionLabel['pedido.cobro_caja']).toBe('Cobro en caja');
    expect(auditActor({ actorEmail: 'a@b.test', actorKind: 'personal' })).toBe('a@b.test (personal)');
    expect(auditActor({ actorEmail: null, actorKind: 'sql_editor' })).toBe('SQL Editor');
    expect(auditDetails({ antes: 1050, despues: 1100, vacio: '' })).toBe('antes: 1050 · despues: 1100');
  });
});
