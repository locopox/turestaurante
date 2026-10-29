import { describe, expect, it } from 'vitest';
import { checkConfig } from '../config';
import { can, roleIn } from '../lib/permissions';
import type { StaffSession } from '../types';

const jwt = (role: string) => `x.${btoa(JSON.stringify({ role }))}.y`;
const supa = (key: string, url = 'https://abcd.supabase.co') =>
  checkConfig({ VITE_DATA_BACKEND: 'supabase', VITE_SUPABASE_URL: url, VITE_SUPABASE_ANON_KEY: key });

describe('checkConfig', () => {
  it('el modo demo no necesita variables', () => expect(checkConfig({})).toEqual([]));
  it('acepta claves públicas', () => {
    expect(supa('sb_publishable_abc')).toEqual([]);
    expect(supa(jwt('anon'))).toEqual([]);
  });
  it('bloquea si faltan URL o clave', () => {
    expect(supa('', '').filter((i) => i.blocking)).toHaveLength(2);
  });
  it('bloquea claves secretas', () => {
    expect(supa('sb_secret_abc')[0]).toMatchObject({ blocking: true, message: expect.stringContaining('SECRETA') });
    expect(supa(jwt('service_role'))[0]).toMatchObject({ blocking: true, message: expect.stringContaining('SECRETA') });
  });
  it('bloquea URL con forma incorrecta y backend desconocido', () => {
    expect(supa('sb_publishable_abc', 'abcd.supabase.co')[0].blocking).toBe(true);
    expect(checkConfig({ VITE_DATA_BACKEND: 'firebase' })[0].blocking).toBe(true);
  });
  it('avisa (sin bloquear) si se intenta activar pagos reales', () => {
    expect(checkConfig({ VITE_PAYMENT_PROVIDER: 'stripe' })[0]).toMatchObject({ blocking: false });
  });
});

describe('permisos por rol (interfaz)', () => {
  const s = (role: 'owner' | 'manager' | 'waiter' | 'kitchen'): StaffSession => ({
    userId: 'u', email: 'u@x', isPlatformAdmin: false, memberships: [{ restaurantId: 'A', role }],
  });
  it('cocina prepara pero no cobra, cancela ni edita la carta', () => {
    expect(can(s('kitchen'), 'A', 'orders.prep')).toBe(true);
    for (const a of ['orders.collect', 'orders.cancel', 'menu.edit', 'restaurant.edit', 'orders.view'] as const)
      expect(can(s('kitchen'), 'A', a)).toBe(false);
  });
  it('sala cobra y cancela, pero no edita la carta', () => {
    expect(can(s('waiter'), 'A', 'orders.collect')).toBe(true);
    expect(can(s('waiter'), 'A', 'menu.edit')).toBe(false);
  });
  it('nadie tiene permisos en un restaurante ajeno', () => {
    expect(roleIn(s('owner'), 'B')).toBeNull();
    expect(can(s('owner'), 'B', 'orders.view')).toBe(false);
    expect(can(s('owner'), 'A', 'restaurant.create')).toBe(false);
  });
});
