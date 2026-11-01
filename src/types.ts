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
  /** Suspendido por la plataforma: no acepta pedidos aunque esté «active». Solo la plataforma lo cambia. */
  suspended: boolean;
}

export type NewRestaurantInput = Pick<Restaurant, 'name' | 'slug'> & Partial<Omit<Restaurant, 'id' | 'createdAt' | 'suspended'>>;

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
  /**
   * Secreto aleatorio (64 caracteres hex) generado en el navegador. Permite al cliente
   * leer SOLO su pedido y hace la creación idempotente: reenviarlo no duplica el pedido.
   */
  accessToken: string;
}

export type StaffRole = 'owner' | 'manager' | 'waiter' | 'kitchen';

export interface Membership {
  restaurantId: string;
  role: StaffRole;
}

/** Miembro del equipo de un restaurante (staff_list). */
export interface StaffMember {
  userId: string;
  email: string;
  role: StaffRole;
  isMe: boolean;
}

/** Comanda para cocina: solo lo necesario para preparar (sin teléfono, importes ni pago). */
export interface KitchenTicket {
  id: string;
  number: number;
  createdAt: string;
  mode: OrderMode;
  table: number | null;
  /** Solo en pedidos para recoger. */
  customerName: string | null;
  pickupTime: string | null;
  notes: string;
  prepStatus: PrepStatus;
  items: { name: string; quantity: number; notes?: string }[];
}

/** Entrada del registro de auditoría (audit_list). */
export interface AuditEntry {
  createdAt: string;
  action: string;
  actorEmail: string | null;
  actorKind: 'plataforma' | 'personal' | 'cliente' | 'servidor' | 'sql_editor';
  targetTable: string | null;
  targetId: string | null;
  details: Record<string, unknown>;
}

export interface StaffSession {
  userId: string;
  email: string;
  isPlatformAdmin: boolean;
  memberships: Membership[];
}
