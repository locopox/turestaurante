import type {
  Category, NewOrderInput, NewRestaurantInput, Order, PaymentStatus,
  PrepStatus, Product, Restaurant, StaffSession,
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
  /** true si el panel, la cocina y la administración exigen iniciar sesión. */
  readonly requiresLogin: boolean;

  // Sesión del personal
  getSession(): Promise<StaffSession | null>;
  signIn(email: string, password: string): Promise<StaffSession>;
  signOut(): Promise<void>;
  onAuthChange(onChange: () => void): Unsubscribe;

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

  // Cliente (sin cuenta): solo accede a SU pedido mediante el token secreto
  /** Valida, calcula precios y numera en el servidor. Reenviar el mismo token devuelve el mismo pedido. */
  createOrder(input: NewOrderInput): Promise<Order>;
  getCustomerOrder(orderId: string, accessToken: string): Promise<Order | null>;
  subscribeCustomerOrder(orderId: string, accessToken: string, onChange: () => void): Unsubscribe;
  /** El cliente abandona el pago online pendiente y pagará en caja. */
  switchToCounterPayment(orderId: string, accessToken: string): Promise<Order>;

  // Personal (con sesión y según su rol)
  listOrders(restaurantId: string): Promise<Order[]>;
  updatePrepStatus(orderId: string, status: PrepStatus): Promise<void>;
  markPaidAtCounter(orderId: string): Promise<void>;
  subscribeOrders(restaurantId: string, onChange: () => void): Unsubscribe;
  subscribeCatalog(onChange: () => void): Unsubscribe;

  /**
   * Resultado de la pasarela SIMULADA del modo demo. Con Supabase lanza error: el estado del
   * pago solo lo cambia el servidor tras la confirmación firmada del proveedor.
   */
  recordPaymentResult(orderId: string, status: PaymentStatus, ref: string | null): Promise<Order>;

  /** Solo demo: restaura los datos de ejemplo. */
  resetDemo?(): Promise<void>;
}
