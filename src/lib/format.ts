import type { Cents, Order, PaymentStatus, PrepStatus } from '../types';

const eur = new Intl.NumberFormat('es-ES', { style: 'currency', currency: 'EUR' });
export const formatPrice = (cents: Cents) => eur.format(cents / 100);

const hm = new Intl.DateTimeFormat('es-ES', { hour: '2-digit', minute: '2-digit' });
export const formatTime = (iso: string) => hm.format(new Date(iso));

export const minutesSince = (iso: string, now = Date.now()) =>
  Math.max(0, Math.floor((now - new Date(iso).getTime()) / 60000));

export const orderCode = (n: number) => `#${n}`;

export const itemCount = (o: Pick<Order, 'items'>) => o.items.reduce((s, i) => s + i.quantity, 0);

export function originLabel(o: Order): string {
  if (o.mode === 'mesa') return `Mesa ${o.table ?? '?'}`;
  const when = !o.pickupTime || o.pickupTime === 'asap' ? 'lo antes posible' : `a las ${o.pickupTime}`;
  return `Recoger ${when}${o.customerName ? ` · ${o.customerName}` : ''}`;
}

export type Tone = 'ok' | 'warn' | 'danger' | 'info' | 'neutral' | 'brand';

export const paymentLabel: Record<PaymentStatus, { label: string; tone: Tone; hint: string }> = {
  pendiente_online: { label: 'Esperando pago online', tone: 'warn', hint: 'El cliente aún no ha completado el pago.' },
  simulado: { label: 'Pago simulado', tone: 'info', hint: 'Pago de demostración. No hay cargo real ni verificación.' },
  pagado_verificado: { label: 'Pagado (verificado)', tone: 'ok', hint: 'Confirmado por la pasarela de pago.' },
  pendiente_caja: { label: 'Cobrar en caja', tone: 'warn', hint: 'Pendiente de cobro por el personal.' },
  cobrado_caja: { label: 'Cobrado en caja', tone: 'ok', hint: 'Marcado como cobrado por el personal.' },
  fallido: { label: 'Pago fallido', tone: 'danger', hint: 'El pago no se completó.' },
};

export const prepLabel: Record<PrepStatus, { label: string; tone: Tone }> = {
  nuevo: { label: 'Nuevo', tone: 'brand' },
  en_preparacion: { label: 'En preparación', tone: 'warn' },
  listo: { label: 'Listo', tone: 'ok' },
  entregado: { label: 'Entregado', tone: 'neutral' },
  cancelado: { label: 'Cancelado', tone: 'danger' },
};

export const nextPrep: Partial<Record<PrepStatus, { to: PrepStatus; action: string }>> = {
  nuevo: { to: 'en_preparacion', action: 'Empezar a preparar' },
  en_preparacion: { to: 'listo', action: 'Marcar como listo' },
  listo: { to: 'entregado', action: 'Marcar entregado' },
};

/** Pedidos que cocina puede ver: excluye los que esperan un pago online. */
export const isKitchenVisible = (o: Order) =>
  o.paymentStatus !== 'pendiente_online' && o.paymentStatus !== 'fallido' &&
  (o.prepStatus === 'nuevo' || o.prepStatus === 'en_preparacion' || o.prepStatus === 'listo');

export const needsCounterPayment = (o: Order) => o.paymentStatus === 'pendiente_caja' && o.prepStatus !== 'cancelado';

export function slugify(s: string) {
  return s
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')
    .slice(0, 40);
}
