import { describe, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { auditActionLabel } from '../lib/audit';
import { can } from '../lib/permissions';
import { denialReasonLabel, denialSummary, isSupportActive, remainingLabel, supportStatusLabel } from '../lib/support';
import { SupabaseDataService, SupportDeniedError, unwrapSupportResponse } from '../services/supabase/supabaseDataService';
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
  const ok = { ok: true, data: [] };
  it('cada operación usa su función SQL (nunca tablas)', async () => {
    const { svc, calls } = service({ support_view_orders: ok, support_view_payment_events: ok, support_view_restaurant: { ok: true, data: {} } });
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

describe('modo soporte: caducidad de solicitudes y consultas denegadas', () => {
  function service(results: Record<string, unknown>) {
    const calls: { fn: string; args: unknown }[] = [];
    const client = {
      auth: { onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }) },
      rpc: async (fn: string, args: unknown) => { calls.push({ fn, args }); return { data: results[fn] ?? null, error: null }; },
    } as unknown as SupabaseClient;
    return { svc: new SupabaseDataService('https://x.supabase.co', 'sb_publishable_x', { createClient: async () => client, env: null }), calls };
  }
  it('la solicitud caducada (24 h) se distingue del acceso caducado (2 h) y nunca está activa', () => {
    expect(supportStatusLabel.solicitud_caducada).toMatch(/24 h/);
    expect(supportStatusLabel.caducada).toMatch(/2 h/);
    expect(isSupportActive({ status: 'solicitud_caducada', expiresAt: null }, Date.now())).toBe(false);
  });
  it('una consulta permitida devuelve solo los datos', async () => {
    const { svc } = service({ support_view_orders: { ok: true, data: [{ id: 'o1' }] } });
    expect(await svc.supportViewOrders('A')).toEqual([{ id: 'o1' }]);
  });
  it('una consulta denegada lanza un error con el motivo y no devuelve datos', async () => {
    for (const reason of ['pendiente', 'solicitud_caducada', 'revocada', 'caducada', 'otro_restaurante', 'sin_solicitud'] as const) {
      const { svc } = service({ support_view_orders: { ok: false, reason, message: `motivo ${reason}` } });
      const err = await svc.supportViewOrders('A').catch((e) => e);
      expect(err).toBeInstanceOf(SupportDeniedError);
      expect(err.reason).toBe(reason);
      expect(err.message).toBe(`motivo ${reason}`);
    }
  });
  it('una respuesta sin «ok: true» nunca se trata como permitida', () => {
    for (const r of [null, undefined, {}, { data: [1] }, { ok: 'true', data: [1] }, { ok: false, data: [1] }])
      expect(() => unwrapSupportResponse(r)).toThrow(SupportDeniedError);
  });
  it('lista los intentos denegados con su función SQL y los convierte', async () => {
    const { svc, calls } = service({ support_denials_list: [{ first_at: 'a', last_at: 'b', actor_email: 'p@x', actor_kind: 'plataforma',
      restaurant_id: 'A', operation: 'pedidos', reason: 'revocada', attempts: 3 }] });
    expect(await svc.listSupportDenials('A')).toEqual([{ firstAt: 'a', lastAt: 'b', actorEmail: 'p@x', actorKind: 'plataforma',
      restaurantId: 'A', operation: 'pedidos', reason: 'revocada', attempts: 3 }]);
    await svc.listSupportDenials(null);
    expect(calls).toEqual([
      { fn: 'support_denials_list', args: { p_restaurant_id: 'A' } },
      { fn: 'support_denials_list', args: { p_restaurant_id: null } },
    ]);
  });
  it('describe cada motivo y resume los intentos', () => {
    for (const r of ['sin_sesion', 'no_es_plataforma', 'restaurante_inexistente', 'sin_solicitud', 'pendiente', 'solicitud_caducada',
      'rechazada', 'revocada', 'cancelada', 'caducada', 'otro_restaurante', 'limite_superado'] as const) expect(denialReasonLabel[r]).toBeTruthy();
    expect(denialSummary({ attempts: 1, operation: 'estado' })).toBe('1 intento de consultar estado del restaurante');
    expect(denialSummary({ attempts: 5, operation: 'pedidos' })).toBe('5 intentos de consultar pedidos');
  });
});

describe('modo soporte en la demo', () => {
  it('no está disponible (requiere cuentas reales separadas)', async () => {
    const svc = new MockDataService();
    await expect(svc.requestSupport()).rejects.toThrow('Supabase');
    await expect(svc.supportViewOrders()).rejects.toThrow('Supabase');
    expect(await svc.mySupportRequests()).toEqual([]);
    expect(await svc.listSupportDenials(null)).toEqual([]);
  });
});
