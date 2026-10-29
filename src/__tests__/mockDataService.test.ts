import { beforeEach, describe, expect, it, vi } from 'vitest';
import { newAccessToken } from '../lib/orderRules';
import type { NewOrderInput } from '../types';

// Sin BroadcastChannel ni localStorage: el servicio funciona solo en memoria.
vi.stubGlobal('BroadcastChannel', undefined);
const { MockDataService } = await import('../services/mock/mockDataService');

const order = (over: Partial<NewOrderInput> = {}): NewOrderInput => ({
  restaurantId: 'r-piazza', mode: 'mesa', table: 5, paymentMethod: 'caja', accessToken: newAccessToken(),
  items: [{ productId: 'p-mar', quantity: 2 }], ...over,
});

describe('MockDataService (modo demo)', () => {
  let svc: InstanceType<typeof MockDataService>;
  beforeEach(() => {
    svc = new MockDataService();
  });

  it('crea el pedido con número y total calculados', async () => {
    const o = await svc.createOrder(order());
    expect(o).toMatchObject({ number: 106, total: 2100, paymentStatus: 'pendiente_caja', prepStatus: 'nuevo' });
  });
  it('es idempotente: el mismo token no duplica el pedido', async () => {
    const input = order();
    const a = await svc.createOrder(input);
    const b = await svc.createOrder({ ...input, items: [{ productId: 'p-agu', quantity: 9 }] });
    expect(b.id).toBe(a.id);
    expect((await svc.listOrders('r-piazza')).filter((o) => o.id === a.id)).toHaveLength(1);
  });
  it('el cliente solo lee su pedido con su token', async () => {
    const input = order();
    const o = await svc.createOrder(input);
    expect((await svc.getCustomerOrder(o.id, input.accessToken))?.id).toBe(o.id);
    expect(await svc.getCustomerOrder(o.id, newAccessToken())).toBeNull();
    expect(await svc.getCustomerOrder('o-demo-1', input.accessToken)).toBeNull();
  });
  it('un pedido online pendiente no puede pasar a cocina', async () => {
    const o = await svc.createOrder(order({ paymentMethod: 'online' }));
    await expect(svc.updatePrepStatus(o.id, 'en_preparacion')).rejects.toThrow('pendiente de pago online');
  });
  it('la pasarela simulada nunca marca un pago como verificado', async () => {
    const o = await svc.createOrder(order({ paymentMethod: 'online' }));
    await expect(svc.recordPaymentResult(o.id, 'pagado_verificado', 'x')).rejects.toThrow();
    expect((await svc.recordPaymentResult(o.id, 'simulado', 'sim_1')).paymentStatus).toBe('simulado');
  });
  it('el cliente puede pasar a pagar en caja solo con su token', async () => {
    const input = order({ paymentMethod: 'online' });
    const o = await svc.createOrder(input);
    await expect(svc.switchToCounterPayment(o.id, newAccessToken())).rejects.toThrow('no encontrado');
    expect((await svc.switchToCounterPayment(o.id, input.accessToken)).paymentStatus).toBe('pendiente_caja');
  });
  it('pasar a caja: rechazado con el restaurante inactivo', async () => {
    const input = order({ paymentMethod: 'online' });
    const o = await svc.createOrder(input);
    const [piazza] = (await svc.listRestaurants()).filter((r) => r.id === 'r-piazza');
    await svc.saveRestaurant({ ...piazza, active: false });
    await expect(svc.switchToCounterPayment(o.id, input.accessToken)).rejects.toThrow('no acepta pedidos');
  });
  it('pasar a caja: rechazado si el pedido tiene más de 2 horas', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    try {
      const input = order({ paymentMethod: 'online' });
      const o = await svc.createOrder(input);
      vi.setSystemTime(Date.now() + 2 * 60 * 60 * 1000 + 1000);
      await expect(svc.switchToCounterPayment(o.id, input.accessToken)).rejects.toThrow('caducado');
    } finally {
      vi.useRealTimers();
    }
  });
  it('no se cobra dos veces en caja', async () => {
    const o = await svc.createOrder(order());
    await svc.markPaidAtCounter(o.id);
    await expect(svc.markPaidAtCounter(o.id)).rejects.toThrow('no está pendiente');
  });
  it('no permite productos con categoría de otro restaurante', async () => {
    await expect(svc.createProduct({
      restaurantId: 'r-piazza', categoryId: 'c-sk-ram', name: 'X', description: '', price: 100, art: 'pizza',
      imageUrl: null, allergens: [], tags: [], available: true,
    })).rejects.toThrow('categoría');
  });
  it('conserva los pedidos de demostración', async () => {
    expect((await svc.listOrders('r-piazza')).map((o) => o.number)).toEqual(expect.arrayContaining([101, 102, 103, 104, 105]));
  });
});
