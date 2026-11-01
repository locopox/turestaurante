import { createSeed, type SeedDB } from '../../data/seed';
import { canChangePrep, OrderRuleError, validateOrder } from '../../lib/orderRules';
import { safeStorage, uid } from '../../lib/storage';
import type { KitchenTicket, Order, PaymentStatus, Restaurant, StaffSession, SupportDenial } from '../../types';
import type { DataService, Menu } from '../dataService';

const KEY = 'turestaurante:demo-db:v1';
/** Plazo para pasar de pago online a caja (igual que en la base de datos). */
const SWITCH_TO_COUNTER_WINDOW_MS = 2 * 60 * 60 * 1000;
const CHANNEL = 'turestaurante:demo';

/** Tokens de seguimiento de los clientes (token → id de pedido). Los datos antiguos no lo tienen. */
type MockDB = SeedDB & { access?: Record<string, string> };

/**
 * En la demo no hay inicio de sesión. La sesión de demostración es plataforma y, además, owner
 * de todos los restaurantes, para poder enseñar todas las pantallas. (Con Supabase, una cuenta
 * de plataforma NO puede ser personal de ningún restaurante.)
 */
const demoSession = (restaurants: { id: string }[]): StaffSession => ({
  userId: 'demo', email: 'demo@turestaurante.app', isPlatformAdmin: true,
  memberships: restaurants.map((r) => ({ restaurantId: r.id, role: 'owner' })),
});
const NO_ACCOUNTS = 'En el modo demo no hay cuentas de personal: el equipo se gestiona con Supabase.';
const NO_INVITES = 'Las invitaciones necesitan Supabase: en la demo no hay cuentas ni se envían correos.';
const NO_SUPPORT = 'El modo soporte necesita Supabase: en la demo no hay cuentas de plataforma ni de propietario separadas.';
/** Restaurantes guardados por versiones anteriores de la demo no tienen «suspended». */
const normalize = (r: Restaurant): Restaurant => ({ ...r, suspended: r.suspended ?? false });

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
    return demoSession(this.db.restaurants);
  }
  async signIn() {
    return demoSession(this.db.restaurants);
  }
  async signOut() {}
  onAuthChange() {
    return () => {};
  }

  // Contraseñas: en la demo no hay cuentas ni inicio de sesión.
  getAuthRedirect() {
    return { kind: 'none' } as const;
  }
  dismissAuthRedirect() {}
  getPasswordSetupKind() {
    return null;
  }
  isPasswordRecoveryPending() {
    return false;
  }
  async setNewPassword(): Promise<void> {
    throw new Error('En el modo demo no hay contraseñas.');
  }
  async changePassword(): Promise<void> {
    throw new Error('En el modo demo no hay contraseñas.');
  }
  async requestPasswordReset(): Promise<void> {
    throw new Error('En el modo demo no hay contraseñas.');
  }
  async cancelPasswordRecovery() {}

  // Restaurantes
  async listRestaurants() {
    return this.delay(this.db.restaurants.map(normalize).sort((a, b) => a.name.localeCompare(b.name, 'es')));
  }
  async getRestaurantBySlug(slug: string) {
    const r = this.db.restaurants.find((x) => x.slug === slug);
    return this.delay(r ? normalize(r) : null);
  }
  async createRestaurant(input: Parameters<DataService['createRestaurant']>[0]) {
    if (this.db.restaurants.some((r) => r.slug === input.slug)) throw new Error('Ya existe un restaurante con esa dirección web (slug).');
    const r = {
      tagline: '', address: '', phone: '', active: false, tables: 10, pickupEnabled: true,
      onlinePaymentEnabled: true, counterPaymentEnabled: true, prepMinutes: 15,
      ...input, id: uid('r-'), createdAt: new Date().toISOString(), suspended: false,
    };
    this.db.restaurants.push(r);
    this.db.counters[r.id] = 100;
    this.commit();
    return this.delay(r);
  }
  async saveRestaurant(restaurant: Parameters<DataService['saveRestaurant']>[0]) {
    if (this.db.restaurants.some((r) => r.slug === restaurant.slug && r.id !== restaurant.id))
      throw new Error('Ya existe un restaurante con esa dirección web (slug).');
    // La suspensión no se cambia desde el formulario (solo con setRestaurantSuspension).
    const current = this.db.restaurants.find((r) => r.id === restaurant.id);
    const saved = { ...restaurant, suspended: current?.suspended ?? false };
    this.db.restaurants = this.db.restaurants.map((r) => (r.id === restaurant.id ? saved : r));
    this.commit();
    return this.delay(saved);
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
    // Mismas reglas que customer_switch_to_counter en supabase/schema.sql
    const restaurant = this.db.restaurants.find((r) => r.id === o.restaurantId);
    if (!restaurant?.active) throw new Error('El restaurante no acepta pedidos en este momento');
    if (!restaurant.counterPaymentEnabled) throw new Error('El pago en caja no está disponible en este restaurante');
    if (o.paymentMethod !== 'online' || !['pendiente_online', 'fallido'].includes(o.paymentStatus) || o.prepStatus !== 'nuevo')
      throw new Error('Este pedido ya no puede cambiar de método de pago');
    if (Date.now() - new Date(o.createdAt).getTime() > SWITCH_TO_COUNTER_WINDOW_MS)
      throw new Error('Este pedido ha caducado. Haz un pedido nuevo.');
    if (o.paymentStatus === 'pendiente_online' && o.paymentRef)
      throw new Error('Hay un pago online en curso. Espera a que termine o pide ayuda al personal.');
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

  // Cocina: mismas reglas que kitchen_orders (sin teléfono, importes ni pago)
  async listKitchenOrders(restaurantId: string): Promise<KitchenTicket[]> {
    const tickets = this.db.orders
      .filter((o) => o.restaurantId === restaurantId && ['nuevo', 'en_preparacion', 'listo'].includes(o.prepStatus)
        && o.paymentStatus !== 'pendiente_online' && o.paymentStatus !== 'fallido')
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt))
      .map((o) => ({
        id: o.id, number: o.number, createdAt: o.createdAt, mode: o.mode, table: o.table,
        customerName: o.mode === 'recoger' ? o.customerName : null, pickupTime: o.pickupTime, notes: o.notes,
        prepStatus: o.prepStatus, items: o.items.map((i) => ({ name: i.name, quantity: i.quantity, ...(i.notes ? { notes: i.notes } : {}) })),
      }));
    return this.delay(tickets);
  }
  subscribeKitchen(_restaurantId: string, onChange: () => void) {
    this.listeners.add(onChange);
    return () => void this.listeners.delete(onChange);
  }

  // Equipo y auditoría: en la demo no hay cuentas ni registro
  async listStaff() {
    return [];
  }
  // Invitaciones: en la demo no hay cuentas ni correo. Nada se concede desde aquí.
  async inviteStaff(): Promise<never> {
    throw new Error(NO_INVITES);
  }
  async resendInvitation(): Promise<never> {
    throw new Error(NO_INVITES);
  }
  async revokeInvitation(): Promise<void> {
    throw new Error(NO_INVITES);
  }
  async listInvitations() {
    return [];
  }
  async myInvitations() {
    return [];
  }
  async acceptInvitation(): Promise<string> {
    throw new Error(NO_INVITES);
  }
  async declineInvitation(): Promise<void> {
    throw new Error(NO_INVITES);
  }
  async createRestaurantWithOwner(): Promise<never> {
    throw new Error(NO_INVITES);
  }
  async changeStaffRole(): Promise<void> {
    throw new Error(NO_ACCOUNTS);
  }
  async removeStaff(): Promise<void> {
    throw new Error(NO_ACCOUNTS);
  }
  async listAudit() {
    return [];
  }
  // Modo soporte: necesita cuentas reales (plataforma y propietario distintos), así que en la demo
  // no está disponible.
  async requestSupport(): Promise<void> {
    throw new Error(NO_SUPPORT);
  }
  async listSupportRequests() {
    return [];
  }
  async mySupportRequests() {
    return [];
  }
  async decideSupport(): Promise<void> {
    throw new Error(NO_SUPPORT);
  }
  async revokeSupport(): Promise<void> {
    throw new Error(NO_SUPPORT);
  }
  async cancelSupport(): Promise<void> {
    throw new Error(NO_SUPPORT);
  }
  async supportViewRestaurant(): Promise<never> {
    throw new Error(NO_SUPPORT);
  }
  async supportViewOrders(): Promise<never> {
    throw new Error(NO_SUPPORT);
  }
  async supportViewPaymentEvents(): Promise<never> {
    throw new Error(NO_SUPPORT);
  }
  async listSupportDenials(_restaurantId: string | null): Promise<SupportDenial[]> {
    void _restaurantId;
    return [];
  }
  async setRestaurantSuspension(restaurantId: string, suspended: boolean, reason: string) {
    if (suspended && reason.trim().length < 3) throw new Error('Indica el motivo de la suspensión');
    this.db.restaurants = this.db.restaurants.map((r) => (r.id === restaurantId ? { ...r, suspended } : r));
    this.commit();
  }

  async resetDemo() {
    this.db = createSeed();
    this.commit();
  }
}
