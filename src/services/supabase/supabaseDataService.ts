import type { SupabaseClient } from '@supabase/supabase-js';
import type { Category, Order, Product, Restaurant } from '../../types';
import type { DataService, Menu } from '../dataService';

/**
 * Implementación para Supabase. Usa el esquema de `supabase/schema.sql`.
 * Columnas en snake_case en la base de datos ↔ camelCase en la app.
 *
 * Nota: aún no se ha probado contra un proyecto real; es el punto de partida
 * para la fase 2.
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

export class SupabaseDataService implements DataService {
  readonly kind = 'supabase' as const;
  private client: Promise<SupabaseClient>;

  constructor(url: string, anonKey: string) {
    if (!url || !anonKey) throw new Error('Faltan VITE_SUPABASE_URL o VITE_SUPABASE_ANON_KEY');
    // Carga diferida: el modo demo no descarga supabase-js.
    this.client = import('@supabase/supabase-js').then(({ createClient }) => createClient(url, anonKey));
  }

  private async one<T>(q: PromiseLike<{ data: any; error: any }>, map: (r: Row) => T): Promise<T> {
    const { data, error } = await q;
    if (error) throw new Error(error.message);
    return map(data);
  }
  private async many<T>(q: PromiseLike<{ data: any; error: any }>, map: (r: Row) => T): Promise<T[]> {
    const { data, error } = await q;
    if (error) throw new Error(error.message);
    return (data ?? []).map(map);
  }

  async listRestaurants() {
    return this.many((await this.client).from('restaurants').select('*').order('name'), toRestaurant);
  }
  async getRestaurantBySlug(slug: string) {
    const { data, error } = await (await this.client).from('restaurants').select('*').eq('slug', slug).maybeSingle();
    if (error) throw new Error(error.message);
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

  async listOrders(restaurantId: string) {
    return this.many(
      (await this.client).from('orders').select(ORDER_SELECT).eq('restaurant_id', restaurantId).order('created_at', { ascending: false }).limit(200),
      toOrder,
    );
  }
  async getOrder(orderId: string) {
    const { data, error } = await (await this.client).from('orders').select(ORDER_SELECT).eq('id', orderId).maybeSingle();
    if (error) throw new Error(error.message);
    return data ? toOrder(data) : null;
  }
  async createOrder(input: Parameters<DataService['createOrder']>[0]) {
    // La función SQL `create_order` valida productos, calcula precios y asigna el número.
    const { data, error } = await (await this.client).rpc('create_order', { payload: input });
    if (error) throw new Error(error.message);
    const order = await this.getOrder(data as string);
    if (!order) throw new Error('No se pudo leer el pedido creado');
    return order;
  }
  private async update(orderId: string, patch: Row) {
    return this.one((await this.client).from('orders').update(patch).eq('id', orderId).select(ORDER_SELECT).single(), toOrder);
  }
  async updatePrepStatus(orderId: string, status: Order['prepStatus']) {
    return this.update(orderId, { prep_status: status });
  }
  async changePaymentMethod(orderId: string, method: Order['paymentMethod']) {
    return this.update(orderId, { payment_method: method, payment_status: method === 'caja' ? 'pendiente_caja' : 'pendiente_online' });
  }
  async markPaidAtCounter(orderId: string) {
    return this.update(orderId, { payment_status: 'cobrado_caja' });
  }
  async recordPaymentResult(): Promise<Order> {
    throw new Error('Con Supabase, el estado del pago lo actualiza la Edge Function del webhook del proveedor.');
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
