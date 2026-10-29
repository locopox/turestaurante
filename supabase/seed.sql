-- TuRestaurante · datos de demostración de La Piazza (ficticios).
-- Ejecutar DESPUÉS de schema.sql. Se puede ejecutar varias veces: usa identificadores fijos
-- y «on conflict do nothing», así que no duplica nada ni sobrescribe cambios hechos después.
-- El pago online queda DESACTIVADO: no hay integración real con un proveedor de pagos.

begin;

insert into public.restaurants (id, slug, name, tagline, address, phone, active, tables,
  pickup_enabled, online_payment_enabled, counter_payment_enabled, prep_minutes)
values ('5e5e0000-0000-4000-8000-000000000001', 'la-piazza', 'La Piazza', 'Pizzería y trattoria · horno de leña',
  'Calle Mayor 12, Madrid', '910 000 000', true, 12, true, false, true, 18)
on conflict (id) do nothing;

insert into public.categories (id, restaurant_id, name, sort) values
  ('5e5e0000-0000-4000-8000-000000000101', '5e5e0000-0000-4000-8000-000000000001', 'Entrantes', 1),
  ('5e5e0000-0000-4000-8000-000000000102', '5e5e0000-0000-4000-8000-000000000001', 'Pizzas', 2),
  ('5e5e0000-0000-4000-8000-000000000103', '5e5e0000-0000-4000-8000-000000000001', 'Pastas', 3),
  ('5e5e0000-0000-4000-8000-000000000104', '5e5e0000-0000-4000-8000-000000000001', 'Postres', 4),
  ('5e5e0000-0000-4000-8000-000000000105', '5e5e0000-0000-4000-8000-000000000001', 'Bebidas', 5)
on conflict (id) do nothing;

insert into public.products (id, category_id, name, description, price_cents, art, allergens, tags, available, sort, restaurant_id)
select v.id::uuid, v.category_id::uuid, v.name, v.description, v.price_cents, v.art, v.allergens, v.tags, v.available, v.sort,
  '5e5e0000-0000-4000-8000-000000000001'::uuid
from (values
  ('5e5e0000-0000-4000-8000-000000000201', '5e5e0000-0000-4000-8000-000000000101', 'Bruschetta clásica', 'Pan de masa madre tostado, tomate, ajo, albahaca y aceite de oliva virgen extra.', 650, 'bread', array['gluten']::text[], array['vegano']::text[], true, 1),
  ('5e5e0000-0000-4000-8000-000000000202', '5e5e0000-0000-4000-8000-000000000101', 'Ensalada Caprese', 'Tomate de temporada, mozzarella di bufala, albahaca fresca y pesto.', 950, 'salad', array['lácteos', 'frutos secos']::text[], array['vegetariano', 'sin_gluten']::text[], true, 2),
  ('5e5e0000-0000-4000-8000-000000000203', '5e5e0000-0000-4000-8000-000000000101', 'Burrata con rúcula', 'Burrata cremosa, rúcula, tomate cherry asado y reducción de balsámico.', 1250, 'salad', array['lácteos']::text[], array['vegetariano', 'nuevo']::text[], true, 3),
  ('5e5e0000-0000-4000-8000-000000000204', '5e5e0000-0000-4000-8000-000000000102', 'Margherita', 'Tomate San Marzano, mozzarella fior di latte y albahaca.', 1050, 'pizza', array['gluten', 'lácteos']::text[], array['vegetariano']::text[], true, 4),
  ('5e5e0000-0000-4000-8000-000000000205', '5e5e0000-0000-4000-8000-000000000102', 'Diavola', 'Tomate, mozzarella, salami picante y aceite de guindilla.', 1250, 'pizza', array['gluten', 'lácteos']::text[], array['picante']::text[], true, 5),
  ('5e5e0000-0000-4000-8000-000000000206', '5e5e0000-0000-4000-8000-000000000102', 'Quattro formaggi', 'Mozzarella, gorgonzola, parmesano y taleggio.', 1350, 'pizza', array['gluten', 'lácteos']::text[], array['vegetariano']::text[], true, 6),
  ('5e5e0000-0000-4000-8000-000000000207', '5e5e0000-0000-4000-8000-000000000102', 'Prosciutto e funghi', 'Tomate, mozzarella, jamón cocido y champiñones.', 1300, 'pizza', array['gluten', 'lácteos']::text[], '{}', true, 7),
  ('5e5e0000-0000-4000-8000-000000000208', '5e5e0000-0000-4000-8000-000000000102', 'Vegetale', 'Calabacín, berenjena, pimiento asado, cebolla roja y mozzarella.', 1200, 'pizza', array['gluten', 'lácteos']::text[], array['vegetariano']::text[], false, 8),
  ('5e5e0000-0000-4000-8000-000000000209', '5e5e0000-0000-4000-8000-000000000103', 'Spaghetti carbonara', 'Guanciale, yema de huevo, pecorino romano y pimienta negra.', 1250, 'pasta', array['gluten', 'huevo', 'lácteos']::text[], '{}', true, 9),
  ('5e5e0000-0000-4000-8000-000000000210', '5e5e0000-0000-4000-8000-000000000103', 'Trofie al pesto', 'Pesto genovés de albahaca, piñones y parmesano.', 1150, 'pasta', array['gluten', 'lácteos', 'frutos secos']::text[], array['vegetariano']::text[], true, 10),
  ('5e5e0000-0000-4000-8000-000000000211', '5e5e0000-0000-4000-8000-000000000103', 'Penne all’arrabbiata', 'Salsa de tomate con ajo y guindilla.', 1050, 'pasta', array['gluten']::text[], array['vegano', 'picante']::text[], true, 11),
  ('5e5e0000-0000-4000-8000-000000000212', '5e5e0000-0000-4000-8000-000000000104', 'Tiramisú de la casa', 'Bizcocho de soletilla, café, mascarpone y cacao.', 600, 'dessert', array['gluten', 'huevo', 'lácteos']::text[], '{}', true, 12),
  ('5e5e0000-0000-4000-8000-000000000213', '5e5e0000-0000-4000-8000-000000000104', 'Panna cotta', 'Con coulis de frutos rojos.', 550, 'dessert', array['lácteos']::text[], array['sin_gluten']::text[], true, 13),
  ('5e5e0000-0000-4000-8000-000000000214', '5e5e0000-0000-4000-8000-000000000104', 'Espresso', 'Café italiano de tueste natural.', 180, 'coffee', '{}', '{}', true, 14),
  ('5e5e0000-0000-4000-8000-000000000215', '5e5e0000-0000-4000-8000-000000000105', 'Agua mineral 50 cl', 'Natural o con gas.', 220, 'water', '{}', array['vegano']::text[], true, 15),
  ('5e5e0000-0000-4000-8000-000000000216', '5e5e0000-0000-4000-8000-000000000105', 'Limonada casera', 'Limón, hierbabuena y un toque de jengibre.', 350, 'soda', '{}', array['vegano']::text[], true, 16),
  ('5e5e0000-0000-4000-8000-000000000217', '5e5e0000-0000-4000-8000-000000000105', 'Copa de Chianti', 'Vino tinto D.O.C.G., Toscana.', 450, 'wine', array['sulfitos']::text[], '{}', true, 17)
) as v (id, category_id, name, description, price_cents, art, allergens, tags, available, sort)
on conflict (id) do nothing;

commit;
