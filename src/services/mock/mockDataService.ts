import { createSeed, type SeedDB } from '../../data/seed';
import { canChangePrep, OrderRuleError, validateOrder } from '../../lib/orderRules';
import { safeStorage, uid } from '../../lib/storage';
import type { Order, PaymentStatus, StaffSession } from '../../types';
import type { DataService, Menu } from '../dataService';

const KEY = 'turestaurante:demo-db:v1';
const CHANNEL = 'turestaurante:demo';

/** Tokens de seguimiento de los clientes (token → id de pedido). Los datos antiguos no lo tienen. */
type MockDB = SeedDB & { access?: Record<string, string> };

/** En la demo no hay inicio de sesión: se actúa como administrador de la plataforma. */
const DEMO_SESSION: StaffSession = {
  userId: 'demo', email: 'demo@turestaurante.app', isPlatformAdmin: true, memberships: [],
};

/**
 * Implementación en el navegador con datos ficticios.
 * Persiste en localStorage y sincroniza pestañas (cliente / panel / cocina)
 * mediante BroadcastChannel y el evento `storage`.
 * Aplica las mismas reglas que la base de datos (lib/orderRules.ts).
 */
export class MockDataService implements DataService {
  readonly kind = 'mock' as const;
  readonly requiresLogin = false;
  private db: MockDB;
  private listeners = new Set<() => void>();
  private channel: BroadcastChannel | null = null;

  constructor() {
    this.db = safeStorage.get<MockDB | null>(KEY, null) ?? createSeed();
    this.persist();
    const reload = () => {
      this.db = safeStorage.get<MockDB | null>(KEY, null) ?? this.db;
      this.emit();
    };
    try {
      this.channel = new BroadcastChannel(CHANNEL);
      this.channel.onmessage = reload;
    } catch {
      this.channel = null;
    }
    if (typeof window !== 'undefined') window.addEventListener('storage', (e) => e.key === KEY && reload());
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
  }
  private orderByToken(orderId: string, token: string): Order | null {
    return this.db.access?.[token] === orderId ? this.db.orders.find((o) => o.id === orderId) ?? null : null;
  }

  // Sesión
  async getSession() {
    return DEMO_SESSION;
  }
  async signIn() {
    return DEMO_SESSION;
  }
  async signOut() {}
  onAuthChange() {
    return () => {};
  }

  // Restaurantes
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

  // Carta
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
    const category = this.db.categories.find((c) => c.id === input.categoryId);
    if (category?.restaurantId !== input.restaurantId) throw new Error('La categoría no pertenece a este restaurante.');
    const sort = Math.max(0, ...this.db.products.map((p) => p.sort)) + 1;
    const product = { ...input, id: uid('p-'), sort };
    this.db.products.push(product);
    this.commit();
    return this.delay(product);
  }
  async saveProduct(product: Parameters<DataService['saveProduct']>[0]) {
    const category = this.db.categories.find((c) => c.id === product.categoryId);
    if (category?.restaurantId !== product.restaurantId) throw new Error('La categoría no pertenece a este restaurante.');
    this.db.products = this.db.products.map((p) => (p.id === product.id ? product : p));
    this.commit();
    return this.delay(product);
  }

  // Cliente
  async createOrder(input: Parameters<DataService['createOrder']>[0]) {
    const access = (this.db.access ??= {});
    // Reintento con el mismo token: devuelve el pedido ya creado.
    const existingId = access[input.accessToken];
    if (existingId) {
      const existing = this.db.orders.find((o) => o.id === existingId);
      if (existing && existing.restaurantId === input.restaurantId) return this.delay(existing);
      throw new Error('Código de seguimiento no válido');
    }
    const restaurant = this.db.restaurants.find((r) => r.id === input.restaurantId);
    let v: ReturnType<typeof validateOrder>;
    try {
      v = validateOrder(input, restaurant, this.db.products);
    } catch (e) {
      if (e instanceof OrderRuleError) throw new Error(e.message);
      throw e;
    }
    const number = (this.db.counters[restaurant!.id] ?? 100) + 1;
    this.db.counters[restaurant!.id] = number;
    const now = new Date().toISOString();
    const order: Order = {
      id: uid('o-'), restaurantId: restaurant!.id, number, createdAt: now, updatedAt: now,
      mode: input.mode, table: v.table, customerName: v.customerName, customerPhone: v.customerPhone,
      pickupTime: v.pickupTime, notes: v.notes,
      items: v.lines.map((l) => ({ productId: l.product.id, name: l.product.name, unitPrice: l.product.price, quantity: l.quantity, ...(l.notes ? { notes: l.notes } : {}) })),
      total: v.total,
      paymentMethod: input.paymentMethod,
      paymentStatus: input.paymentMethod === 'online' ? 'pendiente_online' : 'pendiente_caja',
      paymentRef: null, prepStatus: 'nuevo',
    };
    this.db.orders.push(order);
    access[input.accessToken] = order.id;
    this.commit();
    return this.delay(order);
  }
  async getCustomerOrder(orderId: string, accessToken: string) {
    return this.delay(this.orderByToken(orderId, accessToken));
  }
  subscribeCustomerOrder(_orderId: string, _accessToken: string, onChange: () => void) {
    this.listeners.add(onChange);
    return () => void this.listeners.delete(onChange);
  }
  async switchToCounterPayment(orderId: string, accessToken: string) {
    const o = this.orderByToken(orderId, accessToken);
    if (!o) throw new Error('Pedido no encontrado');
    if (o.paymentMethod !== 'online' || !['pendiente_online', 'fallido'].includes(o.paymentStatus) || o.prepStatus !== 'nuevo')
      throw new Error('Este pedido ya no puede cambiar de método de pago');
    o.paymentMethod = 'caja';
    o.paymentStatus = 'pendiente_caja';
    this.touch(o);
    return this.delay(o);
  }

  // Personal
  async listOrders(restaurantId: string) {
    return this.delay(
      this.db.orders.filter((o) => o.restaurantId === restaurantId).sort((a, b) => b.createdAt.localeCompare(a.createdAt)),
    );
  }
  async updatePrepStatus(orderId: string, status: Order['prepStatus']) {
    const o = this.findOrder(orderId);
    if (!canChangePrep(o.prepStatus, status)) throw new Error('Cambio de estado no permitido');
    if (status !== 'cancelado' && (o.paymentStatus === 'pendiente_online' || o.paymentStatus === 'fallido'))
      throw new Error('El pedido está pendiente de pago online y no puede pasar a cocina');
    o.prepStatus = status;
    this.touch(o);
  }
  async markPaidAtCounter(orderId: string) {
    const o = this.findOrder(orderId);
    if (o.paymentStatus !== 'pendiente_caja' || o.prepStatus === 'cancelado')
      throw new Error('Este pedido no está pendiente de cobro en caja');
    o.paymentStatus = 'cobrado_caja';
    this.touch(o);
  }
  async recordPaymentResult(orderId: string, status: PaymentStatus, ref: string | null) {
    // La pasarela simulada solo puede dar «simulado» o «fallido», nunca un pago verificado.
    if (status !== 'simulado' && status !== 'fallido') throw new Error('La pasarela simulada no puede registrar ese estado de pago.');
    const o = this.findOrder(orderId);
    if (o.paymentMethod !== 'online' || !['pendiente_online', 'fallido'].includes(o.paymentStatus))
      throw new Error('Este pedido no está pendiente de pago online');
    o.paymentStatus = status;
    o.paymentRef = ref;
    this.touch(o);
    return this.delay(o);
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
