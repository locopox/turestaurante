import { createSeed, type SeedDB } from '../../data/seed';
import { safeStorage, uid } from '../../lib/storage';
import type { Order, PaymentStatus } from '../../types';
import type { DataService, Menu } from '../dataService';

const KEY = 'turestaurante:demo-db:v1';
const CHANNEL = 'turestaurante:demo';

/**
 * Implementación en el navegador con datos ficticios.
 * Persiste en localStorage y sincroniza pestañas (cliente / panel / cocina)
 * mediante BroadcastChannel y el evento `storage`.
 */
export class MockDataService implements DataService {
  readonly kind = 'mock' as const;
  private db: SeedDB;
  private listeners = new Set<() => void>();
  private channel: BroadcastChannel | null = null;

  constructor() {
    this.db = safeStorage.get<SeedDB | null>(KEY, null) ?? createSeed();
    this.persist();
    const reload = () => {
      this.db = safeStorage.get<SeedDB | null>(KEY, null) ?? this.db;
      this.emit();
    };
    try {
      this.channel = new BroadcastChannel(CHANNEL);
      this.channel.onmessage = reload;
    } catch {
      this.channel = null;
    }
    window.addEventListener('storage', (e) => e.key === KEY && reload());
  }

  private persist() {
    safeStorage.set(KEY, this.db);
  }
  private emit() {
    this.listeners.forEach((l) => l());
  }
  private commit() {
    this.persist();
    this.emit();
    this.channel?.postMessage('changed');
  }
  private delay<T>(value: T): Promise<T> {
    // Simula la latencia de red para que la UI gestione estados de carga.
    return new Promise((r) => setTimeout(() => r(structuredClone(value)), 120));
  }
  private findOrder(id: string): Order {
    const o = this.db.orders.find((x) => x.id === id);
    if (!o) throw new Error('Pedido no encontrado');
    return o;
  }
  private touch(o: Order) {
    o.updatedAt = new Date().toISOString();
    this.commit();
    return this.delay(o);
  }

  async listRestaurants() {
    return this.delay([...this.db.restaurants].sort((a, b) => a.name.localeCompare(b.name, 'es')));
  }
  async getRestaurantBySlug(slug: string) {
    return this.delay(this.db.restaurants.find((r) => r.slug === slug) ?? null);
  }
  async createRestaurant(input: Parameters<DataService['createRestaurant']>[0]) {
    if (this.db.restaurants.some((r) => r.slug === input.slug)) throw new Error('Ya existe un restaurante con esa dirección web (slug).');
    const r = {
      tagline: '', address: '', phone: '', active: false, tables: 10, pickupEnabled: true,
      onlinePaymentEnabled: true, counterPaymentEnabled: true, prepMinutes: 15,
      ...input, id: uid('r-'), createdAt: new Date().toISOString(),
    };
    this.db.restaurants.push(r);
    this.db.counters[r.id] = 100;
    this.commit();
    return this.delay(r);
  }
  async saveRestaurant(restaurant: Parameters<DataService['saveRestaurant']>[0]) {
    if (this.db.restaurants.some((r) => r.slug === restaurant.slug && r.id !== restaurant.id))
      throw new Error('Ya existe un restaurante con esa dirección web (slug).');
    this.db.restaurants = this.db.restaurants.map((r) => (r.id === restaurant.id ? restaurant : r));
    this.commit();
    return this.delay(restaurant);
  }

  async getMenu(restaurantId: string): Promise<Menu> {
    return this.delay({
      categories: this.db.categories.filter((c) => c.restaurantId === restaurantId).sort((a, b) => a.sort - b.sort),
      products: this.db.products.filter((p) => p.restaurantId === restaurantId).sort((a, b) => a.sort - b.sort),
    });
  }
  async createCategory(restaurantId: string, name: string) {
    const sort = Math.max(0, ...this.db.categories.filter((c) => c.restaurantId === restaurantId).map((c) => c.sort)) + 1;
    const c = { id: uid('c-'), restaurantId, name, sort };
    this.db.categories.push(c);
    this.commit();
    return this.delay(c);
  }
  async createProduct(input: Parameters<DataService['createProduct']>[0]) {
    const sort = Math.max(0, ...this.db.products.map((p) => p.sort)) + 1;
    const product = { ...input, id: uid('p-'), sort };
    this.db.products.push(product);
    this.commit();
    return this.delay(product);
  }
  async saveProduct(product: Parameters<DataService['saveProduct']>[0]) {
    this.db.products = this.db.products.map((p) => (p.id === product.id ? product : p));
    this.commit();
    return this.delay(product);
  }

