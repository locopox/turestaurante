import { expect, test, type Page } from '@playwright/test';

/**
 * Enlaces de los códigos QR (/r/<slug> y /r/<slug>/mesa/<n>) en modo demo, sin base de datos.
 * Se ejecuta dos veces (playwright.config.ts):
 *  - «qr»: servidor de desarrollo de Vite;
 *  - «qr-build»: la app COMPILADA con base './' y servida con `vite preview` desde una carpeta temporal
 *    (nunca dist/). Comprueba además que la compilación incluye 404.html.
 */

const origin = (page: Page) => new URL(page.url()).origin;
const isBuild = () => test.info().project.name === 'qr-build';

async function expectMenu(page: Page, restaurant: string, table?: number) {
  await expect(page.locator('.main--customer')).toBeVisible();
  await expect(page.locator('.appbar, header').first()).toContainText(restaurant);
  if (table) await expect(page.getByText(`Mesa ${table}`).first()).toBeVisible();
}

test.describe('abrir un enlace QR directamente', () => {
  for (const [path, hash, restaurant, table] of [
    ['/r/la-piazza/mesa/5', '#pedir-la-piazza-mesa-5', 'La Piazza', 5],
    ['/r/la-piazza', '#pedir-la-piazza', 'La Piazza', undefined],
    ['/r/sakura-ramen/mesa/2', '#pedir-sakura-ramen-mesa-2', 'Sakura Ramen', 2],
    ['/r/la-piazza/mesa/5/', '#pedir-la-piazza-mesa-5', 'La Piazza', 5],
  ] as const) {
    test(`${path} abre la carta${table ? ` en la mesa ${table}` : ' para recoger'}`, async ({ page }) => {
      const res = await page.goto(path);
      expect(res?.status()).toBe(200);
      await expect(page).toHaveURL(`${origin(page)}/${hash}`);
      await expectMenu(page, restaurant, table);
    });
  }

  test('conserva los parámetros de la dirección (?origen=qr)', async ({ page }) => {
    await page.goto('/r/la-piazza/mesa/5?origen=qr');
    await expect(page).toHaveURL(`${origin(page)}/?origen=qr#pedir-la-piazza-mesa-5`);
    await expectMenu(page, 'La Piazza', 5);
  });

  test('la redirección no deja una entrada de más en el historial', async ({ page }) => {
    await page.goto('/r/la-piazza/mesa/5');
    await expectMenu(page, 'La Piazza', 5);
    expect(await page.evaluate(() => history.length)).toBe(2); // pestaña nueva + la carta
  });

  test('restaurante que no existe: aviso claro, no una página en blanco', async ({ page }) => {
    await page.goto('/r/no-existe/mesa/3');
    await expect(page).toHaveURL(`${origin(page)}/#pedir-no-existe-mesa-3`);
    await expect(page.getByText('No encontramos este restaurante')).toBeVisible();
  });
});

test.describe('las direcciones con «#» siguen funcionando igual', () => {
  for (const [path, check] of [
    ['/#pedir-la-piazza-mesa-5', async (p: Page) => expectMenu(p, 'La Piazza', 5)],
    ['/#pedir-la-piazza', async (p: Page) => expectMenu(p, 'La Piazza')],
    ['/#inicio', async (p: Page) => expect(p.getByText('Cliente · mesa 5')).toBeVisible()],
    ['/#panel', async (p: Page) => expect(p.locator('.appnav .is-active')).toHaveText(/Panel/)],
    ['/#cocina', async (p: Page) => expect(p.locator('.appnav .is-active')).toHaveText(/Cocina/)],
    ['/#admin', async (p: Page) => expect(p.getByRole('tab', { name: 'QR' })).toBeVisible()],
  ] as const) {
    test(path, async ({ page }) => {
      await page.goto(path);
      await expect(page).toHaveURL(`${origin(page)}${path}`);
      await check(page);
    });
  }
});

test.describe('navegando desde la aplicación', () => {
  test('Inicio → «Cliente · mesa 5»', async ({ page }) => {
    await page.goto('/#inicio');
    await page.getByText('Cliente · mesa 5').click();
    await expect(page).toHaveURL(`${origin(page)}/#pedir-la-piazza-mesa-5`);
    await expectMenu(page, 'La Piazza', 5);
  });

  test('Admin → QR: los códigos siguen apuntando a /r/…, y «Probar» abre la mesa', async ({ page }) => {
    await page.goto('/#admin');
    await page.getByRole('tab', { name: 'QR' }).click();
    await expect(page.locator('.notice').filter({ hasText: 'Cada QR' })).toContainText('/r/la-piazza/');
    await expect(page.locator('.qr-card')).toHaveCount(13); // para recoger + 12 mesas de La Piazza
    await page.locator('.qr-card').filter({ has: page.locator('strong', { hasText: /^Mesa 5$/ }) }).getByText('Probar').click();
    await expect(page).toHaveURL(`${origin(page)}/#pedir-la-piazza-mesa-5`);
    await expectMenu(page, 'La Piazza', 5);
    await page.goBack();
    await expect(page).toHaveURL(`${origin(page)}/#admin`);
  });
});

test.describe('direcciones incorrectas: no redirigen y nunca salen del sitio', () => {
  for (const path of [
    '/r/La-Piazza/mesa/5', '/r/la-piazza/mesa/abc', '/r/la-piazza/mesa/0', '/r/la-piazza/mesa/1000',
    '/r/la-piazza/mesa/5/extra', '/r/la_piazza', '/r//evil.com', '/r/..%2F..%2Fevil.com',
    '//evil.com/r/la-piazza', '//evil.com/r/la-piazza/mesa/5',
  ]) {
    test(path, async ({ page, baseURL }) => {
      const target = new URL(baseURL!);
      await page.goto(`${target.origin}${path}`).catch(() => null);
      await page.waitForLoadState('domcontentloaded');
      const now = new URL(page.url());
      expect(now.host).toBe(target.host);
      expect(now.hash).not.toContain('pedir-');
    });
  }
});

test('la compilación incluye 404.html con la misma redirección', async ({ request }) => {
  test.skip(!isBuild(), 'solo en la app compilada');
  const index = await request.get('/index.html');
  const notFound = await request.get('/404.html');
  expect(notFound.status()).toBe(200);
  const body = await notFound.text();
  expect(body).toBe(await index.text());
  expect(body).toContain("location.replace(m[1] + '/' + location.search + '#pedir-'");
  expect(body).toContain('./assets/'); // base './': rutas relativas, como siempre
});
