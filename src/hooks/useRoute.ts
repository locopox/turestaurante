import { useEffect, useState } from 'react';

export type Route =
  | { view: 'inicio' }
  | { view: 'cliente'; slug?: string; table?: number }
  | { view: 'panel' }
  | { view: 'cocina' }
  | { view: 'admin' };

/**
 * Rutas por hash sencillas (#panel, #cocina, #pedir-la-piazza-mesa-5).
 * En producción se pueden sustituir por rutas reales: /r/:slug/mesa/:n
 */
export function parseHash(hash: string): Route {
  const h = decodeURIComponent(hash.replace(/^#\/?/, ''));
  if (h === 'panel' || h === 'cocina' || h === 'admin') return { view: h };
  if (h === 'cliente') return { view: 'cliente' };
  const m = h.match(/^pedir-(.+?)(?:-mesa-(\d+))?$/);
  if (m) return { view: 'cliente', slug: m[1], table: m[2] ? Number(m[2]) : undefined };
  return { view: 'inicio' };
}

export const hrefFor = (r: Route): string => {
  if (r.view === 'cliente' && r.slug) return `#pedir-${r.slug}${r.table ? `-mesa-${r.table}` : ''}`;
  return r.view === 'inicio' ? '#inicio' : `#${r.view}`;
};

export function useRoute(): Route {
  const [route, setRoute] = useState(() => parseHash(window.location.hash));
  useEffect(() => {
    const on = () => {
      setRoute(parseHash(window.location.hash));
      window.scrollTo(0, 0);
    };
    window.addEventListener('hashchange', on);
    return () => window.removeEventListener('hashchange', on);
  }, []);
  return route;
}