  async listOrders(restaurantId: string) {
    return this.delay(
      this.db.orders.filter((o) => o.restaurantId === restaurantId).sort((a, b) => b.createdAt.localeCompare(a.createdAt)),
    );
  }
  async getOrder(orderId: string) {
    return this.delay(this.db.orders.find((o) => o.id === orderId) ?? null);
  }
  async createOrder(input: Parameters<DataService['createOrder']>[0]) {
    const restaurant = this.db.restaurants.find((r) => r.id === input.restaurantId);
    if (!restaurant?.active) throw new Error('El restaurante no acepta pedidos en este momento.');
    if (!input.items.length) throw new Error('El pedido está vacío.');
    const items = input.items.map((line) => {
      const prod = this.db.products.find((p) => p.id === line.productId && p.restaurantId === restaurant.id);
      if (!prod || !prod.available) throw new Error('Algún producto ya no está disponible. Revisa tu carrito.');
      return { productId: prod.id, name: prod.name, unitPrice: prod.price, quantity: Math.max(1, Math.floor(line.quantity)), ...(line.notes ? { notes: line.notes } : {}) };
    });
    const number = (this.db.counters[restaurant.id] ?? 100) + 1;
    this.db.counters[restaurant.id] = number;
    const now = new Date().toISOString();
    const order: Order = {
      id: uid('o-'), restaurantId: restaurant.id, number, createdAt: now, updatedAt: now,
      mode: input.mode, table: input.mode === 'mesa' ? input.table ?? null : null,
      customerName: input.customerName?.trim() || null, customerPhone: input.customerPhone?.trim() || null,
      pickupTime: input.mode === 'recoger' ? input.pickupTime ?? 'asap' : null,
      items, notes: input.notes?.trim() ?? '',
      total: items.reduce((s, i) => s + i.unitPrice * i.quantity, 0),
      paymentMethod: input.paymentMethod,
      paymentStatus: input.paymentMethod === 'online' ? 'pendiente_online' : 'pendiente_caja',
      paymentRef: null, prepStatus: 'nuevo',
    };
    this.db.orders.push(order);
    this.commit();
    return this.delay(order);
  }
  async updatePrepStatus(orderId: string, status: Order['prepStatus']) {
    const o = this.findOrder(orderId);
    o.prepStatus = status;
    return this.touch(o);
  }
  async changePaymentMethod(orderId: string, method: Order['paymentMethod']) {
    const o = this.findOrder(orderId);
    o.paymentMethod = method;
    o.paymentStatus = method === 'caja' ? 'pendiente_caja' : 'pendiente_online';
    return this.touch(o);
  }
  async markPaidAtCounter(orderId: string) {
    const o = this.findOrder(orderId);
    o.paymentStatus = 'cobrado_caja';
    return this.touch(o);
  }
  async recordPaymentResult(orderId: string, status: PaymentStatus, ref: string | null) {
    if (status === 'pagado_verificado') throw new Error('Un pago verificado solo puede registrarlo el servidor.');
    const o = this.findOrder(orderId);
    o.paymentStatus = status;
    o.paymentRef = ref;
    return this.touch(o);
  }

  subscribeOrders(_restaurantId: string, onChange: () => void) {
    this.listeners.add(onChange);
    return () => void this.listeners.delete(onChange);
  }
  subscribeCatalog(onChange: () => void) {
    this.listeners.add(onChange);
    return () => void this.listeners.delete(onChange);
  }

  async resetDemo() {
    this.db = createSeed();
    this.commit();
  }
}
