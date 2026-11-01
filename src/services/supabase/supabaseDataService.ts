import type { SupabaseClient } from '@supabase/supabase-js';
import { friendlyAuthError, parseAuthRedirect, PASSWORD_MIN, type AuthRedirect } from '../../lib/authRedirect';
import type { Category, Order, Product, Restaurant, StaffRole, StaffSession } from '../../types';
import type { DataService, Menu } from '../dataService';

/**
 * Implementación para Supabase. Usa el esquema de `supabase/schema.sql`.
 * Columnas en snake_case en la base de datos ↔ camelCase en la app.
 *
 * Seguridad: solo usa la clave pública. Lo que puede hacer cada usuario lo decide la base de
 * datos (RLS y funciones). Los clientes anónimos solo llaman a create_order,
 * get_customer_order y customer_switch_to_counter.
 *
 * Nota: el SQL está probado contra PostgreSQL local (supabase/tests); este cliente aún no
 * se ha probado contra un proyecto real de Supabase.
 */
type Row = Record<string, any>;

const toRestaurant = (r: Row): Restaurant => ({
  id: r.id, slug: r.slug, name: r.name, tagline: r.tagline ?? '', address: r.address ?? '', phone: r.phone ?? '',
  active: r.active, tables: r.tables, pickupEnabled: r.pickup_enabled, onlinePaymentEnabled: r.online_payment_enabled,
  counterPaymentEnabled: r.counter_payment_enabled, prepMinutes: r.prep_minutes, createdAt: r.created_at,
});
const fromRestaurant = (r: Partial<Restaurant>): Row => ({
  slug: r.slug, name: r.name, tagline: r.tagline, address: r.address, phone: r.phone, active: r.active,
  tables: r.tables, pickup_enabled: r.pickupEnabled, online_payment_enabled: r.onlinePaymentEnabled,
  counter_payment_enabled: r.counterPaymentEnabled, prep_minutes: r.prepMinutes,
});
const toCategory = (r: Row): Category => ({ id: r.id, restaurantId: r.restaurant_id, name: r.name, sort: r.sort });
const toProduct = (r: Row): Product => ({
  id: r.id, restaurantId: r.restaurant_id, categoryId: r.category_id, name: r.name, description: r.description ?? '',
  price: r.price_cents, art: r.art, imageUrl: r.image_url, allergens: r.allergens ?? [], tags: r.tags ?? [],
  available: r.available, sort: r.sort,
});
const fromProduct = (p: Partial<Product>): Row => ({
  restaurant_id: p.restaurantId, category_id: p.categoryId, name: p.name, description: p.description,
  price_cents: p.price, art: p.art, image_url: p.imageUrl ?? null, allergens: p.allergens, tags: p.tags,
  available: p.available,
});
const toOrder = (r: Row): Order => ({
  id: r.id, restaurantId: r.restaurant_id, number: r.number, createdAt: r.created_at, updatedAt: r.updated_at,
  mode: r.mode, table: r.table_number, customerName: r.customer_name, customerPhone: r.customer_phone,
  pickupTime: r.pickup_time, notes: r.notes ?? '', total: r.total_cents, paymentMethod: r.payment_method,
  paymentStatus: r.payment_status, paymentRef: r.payment_ref, prepStatus: r.prep_status,
  items: (r.order_items ?? []).map((i: Row) => ({
    productId: i.product_id, name: i.name, unitPrice: i.unit_price_cents, quantity: i.quantity, notes: i.notes ?? undefined,
  })),
});

const ORDER_SELECT = '*, order_items(*)';

const CUSTOMER_POLL_MS = 5000;

/** Pedido tal y como lo devuelven las funciones para clientes (ya en camelCase, sin datos privados). */
const fromCustomerJson = (j: Row): Order => ({
  id: j.id, restaurantId: j.restaurantId, number: j.number, createdAt: j.createdAt, updatedAt: j.updatedAt,
  mode: j.mode, table: j.table ?? null, customerName: j.customerName ?? null, customerPhone: null,
  pickupTime: j.pickupTime ?? null, notes: j.notes ?? '', total: j.total, paymentMethod: j.paymentMethod,
  paymentStatus: j.paymentStatus, paymentRef: null, prepStatus: j.prepStatus,
  items: (j.items ?? []).map((i: Row) => ({
    productId: i.productId, name: i.name, unitPrice: i.unitPrice, quantity: i.quantity, notes: i.notes ?? undefined,
  })),
});

