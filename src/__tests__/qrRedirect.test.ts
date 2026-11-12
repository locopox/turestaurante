import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { parseHash } from '../hooks/useRoute';

/**
 * Script de index.html que convierte los enlaces de los QR (/r/<slug> y /r/<slug>/mesa/<n>) en las
 * direcciones con «#» que entiende la app. Se prueba el MISMO código que se publica: se lee de index.html.
 */
const html = readFileSync(join(__dirname, '..', '..', 'index.html'), 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
const code = scripts.find((s) => s.includes('/r/'));

/** Ejecuta el script con una dirección simulada. Devuelve adónde redirige, o null si no hace nada. */
function run(pathname: string, search = ''): string | null {
  let target: string | null = null;
  const location = { pathname, search, replace: (u: string) => { target = u; } };
  new Function('location', code!)(location);
  return target;
}

describe('redirección temprana de los enlaces QR (index.html)', () => {
  it('el script está en index.html, antes de cargar la app', () => {
    expect(code).toBeDefined();
    expect(html.indexOf('/r/')).toBeLessThan(html.indexOf('<script type="module"'));
  });

  it.each([
    ['/r/la-piazza/mesa/5', '/#pedir-la-piazza-mesa-5'],
    ['/r/la-piazza', '/#pedir-la-piazza'],
    ['/r/la-piazza/', '/#pedir-la-piazza'],
    ['/r/la-piazza/mesa/5/', '/#pedir-la-piazza-mesa-5'],
    ['/r/sakura-ramen/mesa/12', '/#pedir-sakura-ramen-mesa-12'],
    ['/r/el-fogon/mesa/999', '/#pedir-el-fogon-mesa-999'],
    ['/r/a1/mesa/1', '/#pedir-a1-mesa-1'],
    // La app publicada en una subcarpeta: se queda en esa carpeta
    ['/turestaurante/r/la-piazza/mesa/5', '/turestaurante/#pedir-la-piazza-mesa-5'],
    ['/a/b/r/la-piazza', '/a/b/#pedir-la-piazza'],
  ])('%s → %s', (path, expected) => {
    expect(run(path)).toBe(expected);
  });

  it('conserva los parámetros de la dirección (?origen=qr)', () => {
    expect(run('/r/la-piazza/mesa/5', '?origen=qr')).toBe('/?origen=qr#pedir-la-piazza-mesa-5');
  });

  it('la dirección resultante la entiende el enrutador de la app con el mismo restaurante y mesa', () => {
    const target = run('/r/sakura-ramen/mesa/7')!;
    expect(parseHash(target.slice(target.indexOf('#')))).toEqual({ view: 'cliente', slug: 'sakura-ramen', table: 7 });
    const pickup = run('/r/la-piazza')!;
    expect(parseHash(pickup.slice(pickup.indexOf('#')))).toEqual({ view: 'cliente', slug: 'la-piazza', table: undefined });
  });

  it.each([
    '/', '/index.html', '/404.html', '/r', '/r/', '/r//mesa/5', '/r//evil.com', '/r/https:%2F%2Fevil.com',
    '/r/..%2F..%2Fevil.com', '/r/../evil', '/r/La-Piazza/mesa/5', '/r/la_piazza', '/r/-la-piazza', '/r/la-piazza-',
    '/r/la--piazza', '/r/la-piazza/mesa/0', '/r/la-piazza/mesa/05', '/r/la-piazza/mesa/1000', '/r/la-piazza/mesa/-1',
    '/r/la-piazza/mesa/abc', '/r/la-piazza/mesa', '/r/la-piazza/mesa/5/extra', '/r/la-piazza/otra', '/rr/la-piazza',
    '/x/r/la-piazza/mesa/5.html', '/r/la piazza', '/r/la-piazza%0a/mesa/5',
    // Redirección abierta: con «//» delante, el destino «//evil.com/…» sería OTRO sitio
    '//evil.com/r/la-piazza', '//evil.com/r/la-piazza/mesa/5', '/sub//r/la-piazza', '///r/la-piazza',
    '/a//b/r/la-piazza/mesa/5',
  ])('dirección incorrecta %s: no redirige', (path) => {
    expect(run(path)).toBeNull();
  });

  it('nunca sale del sitio: el destino siempre empieza por «/» y no por «//»', () => {
    for (const p of ['/r/la-piazza', '/r/la-piazza/mesa/5', '/sub/r/x/mesa/1', '//evil.com/r/la-piazza']) {
      const t = run(p);
      if (t !== null) {
        expect(t.startsWith('/')).toBe(true);
        expect(t.startsWith('//')).toBe(false);
      }
    }
  });

  it('no afecta a los enlaces con «#» que ya existen (la ruta es «/»)', () => {
    expect(run('/', '')).toBeNull();
  });
});
