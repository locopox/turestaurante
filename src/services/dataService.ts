import type {
  Category, NewOrderInput, NewRestaurantInput, Order, PaymentMethod, PaymentStatus,
  PrepStatus, Product, Restaurant,
} from '../types';

export interface Menu {
  categories: Category[];
  products: Product[];
}

export type Unsubscribe = () => void;

/**
 * Contrato único de acceso a datos. La UI solo habla con esta interfaz, de modo que
 * cambiar de datos ficticios (MockDataService) a Supabase (SupabaseDataService)
 * no requiere tocar las pantallas.
 */
export interface DataService {
  readonly kind: 'mock' | 'supabase';

  // Restaurantes (multi-tenant)
  listRestaurants(): Promise<Restaurant[]>;
  getRestaurantBySlug(slug: string): Promise<Restaurant | null>;
  createRestaurant(input: NewRestaurantInput): Promise<Restaurant>;
  saveRestaurant(restaurant: Restaurant): Promise<Restaurant>;

  // Carta
  getMenu(restaurantId: string): Promise<Menu>;
  createCategory(restaurantId: string, name: string): Promise<Category>;
  createProduct(input: Omit<Product, 'id' | 'sort'>): Promise<Product>;
  saveProduct(product: Product): Promise<Product>;

  // Pedidos
  listOrders(restaurantId: string): Promise<Order[]>;
  getOrder(orderId: string): Promise<Order | null>;
  /** Calcula precios y número de pedido en el servidor. */
  createOrder(input: NewOrderInput): Promise<Order>;
  updatePrepStatus(orderId: string, status: PrepStatus): Promise<Order>;
  /** Cambia el método (p. ej. el cliente abandona el pago online y pagará en caja). */
  changePaymentMethod(orderId: string, method: PaymentMethod): Promise<Order>;
  /** El personal confirma que ha cobrado en caja. */
  markPaidAtCounter(orderId: string): Promise<Order>;
  /**
   * Actualización de pago desde el proveedor. En producción la hace la Edge Function
   * del webhook con la service role; desde el navegador solo se permite en modo demo.
   */
  recordPaymentResult(orderId: string, status: PaymentStatus, ref: string | null): Promise<Order>;

  // Tiempo real
  subscribeOrders(restaurantId: string, onChange: () => void): Unsubscribe;
  subscribeCatalog(onChange: () => void): Unsubscribe;

  /** Solo demo: restaura los datos de ejemplo. */
  resetDemo?(): Promise<void>;
}
