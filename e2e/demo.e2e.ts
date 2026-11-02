import { expect, test } from '@playwright/test';

// Modo demo (sin base de datos): las invitaciones lo explican y el resto sigue funcionando.
test('demo: equipo, invitaciones, alta de restaurante y panel', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto('#admin');
  await page.getByRole('tab', { name: 'Equipo' }).click();
  await expect(page.getByText('Las invitaciones necesitan Supabase').first()).toBeVisible();
  await page.getByRole('button', { name: 'Nuevo restaurante' }).click();
  await expect(page.locator('#nr-owner')).toHaveCount(0);
  await page.locator('#nr-name').fill('Demo E2E');
  await page.getByRole('button', { name: 'Crear restaurante' }).click();
  await expect(page.getByText('Demo E2E creado')).toBeVisible();
  await page.goto('#invitaciones');
  await expect(page.getByText('Las invitaciones necesitan Supabase')).toBeVisible();
  await page.goto('#panel');
  await expect(page.locator('.appnav')).toBeVisible();
  await page.goto('#cliente');
  await expect(page.locator('main')).not.toBeEmpty();
  expect(errors).toEqual([]);
});
