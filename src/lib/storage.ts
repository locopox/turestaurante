// localStorage puede no existir o lanzar (modo privado, iframes); nunca debe romper la app.
export const safeStorage = {
  get<T>(key: string, fallback: T): T {
    try {
      const raw = window.localStorage.getItem(key);
      return raw ? (JSON.parse(raw) as T) : fallback;
    } catch {
      return fallback;
    }
  },
  set(key: string, value: unknown) {
    try {
      window.localStorage.setItem(key, JSON.stringify(value));
    } catch {
      /* sin persistencia: seguimos en memoria */
    }
  },
  remove(key: string) {
    try {
      window.localStorage.removeItem(key);
    } catch {
      /* noop */
    }
  },
};

export function uid(prefix = ''): string {
  try {
    return prefix + crypto.randomUUID();
  } catch {
    return prefix + Math.random().toString(36).slice(2) + Date.now().toString(36);
  }
}
