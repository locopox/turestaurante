import { uid } from '../../lib/storage';
import type { Order } from '../../types';
import type { DataService } from '../dataService';
import type { PaymentProvider, SimulatedOutcome } from './paymentProvider';

/**
 * Pasarela simulada. No pide datos de tarjeta, no contacta con ningún banco y
 * nunca marca un pedido como "pagado_verificado": el mejor resultado posible es `simulado`.
 */
export class SimulatedPaymentProvider implements PaymentProvider {
  readonly id = 'simulado' as const;
  readonly label = 'Pasarela de prueba';
  readonly simulated = true;

  constructor(private data: DataService) {}

  async beginPayment() {
    return { kind: 'simulated' as const, sessionId: uid('sim_') };
  }

  simulateResult(order: Order, outcome: SimulatedOutcome) {
    return outcome === 'aprobado'
      ? this.data.recordPaymentResult(order.id, 'simulado', `sim_${order.number}_${Date.now().toString(36)}`)
      : this.data.recordPaymentResult(order.id, 'fallido', null);
  }
}
