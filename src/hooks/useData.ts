import { useCallback, useEffect, useState } from 'react';
import { data, type Menu } from '../services';
import type { AuditEntry, KitchenTicket, Order, Restaurant, StaffMember, StaffSession } from '../types';

interface Loadable<T> {
  value: T | undefined;
  loading: boolean;
  error: string | null;
  reload: () => void;
}

function useLoad<T>(load: () => Promise<T>, subscribe: ((cb: () => void) => () => void) | null, deps: unknown[]): Loadable<T> {
  const [value, setValue] = useState<T>();
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const reload = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    let alive = true;
    load()
      .then((v) => alive && (setValue(v), setError(null)))
      .catch((e: Error) => alive && setError(e.message))
      .finally(() => alive && setLoading(false));
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick]);

  useEffect(() => (subscribe ? subscribe(reload) : undefined),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    deps);

  return { value, loading, error, reload };
}

export const useRestaurants = () =>
  useLoad<Restaurant[]>(() => data.listRestaurants(), (cb) => data.subscribeCatalog(cb), []);

export const useMenu = (restaurantId: string | undefined) =>
  useLoad<Menu>(
    () => (restaurantId ? data.getMenu(restaurantId) : Promise.resolve({ categories: [], products: [] })),
    (cb) => data.subscribeCatalog(cb),
    [restaurantId],
  );

export const useOrders = (restaurantId: string | undefined) =>
  useLoad<Order[]>(
    () => (restaurantId ? data.listOrders(restaurantId) : Promise.resolve([])),
    restaurantId ? (cb) => data.subscribeOrders(restaurantId, cb) : null,
    [restaurantId],
  );

/** Pedido del cliente: solo se puede leer con su token secreto. */
export const useCustomerOrder = (orderId: string | null, accessToken: string | null) =>
  useLoad<Order | null>(
    () => (orderId && accessToken ? data.getCustomerOrder(orderId, accessToken) : Promise.resolve(null)),
    orderId && accessToken ? (cb) => data.subscribeCustomerOrder(orderId, accessToken, cb) : null,
    [orderId, accessToken],
  );

/** Sesión del personal. `value` es null si no hay sesión. */
export const useSession = () => useLoad<StaffSession | null>(() => data.getSession(), (cb) => data.onAuthChange(cb), []);

/** Comandas de cocina (sin datos personales ni importes). */
export const useKitchenOrders = (restaurantId: string) =>
  useLoad<KitchenTicket[]>(() => data.listKitchenOrders(restaurantId), (cb) => data.subscribeKitchen(restaurantId, cb), [restaurantId]);

export const useStaff = (restaurantId: string) =>
  useLoad<StaffMember[]>(() => data.listStaff(restaurantId), null, [restaurantId]);

export const useAudit = (restaurantId: string | null) =>
  useLoad<AuditEntry[]>(() => data.listAudit(restaurantId), null, [restaurantId]);

/** Reloj que se actualiza periódicamente (tiempos de espera en cocina). */
export function useNow(intervalMs = 30000) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}