/** Traduce los errores técnicos más comunes a mensajes comprensibles. */
function friendly(message: string): string {
  if (/permission denied|row-level security|JWT|not authorized/i.test(message)) return 'No tienes permiso para hacer esto. Inicia sesión con una cuenta del restaurante.';
  // Un UPDATE bloqueado por RLS no da error: simplemente no devuelve ninguna fila.
  if (/PGRST116|multiple \(or no\) rows|0 rows/i.test(message)) return 'No tienes permiso para modificar esto o ya no existe.';
  if (/duplicate key.*slug/i.test(message)) return 'Ya existe un restaurante con esa dirección web (slug).';
  if (/Failed to fetch|NetworkError|fetch failed/i.test(message)) return 'No hay conexión con el servidor. Inténtalo de nuevo.';
  return message;
}

/** Lo que el servicio necesita del navegador. Se puede sustituir en las pruebas. */
export interface BrowserEnv {
  location: { hash: string; search: string; origin: string; pathname: string };
  history: { state: unknown; replaceState(data: unknown, unused: string, url?: string): void } | null;
  storage: { getItem(k: string): string | null; setItem(k: string, v: string): void; removeItem(k: string): void } | null;
}

function browserEnv(): BrowserEnv | null {
  if (typeof window === 'undefined') return null;
  let storage: BrowserEnv['storage'] = null;
  try {
    storage = window.sessionStorage;
  } catch {
    storage = null;
  }
  return { location: window.location, history: window.history, storage };
}

/** Marca de «recuperación pendiente», solo para esta pestaña (sessionStorage). */
const RECOVERY_KEY = 'turestaurante:recuperar-contrasena';

export class SupabaseDataService implements DataService {
  readonly kind = 'supabase' as const;
  readonly requiresLogin = true;
  private client: Promise<SupabaseClient>;
  private env: BrowserEnv | null;
  private redirect: AuthRedirect;
  private authListeners = new Set<() => void>();

