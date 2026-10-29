import { config, configBlocked } from '../config';
import type { DataService } from './dataService';
import { MockDataService } from './mock/mockDataService';
import type { PaymentProvider } from './payments/paymentProvider';
import { SimulatedPaymentProvider } from './payments/simulatedProvider';
import { SupabaseDataService } from './supabase/supabaseDataService';

/**
 * Servicio que no hace nada: se usa cuando la configuración es incorrecta. La app muestra
 * entonces la pantalla de configuración y nunca cae en silencio a los datos de demostración.
 */
const unavailable = new Proxy({} as DataService, {
  get: (_t, prop) => {
    if (prop === 'kind') return 'supabase';
    if (prop === 'requiresLogin') return true;
    return () => Promise.reject(new Error('La configuración de la app está incompleta.'));
  },
});

/** Punto único de configuración: cambia las variables VITE_* para conectar servicios reales. */
export const data: DataService =
  config.dataBackend === 'mock'
    ? new MockDataService()
    : configBlocked
      ? unavailable
      : new SupabaseDataService(config.supabaseUrl, config.supabaseAnonKey);

/**
 * Pagos: de momento solo existe la pasarela simulada, y la UI solo la ofrece en el modo demo
 * (ver `onlinePaymentsAvailable` en config.ts). `payments/stripeProvider.ts` es un esqueleto
 * para la fase de pagos reales y no se usa.
 */
export const payments: PaymentProvider = new SimulatedPaymentProvider(data);

export type { DataService, Menu } from './dataService';
