import type { Order } from '../../types';
import type { PaymentProvider, PaymentSession } from './paymentProvider';

/**
 * Esqueleto para un proveedor real (ejemplo: Stripe Checkout).
 *
 * Flujo previsto:
 * 1. El navegador llama a la Edge Function `create-checkout` con el id del pedido.
 * 2. La función lee el importe desde la base de datos (nunca del navegador),
 *    crea la sesión con la clave secreta y devuelve la URL.
 * 3. El proveedor llama al webhook `payment-webhook`, que verifica la firma y
 *    marca el pedido como `pagado_verificado` o `fallido`.
 */
export class StripePaymentProvider implements PaymentProvider {
  readonly id = 'stripe' as const;
  readonly label = 'Pago con tarjeta';
  readonly simulated = false;

  constructor(private functionsBaseUrl: string, private anonKey: string) {}

  async beginPayment(order: Order): Promise<PaymentSession> {
    const res = await fetch(`${this.functionsBaseUrl}/functions/v1/create-checkout`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${this.anonKey}` },
      body: JSON.stringify({ orderId: order.id, returnUrl: window.location.href }),
    });
    if (!res.ok) throw new Error('No se pudo iniciar el pago. Puedes pagar en caja.');
    const { sessionId, url } = (await res.json()) as { sessionId: string; url: string };
    return { kind: 'redirect', sessionId, url };
  }
}
