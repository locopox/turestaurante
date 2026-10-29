import { config } from '../config';
import type { DataService } from './dataService';
import { MockDataService } from './mock/mockDataService';
import type { PaymentProvider } from './payments/paymentProvider';
import { SimulatedPaymentProvider } from './payments/simulatedProvider';
import { StripePaymentProvider } from './payments/stripeProvider';
import { SupabaseDataService } from './supabase/supabaseDataService';

/** Punto único de configuración: cambia las variables VITE_* para conectar servicios reales. */
export const data: DataService =
  config.dataBackend === 'supabase'
    ? new SupabaseDataService(config.supabaseUrl, config.supabaseAnonKey)
    : new MockDataService();

export const payments: PaymentProvider =
  config.paymentProvider === 'stripe'
    ? new StripePaymentProvider(config.supabaseUrl, config.supabaseAnonKey)
    : new SimulatedPaymentProvider(data);

export type { DataService, Menu } from './dataService';
