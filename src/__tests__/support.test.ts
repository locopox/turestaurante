import { describe, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { auditActionLabel } from '../lib/audit';
import { can } from '../lib/permissions';
import { isSupportActive, remainingLabel } from '../lib/support';
import { SupabaseDataService } from '../services/supabase/supabaseDataService';
import type { StaffRole, StaffSession } from '../types';

vi.stubGlobal('BroadcastChannel', undefined);
const { MockDataService } = await import('../services/mock/mockDataService');

const staff = (role: StaffRole): StaffSession => ({ userId: 'u', email: 'u@x', isPlatformAdmin: false, memberships: [{ restaurantId: 'A', role }] });
const platform: StaffSession = { userId: 'p', email: 'p@x', isPlatformAdmin: true, memberships: [] };

describe('modo soporte: permisos de la interfaz', () => {
  it('solo la plataforma solicita; nunca aprueba', () => {
    expect(can(platform, 'A', 'support.request')).toBe(true);
    expect(can(platform, 'A', 'support.approve')).toBe(false);
  });
  it('solo el propietario aprueba; el encargado y el resto no', () => {
    expect(can(staff('owner'), 'A', 'support.approve')).toBe(true);
    for (const r of ['manager', 'waiter', 'kitchen'] as const) expect(can(staff(r), 'A', 'support.approve')).toBe(false);
    for (const r of ['owner', 'manager', 'waiter', 'kitchen'] as const) expect(can(staff(r), 'A', 'support.request')).toBe(false);
  });
  it('el propietario de un restaurante no aprueba soporte de otro', () => {
    expect(can(staff('owner'), 'B', 'support.approve')).toBe(false);
  });
});

describe('modo soporte: tiempo', () => {
  const now = Date.parse('2026-11-02T10:00:00Z');
  it('activo solo si está aprobado y no ha caducado', () => {
    expect(isSupportActive({ status: 'aprobada', expiresAt: '2026-11-02T11:00:00Z' }, now)).toBe(true);
    expect(isSupportActive({ status: 'aprobada', expiresAt: '2026-11-02T09:59:00Z' }, now)).toBe(false);
    expect(isSupportActive({ status: 'pendiente', expiresAt: null }, now)).toBe(false);
    expect(isSupportActive({ status: 'revocada', expiresAt: '2026-11-02T11:00:00Z' }, now)).toBe(false);
  });
  it('muestra el tiempo restante', () => {
    expect(remainingLabel('2026-11-02T12:00:00Z', now)).toBe('2 h 00 min');
    expect(remainingLabel('2026-11-02T10:12:30Z', now)).toBe('12 min');
    expect(remainingLabel('2026-11-02T10:00:20Z', now)).toBe('menos de 1 min');
  });
  it('el registro nombra cada paso del soporte', () => {
    for (const a of ['soporte.solicitud', 'soporte.aprobacion', 'soporte.rechazo', 'soporte.revocacion', 'soporte.consulta'])
      expect(auditActionLabel[a]).toBeTruthy();
  });
});

describe('modo soporte: servicio de Supabase (cliente simulado)', () => {
  function service(results: Record<string, unknown> = {}) {
    const calls: { fn: string; args: unknown }[] = [];
    const client = {
      auth: { onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }) },
      rpc: async (fn: string, args: unknown) => {
        calls.push({ fn, args });
        return { data: results[fn] ?? null, error: null };
      },
    } as unknown as SupabaseClient;
    return { svc: new SupabaseDataService('https://x.supabase.co', 'sb_publishable_x', { createClient: async () => client, env: null }), calls };
  }
  it('cada operación usa su función SQL (nunca tablas)', async () => {
    const { svc, calls } = service();
    await svc.requestSupport('A', '  Pedidos que no llegan  ');
    await svc.decideSupport('g1', true);
    await svc.revokeSupport('g1');
    await svc.cancelSupport('g2');
    await svc.supportViewOrders('A');
    await svc.supportViewPaymentEvents('A');
    await svc.supportViewRestaurant('A');
    expect(calls).toEqual([
      { fn: 'support_request', args: { p_restaurant_id: 'A', p_reason: 'Pedidos que no llegan' } },
      { fn: 'support_decide', args: { p_grant_id: 'g1', p_approve: true } },
      { fn: 'support_revoke', args: { p_grant_id: 'g1' } },
      { fn: 'support_cancel', args: { p_grant_id: 'g2' } },
      { fn: 'support_view_orders', args: { p_restaurant_id: 'A', p_limit: 50 } },
      { fn: 'support_view_payment_events', args: { p_restaurant_id: 'A', p_limit: 50 } },
      { fn: 'support_view_restaurant', args: { p_restaurant_id: 'A' } },
    ]);
  });
  it('convierte las solicitudes al formato de la app', async () => {
    const { svc } = service({ support_list_for_restaurant: [{ id: 'g1', requested_by_email: 'p@x', reason: 'Motivo largo', status: 'aprobada',
      requested_at: 'a', decided_at: 'b', decided_by_email: 'o@x', expires_at: 'c', revoked_at: null }] });
    expect(await svc.listSupportRequests('A')).toEqual([{ id: 'g1', restaurantId: null, restaurantName: null, requestedByEmail: 'p@x',
      reason: 'Motivo largo', status: 'aprobada', requestedAt: 'a', decidedAt: 'b', decidedByEmail: 'o@x', expiresAt: 'c', revokedAt: null }]);
  });
});

describe('modo soporte en la demo', () => {
  it('no está disponible (requiere cuentas reales separadas)', async () => {
    const svc = new MockDataService();
    await expect(svc.requestSupport()).rejects.toThrow('Supabase');
    await expect(svc.supportViewOrders()).rejects.toThrow('Supabase');
    expect(await svc.mySupportRequests()).toEqual([]);
  });
});
