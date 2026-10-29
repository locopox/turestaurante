/** Importes siempre en céntimos (enteros) para evitar errores de redondeo. */
export type Cents = number;

export interface Restaurant {
  id: string;
  slug: string;
  name: string;
  tagline: string;
  address: string;
  phone: string;
  active: boolean;
  tables: number;
  pickupEnabled: boolean;
  onlinePaymentEnabled: boolean;
  counterPaymentEnabled: boolean;
  /** Tiempo medio de preparación, en minutos. */
  prepMinutes: number;
  createdAt: string;
}

export type NewRestaurantInput = Pick<Restaurant, 'name' | 'slug'> & Partial<Omit<Restaurant, 'id' | 'createdAt'>>;

export interface Category {
  id: string;
  restaurantId: string;
  name: string;
  sort: number;
}

export type FoodArt =
  | 'pizza' | 'pasta' | 'salad' | 'bread' | 'dessert' | 'soda' | 'coffee'
  | 'wine' | 'water' | 'ramen' | 'taco' | 'gyoza';

export type ProductTag = 'vegetariano' | 'vegano' | 'picante' | 'nuevo' | 'sin_gluten';

export interface Product {
  id: string;
  restaurantId: string;
  categoryId: string;
  name: string;
  description: string;
  price: Cents;
  /** Ilustración de reserva mientras no haya foto real. */
  art: FoodArt;
  imageUrl?: string | null;
  allergens: string[];
  tags: ProductTag[];
  available: boolean;
  sort: number;
}

export type OrderMode = 'mesa' | 'recoger';
export type PaymentMethod = 'online' | 'caja';

/**
 * Estados de pago.
 * - `pagado_verificado` SOLO debe asignarlo el servidor tras recibir la confirmación
 *   firmada del proveedor de pagos (webhook). La demo nunca lo usa.
 * - `simulado` es el resultado de la pasarela de prueba: no hay cargo real.
 */
export type PaymentStatus =
  | 'pendiente_online'
  | 'simulado'
  | 'pagado_verificado'
  | 'pendiente_caja'
  | 'cobrado_caja'
  | 'fallido';

export type PrepStatus = 'nuevo' | 'en_preparacion' | 'listo' | 'entregado' | 'cancelado';

export interface OrderItem {
  productId: string;
  name: string;
  unitPrice: Cents;
  quantity: number;
  notes?: string;
}

export interface Order {
  id: string;
  restaurantId: string;
  /** Número visible para cliente, sala y cocina. */
  number: number;
  createdAt: string;
  updatedAt: string;
  mode: OrderMode;
  table: number | null;
  customerName: string | null;
  customerPhone: string | null;
  /** "asap" o una hora "HH:MM". */
  pickupTime: string | null;
  items: OrderItem[];
  notes: string;
  total: Cents;
  paymentMethod: PaymentMethod;
  paymentStatus: PaymentStatus;
  paymentRef: string | null;
  prepStatus: PrepStatus;
}

export interface NewOrderInput {
  restaurantId: string;
  mode: OrderMode;
  table?: number | null;
  customerName?: string | null;
  customerPhone?: string | null;
  pickupTime?: string | null;
  /** El precio NO viaja desde el cliente: el servidor lo calcula con la carta. */
  items: { productId: string; quantity: number; notes?: string }[];
  notes?: string;
  paymentMethod: PaymentMethod;
}