  constructor(url: string, anonKey: string, deps: { createClient?: () => Promise<SupabaseClient>; env?: BrowserEnv | null } = {}) {
    this.env = deps.env !== undefined ? deps.env : browserEnv();
    // Se lee ANTES de crear el cliente: supabase-js borra los datos del enlace al procesarlo.
    this.redirect = this.env ? parseAuthRedirect(this.env.location.hash, this.env.location.search) : { kind: 'none' };
    if (this.redirect.kind === 'recovery') this.setRecoveryFlag(true);
    if (this.redirect.kind === 'error' && this.env?.history) {
      // Quita el error de la dirección para que no se repita al recargar.
      this.env.history.replaceState(this.env.history.state, '', this.env.location.pathname);
    }
    // Carga diferida: el modo demo no descarga supabase-js.
    const create = deps.createClient
      ?? (() => import('@supabase/supabase-js').then(({ createClient }) => createClient(url, anonKey)));
    this.client = create().then((sb) => {
      // Suscripción inmediata: el evento PASSWORD_RECOVERY se emite nada más procesar el enlace.
      sb.auth.onAuthStateChange((event, session) => {
        if (event === 'PASSWORD_RECOVERY') this.setRecoveryFlag(true);
        // Sin sesión (enlace no válido o sesión cerrada), la recuperación ya no está pendiente.
        if (event === 'SIGNED_OUT' || (event === 'INITIAL_SESSION' && !session)) this.setRecoveryFlag(false);
        // Si el enlace no pudo procesarse (token no válido, sin conexión…), supabase-js deja los
        // tokens en la dirección. Se quitan para que no queden visibles ni en el historial.
        if (event === 'INITIAL_SESSION' && this.env?.history && /(^|[#&])(access_token|refresh_token)=/.test(this.env.location.hash)) {
          this.env.history.replaceState(this.env.history.state, '', this.env.location.pathname + this.env.location.search);
        }
        // Fuera del callback: supabase-js recomienda no llamar a Supabase dentro de él.
        setTimeout(() => this.emitAuth(), 0);
      });
      return sb;
    });
  }

  private emitAuth() {
    this.authListeners.forEach((l) => l());
  }
  private setRecoveryFlag(on: boolean) {
    try {
      if (on) this.env?.storage?.setItem(RECOVERY_KEY, '1');
      else this.env?.storage?.removeItem(RECOVERY_KEY);
    } catch {
      /* sin almacenamiento: solo dura mientras la página esté abierta */
    }
    this.recoveryInMemory = on;
  }
  private recoveryInMemory = false;

  // ---------- Sesión del personal ----------
  async getSession(): Promise<StaffSession | null> {
    const sb = await this.client;
    const { data } = await sb.auth.getSession();
    const user = data.session?.user;
    if (!user) return null;
    const [memberships, admin] = await Promise.all([
      sb.rpc('my_memberships'),
      sb.from('platform_admins').select('user_id').eq('user_id', user.id).maybeSingle(),
    ]);
    if (memberships.error) throw new Error(friendly(memberships.error.message));
    return {
      userId: user.id,
      email: user.email ?? '',
      isPlatformAdmin: !!admin.data,
      memberships: ((memberships.data ?? []) as Row[]).map((m) => ({ restaurantId: m.restaurant_id, role: m.role as StaffRole })),
    };
  }
  async signIn(email: string, password: string) {
    const { error } = await (await this.client).auth.signInWithPassword({ email: email.trim(), password });
    if (error) throw new Error(/invalid/i.test(error.message) ? 'Email o contraseña incorrectos.' : friendly(error.message));
    // Quien entra con su contraseña ya no está recuperándola.
    this.setRecoveryFlag(false);
    const session = await this.getSession();
    if (!session) throw new Error('No se pudo iniciar sesión.');
    return session;
  }
  async signOut() {
    await (await this.client).auth.signOut();
  }
  onAuthChange(onChange: () => void) {
    this.authListeners.add(onChange);
    return () => void this.authListeners.delete(onChange);
  }

  // ---------- Contraseña ----------
  getAuthRedirect() {
    return this.redirect;
  }
  dismissAuthRedirect() {
    this.redirect = { kind: 'none' };
    this.emitAuth();
  }
  isPasswordRecoveryPending() {
    try {
      const stored = this.env?.storage?.getItem(RECOVERY_KEY);
      if (stored != null) return stored === '1';
    } catch {
      /* usar el valor en memoria */
    }
    return this.recoveryInMemory;
  }
  async setNewPassword(newPassword: string) {
    if (newPassword.length < PASSWORD_MIN) throw new Error(`La contraseña debe tener al menos ${PASSWORD_MIN} caracteres.`);
    const sb = await this.client;
    // Usa la sesión abierta por el enlace de recuperación (o la del propio usuario).
    const { error } = await sb.auth.updateUser({ password: newPassword });
    if (error) throw new Error(friendlyAuthError(error));
    this.setRecoveryFlag(false);
    this.emitAuth();
  }
  async changePassword(currentPassword: string, newPassword: string, signOutOtherDevices: boolean) {
    const sb = await this.client;
    const { data } = await sb.auth.getSession();
    const email = data.session?.user.email;
    if (!email) throw new Error('Tu sesión ha caducado. Vuelve a iniciar sesión.');
    // Comprobar la contraseña actual. Si es incorrecta, Supabase devuelve error y la sesión
    // actual se mantiene intacta.
    const check = await sb.auth.signInWithPassword({ email, password: currentPassword });
    if (check.error) {
      throw new Error(/invalid login credentials/i.test(check.error.message) || check.error.code === 'invalid_credentials'
        ? 'La contraseña actual no es correcta.'
        : friendlyAuthError(check.error));
    }
    await this.setNewPassword(newPassword);
    // Solo si el usuario lo pide. Nunca cierra la sesión actual.
    if (signOutOtherDevices) {
      const { error } = await sb.auth.signOut({ scope: 'others' });
      if (error) throw new Error('La contraseña se ha cambiado, pero no se pudieron cerrar las otras sesiones.');
    }
  }
  async requestPasswordReset(email: string) {
    const clean = email.trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(clean)) throw new Error('Escribe un email válido.');
    const sb = await this.client;
    // El enlace vuelve a esta misma app. La dirección debe estar en «Redirect URLs» de Supabase;
    // si no lo está, Supabase usa la «Site URL» del proyecto.
    const redirectTo = this.env ? this.env.location.origin + this.env.location.pathname : undefined;
    const { error } = await sb.auth.resetPasswordForEmail(clean, redirectTo ? { redirectTo } : undefined);
    // Supabase no indica si el email existe. Solo se muestran errores generales (p. ej. límite de envíos).
    if (error) throw new Error(friendlyAuthError(error));
  }
  async cancelPasswordRecovery() {
    this.setRecoveryFlag(false);
    await (await this.client).auth.signOut({ scope: 'local' });
    this.emitAuth();
  }

  private async one<T>(q: PromiseLike<{ data: any; error: any }>, map: (r: Row) => T): Promise<T> {
    const { data, error } = await q;
    if (error) throw new Error(friendly(error.message));
    return map(data);
  }
  private async many<T>(q: PromiseLike<{ data: any; error: any }>, map: (r: Row) => T): Promise<T[]> {
    const { data, error } = await q;
    if (error) throw new Error(friendly(error.message));
    return (data ?? []).map(map);
  }

  async listRestaurants() {
    return this.many((await this.client).from('restaurants').select('*').order('name'), toRestaurant);
  }
  async getRestaurantBySlug(slug: string) {
    const { data, error } = await (await this.client).from('restaurants').select('*').eq('slug', slug).maybeSingle();
    if (error) throw new Error(friendly(error.message));
    return data ? toRestaurant(data) : null;
  }
  async createRestaurant(input: Parameters<DataService['createRestaurant']>[0]) {
    return this.one((await this.client).from('restaurants').insert(fromRestaurant(input)).select().single(), toRestaurant);
  }
  async saveRestaurant(r: Restaurant) {
    return this.one((await this.client).from('restaurants').update(fromRestaurant(r)).eq('id', r.id).select().single(), toRestaurant);
  }

  async getMenu(restaurantId: string): Promise<Menu> {
    const [categories, products] = await Promise.all([
      this.many((await this.client).from('categories').select('*').eq('restaurant_id', restaurantId).order('sort'), toCategory),
      this.many((await this.client).from('products').select('*').eq('restaurant_id', restaurantId).order('sort'), toProduct),
    ]);
    return { categories, products };
  }
  async createCategory(restaurantId: string, name: string) {
    return this.one((await this.client).from('categories').insert({ restaurant_id: restaurantId, name }).select().single(), toCategory);
  }
  async createProduct(input: Omit<Product, 'id' | 'sort'>) {
    return this.one((await this.client).from('products').insert(fromProduct(input)).select().single(), toProduct);
  }
  async saveProduct(p: Product) {
    return this.one((await this.client).from('products').update(fromProduct(p)).eq('id', p.id).select().single(), toProduct);
  }

  // ---------- Cliente (sin sesión): solo funciones con token ----------
  async createOrder(input: Parameters<DataService['createOrder']>[0]) {
    // `create_order` valida, calcula precios y total, numera y es idempotente por token.
    const { data, error } = await (await this.client).rpc('create_order', { payload: input });
    if (error) throw new Error(friendly(error.message));
    return fromCustomerJson(data);
  }
  async getCustomerOrder(orderId: string, accessToken: string) {
    const { data, error } = await (await this.client).rpc('get_customer_order', { p_order_id: orderId, p_token: accessToken });
    if (error) throw new Error(friendly(error.message));
    return data ? fromCustomerJson(data) : null;
  }
  subscribeCustomerOrder(_orderId: string, _accessToken: string, onChange: () => void) {
    // El cliente anónimo no puede usar Realtime (no tiene permiso de lectura): consulta cada pocos segundos.
    const id = setInterval(onChange, CUSTOMER_POLL_MS);
    const onVisible = () => document.visibilityState === 'visible' && onChange();
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      clearInterval(id);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }
  async switchToCounterPayment(orderId: string, accessToken: string) {
    const { data, error } = await (await this.client).rpc('customer_switch_to_counter', { p_order_id: orderId, p_token: accessToken });
    if (error) throw new Error(friendly(error.message));
    return fromCustomerJson(data);
  }

  // ---------- Personal (con sesión) ----------
  async listOrders(restaurantId: string) {
    return this.many(
      (await this.client).from('orders').select(ORDER_SELECT).eq('restaurant_id', restaurantId).order('created_at', { ascending: false }).limit(200),
      toOrder,
    );
  }
  async updatePrepStatus(orderId: string, status: Order['prepStatus']) {
    const { error } = await (await this.client).rpc('staff_set_prep_status', { p_order_id: orderId, p_status: status });
    if (error) throw new Error(friendly(error.message));
  }
  async markPaidAtCounter(orderId: string) {
    const { error } = await (await this.client).rpc('staff_mark_paid_at_counter', { p_order_id: orderId });
    if (error) throw new Error(friendly(error.message));
  }
  async recordPaymentResult(): Promise<Order> {
    throw new Error('Con Supabase, el estado del pago solo lo actualiza el servidor tras la confirmación del proveedor de pagos.');
  }

  private listen(name: string, tables: { table: string; filter?: string }[], onChange: () => void) {
    let cleanup = () => {};
    let closed = false;
    this.client.then((sb) => {
      if (closed) return;
      let ch = sb.channel(name);
      for (const t of tables) ch = ch.on('postgres_changes', { event: '*', schema: 'public', ...t }, onChange);
      ch.subscribe();
      cleanup = () => void sb.removeChannel(ch);
    });
    return () => {
      closed = true;
      cleanup();
    };
  }
  subscribeOrders(restaurantId: string, onChange: () => void) {
    return this.listen(`orders:${restaurantId}`, [{ table: 'orders', filter: `restaurant_id=eq.${restaurantId}` }], onChange);
  }
  subscribeCatalog(onChange: () => void) {
    return this.listen('catalog', [{ table: 'products' }, { table: 'restaurants' }], onChange);
  }
}
