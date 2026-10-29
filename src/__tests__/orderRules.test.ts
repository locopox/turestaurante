import { describe, expect, it } from 'vitest';
import { createSeed } from '../data/seed';
import { canChangePrep, isValidAccessToken, newAccessToken, validateOrder } from '../lib/orderRules';
import type { NewOrderInput } from '../types';

const db = createSeed(0);
const piazza = db.restaurants.find((r) => r.id === 'r-piazza')!;
const base = (over: Partial<NewOrderInput> = {}): NewOrderInput => ({
  restaurantId: 'r-piazza', mode: 'mesa', table: 5, paymentMethod: 'caja', accessToken: newAccessToken(),
  items: [{ productId: 'p-mar', quantity: 2 }, { productId: 'p-agu', quantity: 1 }], ...over,
});
const check = (over: Partial<NewOrderInput>, r = piazza) => () => validateOrder(base(over), r, db.products);

describe('validateOrder', () => {
  it('acepta un pedido válido y calcula el total con los precios de la carta', () => {
    expect(validateOrder(base(), piazza, db.products).total).toBe(2 * 1050 + 220);
  });
  it('ignora precios enviados por el navegador', () => {
    const tampered = base({ items: [{ productId: 'p-mar', quantity: 1, price: 1 } as never] });
    expect(validateOrder(tampered, piazza, db.products).total).toBe(1050);
  });
  it('rechaza carrito vacío', () => expect(check({ items: [] })).toThrow('carrito está vacío'));
  it('rechaza cantidades inválidas', () => {
    for (const q of [0, 21, -1, 1.5, Number.NaN]) expect(check({ items: [{ productId: 'p-mar', quantity: q }] })).toThrow();
  });
  it('limita líneas y unidades', () => {
    expect(check({ items: Array.from({ length: 31 }, () => ({ productId: 'p-agu', quantity: 1 })) })).toThrow('30 productos');
    expect(check({ items: Array.from({ length: 6 }, () => ({ productId: 'p-agu', quantity: 20 })) })).toThrow('100 unidades');
  });
  it('rechaza producto agotado y producto de otro restaurante', () => {
    expect(check({ items: [{ productId: 'p-ver', quantity: 1 }] })).toThrow('agotado');
    expect(check({ items: [{ productId: 'p-sk-sho', quantity: 1 }] })).toThrow('no pertenece');
  });
  it('rechaza mesas inválidas', () => {
    for (const table of [0, 13, null, 2.5]) expect(check({ table })).toThrow(/mesa/);
  });
  it('recogida: exige nombre, valida teléfono y hora', () => {
    expect(check({ mode: 'recoger' })).toThrow('nombre');
    expect(check({ mode: 'recoger', customerName: 'A' })).toThrow('nombre');
    expect(check({ mode: 'recoger', customerName: 'Ana', customerPhone: 'llámame' })).toThrow('teléfono');
    expect(check({ mode: 'recoger', customerName: 'Ana', pickupTime: '25:00' })).toThrow('hora');
    const ok = validateOrder(base({ mode: 'recoger', customerName: ' Ana ', table: 3 }), piazza, db.products);
    expect(ok).toMatchObject({ customerName: 'Ana', pickupTime: 'asap', table: null });
  });
  it('respeta la configuración del restaurante', () => {
    expect(check({ mode: 'recoger', customerName: 'Ana' }, { ...piazza, pickupEnabled: false })).toThrow('para recoger');
    expect(check({ paymentMethod: 'online' }, { ...piazza, onlinePaymentEnabled: false })).toThrow('pago online');
    expect(check({}, { ...piazza, counterPaymentEnabled: false })).toThrow('pago en caja');
    expect(check({}, { ...piazza, active: false })).toThrow('no acepta pedidos');
  });
  it('limita textos y exige token', () => {
    expect(check({ notes: 'x'.repeat(201) })).toThrow('200');
    expect(check({ items: [{ productId: 'p-mar', quantity: 1, notes: 'x'.repeat(121) }] })).toThrow('120');
    expect(check({ accessToken: 'abc' })).toThrow('código de seguimiento');
  });
});

describe('tokens y transiciones', () => {
  it('genera tokens de 256 bits distintos', () => {
    const a = newAccessToken();
    expect(isValidAccessToken(a)).toBe(true);
    expect(a).not.toBe(newAccessToken());
  });
  it('solo permite cambios de preparación válidos', () => {
    expect(canChangePrep('nuevo', 'en_preparacion')).toBe(true);
    expect(canChangePrep('listo', 'en_preparacion')).toBe(true);
    expect(canChangePrep('nuevo', 'entregado')).toBe(false);
    expect(canChangePrep('cancelado', 'nuevo')).toBe(false);
    expect(canChangePrep('entregado', 'cancelado')).toBe(false);
  });
});
