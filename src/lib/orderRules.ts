import type { NewOrderInput, PrepStatus, Product, Restaurant } from '../types';

/**
 * Reglas de un pedido. Son las MISMAS que aplica la función SQL `create_order`
 * (supabase/schema.sql). En modo Supabase la base de datos es la autoridad; aquí se usan
 * para que el modo demo se comporte igual y para avisar al cliente antes de enviar.
 */
export const ORDER_LIMITS = {
  maxLines: 30,
  maxQtyPerLine: 20,
  maxUnits: 100,
  maxNotes: 200,
  maxLineNotes: 120,
  nameMin: 2,
  nameMax: 60,
} as const;

const TOKEN_RE = /^[0-9a-f]{64}$/;
const PHONE_RE = /^[0-9+() -]{6,20}$/;
const PICKUP_RE = /^(asap|([01][0-9]|2[0-3]):[0-5][0-9])$/;

/** 32 bytes aleatorios en hexadecimal (256 bits), con el generador criptográfico del navegador. */
export function newAccessToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

export const isValidAccessToken = (t: unknown): t is string => typeof t === 'string' && TOKEN_RE.test(t);

export class OrderRuleError extends Error {}

const fail = (msg: string): never => {
  throw new OrderRuleError(msg);
};

export interface ValidatedLine {
  product: Product;
  quantity: number;
  notes?: string;
}

/** Valida un pedido contra la configuración y la carta. Devuelve las líneas con el producto real. */
export function validateOrder(input: NewOrderInput, restaurant: Restaurant | undefined, products: Product[]) {
  if (!isValidAccessToken(input.accessToken)) fail('Falta el código de seguimiento del pedido');
  // Cerrado por el restaurante o suspendido por la plataforma (igual que create_order).
  if (!restaurant || !restaurant.active || restaurant.suspended) fail('El restaurante no acepta pedidos en este momento');
  const r = restaurant!;

  if (input.mode !== 'mesa' && input.mode !== 'recoger') fail('Elige si el pedido es para mesa o para recoger');
  if (input.paymentMethod !== 'online' && input.paymentMethod !== 'caja') fail('Elige un método de pago');
  if (input.paymentMethod === 'online' && !r.onlinePaymentEnabled) fail('El pago online no está disponible en este restaurante');
  if (input.paymentMethod === 'caja' && !r.counterPaymentEnabled) fail('El pago en caja no está disponible en este restaurante');

  let table: number | null = null;
  let customerName: string | null = null;
  let customerPhone: string | null = null;
  let pickupTime: string | null = null;
  if (input.mode === 'mesa') {
    if (!Number.isInteger(input.table)) fail('Indica un número de mesa válido');
    table = input.table as number;
    if (table < 1 || table > r.tables) fail(`La mesa ${table} no existe en este restaurante`);
  } else {
    if (!r.pickupEnabled) fail('Este restaurante no acepta pedidos para recoger');
    customerName = (input.customerName ?? '').trim();
    if (customerName.length < ORDER_LIMITS.nameMin || customerName.length > ORDER_LIMITS.nameMax)
      fail('Indica un nombre de 2 a 60 caracteres para recoger el pedido');
    customerPhone = (input.customerPhone ?? '').trim() || null;
    if (customerPhone && !PHONE_RE.test(customerPhone)) fail('El teléfono no es válido');
    pickupTime = input.pickupTime || 'asap';
    if (!PICKUP_RE.test(pickupTime)) fail('La hora de recogida no es válida');
  }

  const notes = (input.notes ?? '').trim();
  if (notes.length > ORDER_LIMITS.maxNotes) fail('Los comentarios admiten como máximo 200 caracteres');

  if (!Array.isArray(input.items) || input.items.length === 0) fail('El carrito está vacío');
  if (input.items.length > ORDER_LIMITS.maxLines) fail('Un pedido admite como máximo 30 productos distintos');
  let units = 0;
  const lines: ValidatedLine[] = input.items.map((line) => {
    if (!Number.isInteger(line.quantity) || line.quantity < 0) fail('Cantidad no válida');
    if (line.quantity < 1 || line.quantity > ORDER_LIMITS.maxQtyPerLine) fail('Cada producto admite entre 1 y 20 unidades');
    units += line.quantity;
    if (units > ORDER_LIMITS.maxUnits) fail('Un pedido admite como máximo 100 unidades');
    const lineNotes = (line.notes ?? '').trim();
    if (lineNotes.length > ORDER_LIMITS.maxLineNotes) fail('Las notas de un producto admiten como máximo 120 caracteres');
    const product = products.find((p) => p.id === line.productId && p.restaurantId === r.id);
    if (!product) fail('Algún producto no pertenece a esta carta. Revisa tu carrito.');
    if (!product!.available) fail(`«${product!.name}» está agotado. Quítalo del carrito para continuar.`);
    return { product: product!, quantity: line.quantity, ...(lineNotes ? { notes: lineNotes } : {}) };
  });

  const total = lines.reduce((s, l) => s + l.product.price * l.quantity, 0);
  return { lines, total, table, customerName, customerPhone, pickupTime, notes };
}

/** Cambios de preparación permitidos (igual que `staff_set_prep_status`). */
const forward: [PrepStatus, PrepStatus][] = [
  ['nuevo', 'en_preparacion'], ['en_preparacion', 'listo'], ['listo', 'entregado'],
  ['en_preparacion', 'nuevo'], ['listo', 'en_preparacion'],
];
export function canChangePrep(from: PrepStatus, to: PrepStatus): boolean {
  if (to === 'cancelado') return from === 'nuevo' || from === 'en_preparacion' || from === 'listo';
  return forward.some(([a, b]) => a === from && b === to);
}
