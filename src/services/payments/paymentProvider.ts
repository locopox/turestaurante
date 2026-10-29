import type { Order } from '../../types';

export type PaymentSession =
  /** Pasarela de prueba integrada en la app; no se cobra nada. */
  | { kind: 'simulated'; sessionId: string }
  /** Proveedor real: redirigir al checkout alojado (Stripe Checkout, Redsys, etc.). */
  | { kind: 'redirect'; sessionId: string; url: string };

export type SimulatedOutcome = 'aprobado' | 'rechazado';

export interface PaymentProvider {
  readonly id: 'simulado' | 'stripe';
  readonly label: string;
  /** true = ningún pago es real. La UI lo indica siempre. */
  readonly simulated: boolean;
  beginPayment(order: Order): Promise<PaymentSession>;
  /** Solo disponible en el proveedor simulado. */
  simulateResult?(order: Order, outcome: SimulatedOutcome): Promise<Order>;
}
