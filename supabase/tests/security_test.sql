-- Pruebas de seguridad y reglas de negocio del esquema.
-- SOLO para una base de datos LOCAL y desechable (ver supabase/tests/run.sh). NUNCA en Supabase.
-- Requiere: supabase_shim.sql, schema.sql y seed.sql ya ejecutados.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null

-- ===================== Utilidades de prueba =====================
create schema tests;
create table tests.results (id serial primary key, name text not null, pass boolean not null, detail text);
create table tests.vars (key text primary key, val jsonb);
grant usage on schema tests to anon, authenticated, service_role;
grant all on all tables in schema tests to anon, authenticated, service_role;
grant all on all sequences in schema tests to anon, authenticated, service_role;

create function tests.ok(cond boolean, name text, detail text default null) returns void language sql as $$
  insert into tests.results (name, pass, detail) values (name, coalesce(cond, false), detail)
$$;
-- Ejecuta q con el rol actual y comprueba que falla con un mensaje que encaja con pattern.
create function tests.throws(q text, pattern text, name text) returns void language plpgsql as $$
begin
  begin
    execute q;
  exception when others then
    insert into tests.results (name, pass, detail) values (name, sqlerrm ~* pattern, sqlerrm);
    return;
  end;
  insert into tests.results (name, pass, detail) values (name, false, 'no se produjo ningún error');
end $$;
-- Ejecuta q y devuelve cuántas filas afectó (para comprobar que RLS bloquea en silencio).
create function tests.affected(q text) returns int language plpgsql as $$
declare n int; begin execute q; get diagnostics n = row_count; return n; end $$;
create function tests.claims(r text, sub uuid) returns void language sql as $$
  select set_config('request.jwt.claims', case when r is null then '' else json_build_object('role', r, 'sub', sub)::text end, false)
$$;
create function tests.tok(n int) returns text language sql immutable as $$ select lpad(to_hex(n), 64, '0') $$;
create function tests.v(k text) returns jsonb language sql stable as $$ select val from tests.vars where key = k $$;
create function tests.id(k text) returns uuid language sql stable as $$ select (val ->> 'id')::uuid from tests.vars where key = k $$;

-- Identificadores
-- La Piazza (seed): restaurante ...0001; Margherita ...0204 (10,50 €), Agua ...0215 (2,20 €), Vegetale ...0208 (agotada)
create function tests.piazza() returns uuid language sql immutable as $$ select '5e5e0000-0000-4000-8000-000000000001'::uuid $$;
create function tests.marg() returns uuid language sql immutable as $$ select '5e5e0000-0000-4000-8000-000000000204'::uuid $$;
create function tests.agua() returns uuid language sql immutable as $$ select '5e5e0000-0000-4000-8000-000000000215'::uuid $$;
create function tests.vegetale() returns uuid language sql immutable as $$ select '5e5e0000-0000-4000-8000-000000000208'::uuid $$;
create function tests.otro() returns uuid language sql immutable as $$ select 'b0000000-0000-4000-8000-000000000001'::uuid $$;
create function tests.otro_prod() returns uuid language sql immutable as $$ select 'b0000000-0000-4000-8000-000000000201'::uuid $$;

-- Pedido base válido: mesa 5, pago en caja, 2 Margherita + 1 agua = 23,20 €.
create function tests.payload(token int, extra jsonb default '{}'::jsonb) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'restaurantId', tests.piazza(), 'mode', 'mesa', 'table', 5, 'paymentMethod', 'caja', 'accessToken', tests.tok(token),
    'items', jsonb_build_array(
      jsonb_build_object('productId', tests.marg(), 'quantity', 2),
      jsonb_build_object('productId', tests.agua(), 'quantity', 1))) || extra
$$;

-- Pedido online en «Otro Sitio» (Plato del día, 9 €): mesa 1, qty unidades.
create function tests.online(token int, qty int) returns jsonb language sql stable as $$
  select jsonb_build_object('restaurantId', tests.otro(), 'mode', 'mesa', 'table', 1, 'paymentMethod', 'online',
    'accessToken', tests.tok(token), 'items', jsonb_build_array(jsonb_build_object('productId', tests.otro_prod(), 'quantity', qty)))
$$;

-- Usuario de prueba por sufijo: tests.u('a1') = a0000000-0000-4000-8000-0000000000a1
create function tests.u(code text) returns uuid language sql immutable as $$ select ('a0000000-0000-4000-8000-0000000000' || code)::uuid $$;
-- ¿Aparece el pedido en la vista de cocina de ese restaurante? (con el rol actual)
create function tests.in_kitchen(rid uuid, oid uuid) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(public.kitchen_orders(rid)) t where (t ->> 'id')::uuid = oid)
$$;

-- ===================== Datos de prueba (como postgres) =====================
-- Segundo restaurante, con pago online ACTIVADO desde el servidor (lo permite el SQL Editor).
insert into public.restaurants (id, slug, name, active, tables, pickup_enabled, online_payment_enabled, counter_payment_enabled)
values (tests.otro(), 'otro-sitio', 'Otro Sitio', true, 4, true, true, true);
insert into public.categories (id, restaurant_id, name) values ('b0000000-0000-4000-8000-000000000101', tests.otro(), 'Platos');
insert into public.products (id, restaurant_id, category_id, name, price_cents)
values (tests.otro_prod(), tests.otro(), 'b0000000-0000-4000-8000-000000000101', 'Plato del día', 900);

insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-0000000000a1', 'owner@piazza.test'),
  ('a0000000-0000-4000-8000-0000000000a2', 'manager@piazza.test'),
  ('a0000000-0000-4000-8000-0000000000a3', 'waiter@piazza.test'),
  ('a0000000-0000-4000-8000-0000000000a4', 'kitchen@piazza.test'),
  ('a0000000-0000-4000-8000-0000000000b1', 'owner@otro.test'),
  ('a0000000-0000-4000-8000-0000000000b4', 'kitchen@otro.test'),
  ('a0000000-0000-4000-8000-0000000000ad', 'admin@plataforma.test'),
  ('a0000000-0000-4000-8000-0000000000ee', 'sin-rol@test');
insert into public.restaurant_staff (restaurant_id, user_id, role) values
  (tests.piazza(), 'a0000000-0000-4000-8000-0000000000a1', 'owner'),
  (tests.piazza(), 'a0000000-0000-4000-8000-0000000000a2', 'manager'),
  (tests.piazza(), 'a0000000-0000-4000-8000-0000000000a3', 'waiter'),
  (tests.piazza(), 'a0000000-0000-4000-8000-0000000000a4', 'kitchen'),
  (tests.otro(), 'a0000000-0000-4000-8000-0000000000b1', 'owner'),
  (tests.otro(), 'a0000000-0000-4000-8000-0000000000b4', 'kitchen');
insert into public.platform_admins (user_id) values ('a0000000-0000-4000-8000-0000000000ad');

-- ===================== 1. PEDIDOS (cliente anónimo) =====================
select tests.claims('anon', null);
set role anon;

insert into tests.vars select 'o1', public.create_order(tests.payload(1));
select tests.ok(tests.v('o1') ->> 'total' = '2320', 'pedido válido: total calculado en la base de datos (23,20 €)', tests.v('o1') ->> 'total');
select tests.ok(tests.v('o1') ->> 'number' = '101', 'pedido válido: número 101');
select tests.ok(tests.v('o1') ->> 'paymentStatus' = 'pendiente_caja', 'pedido válido: pago pendiente en caja');
select tests.ok(not (tests.v('o1') ? 'customerPhone'), 'la vista del cliente no incluye el teléfono');

insert into tests.vars select 'o_precio', public.create_order(tests.payload(2, jsonb_build_object('total', 1, 'items', jsonb_build_array(
  jsonb_build_object('productId', tests.marg(), 'quantity', 1, 'price', 1, 'unitPrice', 1, 'unit_price_cents', 1)))));
select tests.ok(tests.v('o_precio') ->> 'total' = '1050', 'precios y total enviados por el navegador se ignoran', tests.v('o_precio') ->> 'total');

select tests.throws(format('select public.create_order(%L)', tests.payload(10, '{"items": []}')), 'carrito está vacío', 'rechaza carrito vacío');
select tests.throws(format('select public.create_order(%L)', tests.payload(11) - 'items'), 'carrito está vacío', 'rechaza pedido sin lista de productos');
select tests.throws(format('select public.create_order(%L)', tests.payload(12, '{"items": {"a": 1}}')), 'carrito está vacío', 'rechaza productos que no son una lista');
select tests.throws(format('select public.create_order(%L)', tests.payload(13, jsonb_build_object('items', jsonb_build_array(jsonb_build_object('productId', tests.marg(), 'quantity', 0))))), 'entre 1 y 20', 'rechaza cantidad 0');
select tests.throws(format('select public.create_order(%L)', tests.payload(14, jsonb_build_object('items', jsonb_build_array(jsonb_build_object('productId', tests.marg(), 'quantity', 21))))), 'entre 1 y 20', 'rechaza cantidad 21');
select tests.throws(format('select public.create_order(%L)', tests.payload(15, jsonb_build_object('items', jsonb_build_array(jsonb_build_object('productId', tests.marg(), 'quantity', -1))))), 'cantidad no válida', 'rechaza cantidad negativa');
select tests.throws(format('select public.create_order(%L)', tests.payload(16, jsonb_build_object('items', jsonb_build_array(jsonb_build_object('productId', tests.marg(), 'quantity', 1.5))))), 'cantidad no válida', 'rechaza cantidad decimal');
select tests.throws(format('select public.create_order(%L)', tests.payload(17, jsonb_build_object('items', jsonb_build_array(jsonb_build_object('productId', tests.marg()))))), 'cantidad no válida', 'rechaza línea sin cantidad');
select tests.throws(format('select public.create_order(%L)', tests.payload(18, jsonb_build_object('items',
  (select jsonb_agg(jsonb_build_object('productId', tests.marg(), 'quantity', 1)) from generate_series(1, 31))))), 'máximo 30 productos', 'rechaza más de 30 líneas');
select tests.throws(format('select public.create_order(%L)', tests.payload(19, jsonb_build_object('items',
  (select jsonb_agg(jsonb_build_object('productId', tests.marg(), 'quantity', 20)) from generate_series(1, 6))))), 'máximo 100 unidades', 'rechaza más de 100 unidades');
select tests.throws(format('select public.create_order(%L)', tests.payload(20, jsonb_build_object('items', jsonb_build_array(jsonb_build_object('productId', tests.vegetale(), 'quantity', 1))))), 'agotado', 'rechaza producto agotado');
select tests.throws(format('select public.create_order(%L)', tests.payload(21, jsonb_build_object('items', jsonb_build_array(jsonb_build_object('productId', tests.otro_prod(), 'quantity', 1))))), 'no pertenece a esta carta', 'rechaza producto de otro restaurante');
select tests.throws(format('select public.create_order(%L)', tests.payload(22, jsonb_build_object('items', jsonb_build_array(jsonb_build_object('productId', 'no-es-un-id', 'quantity', 1))))), 'producto no válido', 'rechaza identificador de producto inválido');
select tests.throws(format('select public.create_order(%L)', tests.payload(23, '{"table": 0}')), 'mesa 0 no existe', 'rechaza mesa 0');
select tests.throws(format('select public.create_order(%L)', tests.payload(24, '{"table": 13}')), 'mesa 13 no existe', 'rechaza mesa fuera de rango (La Piazza tiene 12)');
select tests.throws(format('select public.create_order(%L)', tests.payload(25) - 'table'), 'número de mesa válido', 'rechaza pedido en mesa sin número');
select tests.throws(format('select public.create_order(%L)', tests.payload(26, '{"table": "5; drop table orders"}')), 'número de mesa válido', 'rechaza mesa con texto');
select tests.throws(format('select public.create_order(%L)', tests.payload(27, '{"mode": "domicilio"}')), 'mesa o para recoger', 'rechaza modo desconocido');
select tests.throws(format('select public.create_order(%L)', tests.payload(28, '{"mode": "recoger"}')), 'nombre de 2 a 60', 'recogida: exige nombre');
select tests.throws(format('select public.create_order(%L)', tests.payload(29, '{"mode": "recoger", "customerName": " A "}')), 'nombre de 2 a 60', 'recogida: rechaza nombre de 1 letra');
select tests.throws(format('select public.create_order(%L)', tests.payload(30, jsonb_build_object('mode', 'recoger', 'customerName', repeat('x', 61)))), 'nombre de 2 a 60', 'recogida: rechaza nombre demasiado largo');
select tests.throws(format('select public.create_order(%L)', tests.payload(31, '{"mode": "recoger", "customerName": "Ana", "customerPhone": "llámame"}')), 'teléfono no es válido', 'recogida: rechaza teléfono inválido');
select tests.throws(format('select public.create_order(%L)', tests.payload(32, '{"mode": "recoger", "customerName": "Ana", "pickupTime": "25:00"}')), 'hora de recogida', 'recogida: rechaza hora inválida');
insert into tests.vars select 'o_rec', public.create_order(tests.payload(33, '{"mode": "recoger", "customerName": "Ana", "customerPhone": "600 000 000", "table": 3}'));
select tests.ok(tests.v('o_rec') ->> 'pickupTime' = 'asap' and tests.v('o_rec') -> 'table' = 'null'::jsonb,
  'recogida válida: hora por defecto «asap» y sin mesa aunque se envíe');
select tests.throws(format('select public.create_order(%L)', tests.payload(34, '{"paymentMethod": "online"}')), 'pago online no está disponible', 'rechaza pago online desactivado (configuración inicial)');
select tests.throws(format('select public.create_order(%L)', tests.payload(35, '{"paymentMethod": "bizum"}')), 'método de pago', 'rechaza método de pago desconocido');
select tests.throws(format('select public.create_order(%L)', tests.payload(36, jsonb_build_object('notes', repeat('x', 201)))), '200 caracteres', 'rechaza comentarios de más de 200 caracteres');
select tests.throws(format('select public.create_order(%L)', tests.payload(37, jsonb_build_object('items', jsonb_build_array(jsonb_build_object('productId', tests.marg(), 'quantity', 1, 'notes', repeat('x', 121)))))), '120 caracteres', 'rechaza notas de producto de más de 120 caracteres');
select tests.throws(format('select public.create_order(%L)', tests.payload(38) - 'accessToken'), 'código de seguimiento', 'rechaza pedido sin token');
select tests.throws(format('select public.create_order(%L)', tests.payload(39, '{"accessToken": "1234"}')), 'código de seguimiento', 'rechaza token corto');
select tests.throws(format('select public.create_order(%L)', tests.payload(40, '{"restaurantId": "nada"}')), 'restaurante no válido', 'rechaza restaurante inválido');
select tests.throws(format('select public.create_order(%L)', tests.payload(41, '{"restaurantId": "00000000-0000-4000-8000-000000000000"}')), 'no acepta pedidos', 'rechaza restaurante inexistente');

-- Fallo parcial: la primera línea es válida y la segunda no -> no se guarda nada
reset role;
insert into tests.vars select 'antes', jsonb_build_object('pedidos', (select count(*) from public.orders),
  'lineas', (select count(*) from public.order_items), 'contador', (select last_number from private.order_counters where restaurant_id = tests.piazza()));
set role anon;
select tests.throws(format('select public.create_order(%L)', tests.payload(42, jsonb_build_object('items', jsonb_build_array(
  jsonb_build_object('productId', tests.marg(), 'quantity', 1), jsonb_build_object('productId', tests.vegetale(), 'quantity', 1))))),
  'agotado', 'fallo en la segunda línea: se rechaza el pedido');
reset role;
select tests.ok(tests.v('antes') = jsonb_build_object('pedidos', (select count(*) from public.orders),
  'lineas', (select count(*) from public.order_items), 'contador', (select last_number from private.order_counters where restaurant_id = tests.piazza())),
  'fallo parcial: no quedan pedidos, líneas ni números consumidos');

-- Idempotencia: reenviar con el mismo token devuelve el mismo pedido
select tests.claims('anon', null);
set role anon;
insert into tests.vars select 'o1_bis', public.create_order(tests.payload(1, jsonb_build_object('items', jsonb_build_array(jsonb_build_object('productId', tests.agua(), 'quantity', 9)))));
select tests.ok(tests.id('o1_bis') = tests.id('o1') and tests.v('o1_bis') ->> 'total' = '2320', 'reintento con el mismo token: mismo pedido, sin duplicar');
reset role;
select tests.ok((select count(*) from public.orders where restaurant_id = tests.piazza()) = 3, 'reintento: siguen existiendo 3 pedidos en La Piazza');
set role anon;
select tests.throws(format('select public.create_order(%L)', tests.payload(1, jsonb_build_object('restaurantId', tests.otro(), 'items',
  jsonb_build_array(jsonb_build_object('productId', tests.otro_prod(), 'quantity', 1))))), 'código de seguimiento no válido', 'token reutilizado en otro restaurante: rechazado');

-- Restaurante inactivo y recogida o caja desactivadas
reset role;
update public.restaurants set active = false where id = tests.piazza();
set role anon;
select tests.throws(format('select public.create_order(%L)', tests.payload(43)), 'no acepta pedidos', 'rechaza restaurante inactivo');
reset role;
update public.restaurants set active = true, pickup_enabled = false where id = tests.piazza();
set role anon;
select tests.throws(format('select public.create_order(%L)', tests.payload(44, '{"mode": "recoger", "customerName": "Ana"}')), 'no acepta pedidos para recoger', 'rechaza recogida desactivada');
reset role;
update public.restaurants set pickup_enabled = true, counter_payment_enabled = false where id = tests.piazza();
set role anon;
select tests.throws(format('select public.create_order(%L)', tests.payload(45)), 'pago en caja no está disponible', 'rechaza pago en caja desactivado');
reset role;
update public.restaurants set counter_payment_enabled = true where id = tests.piazza();

-- ===================== 2. LECTURA DEL PEDIDO PROPIO =====================
select tests.claims('anon', null);
set role anon;
select tests.ok((public.get_customer_order(tests.id('o1'), tests.tok(1)) ->> 'id')::uuid = tests.id('o1'), 'el cliente lee su pedido con su token');
select tests.ok(public.get_customer_order(tests.id('o1'), tests.tok(999)) is null, 'token incorrecto: no devuelve nada');
select tests.ok(public.get_customer_order(tests.id('o_rec'), tests.tok(1)) is null, 'token de otro pedido: no devuelve nada');
select tests.ok(public.get_customer_order(tests.id('o1'), 'abc') is null, 'token mal formado: no devuelve nada');
select tests.ok(public.get_customer_order(tests.id('o1'), null) is null, 'sin token: no devuelve nada');
select tests.throws('select * from public.orders', 'permission denied', 'anónimo: no puede leer la tabla de pedidos');
select tests.throws('select * from public.order_items', 'permission denied', 'anónimo: no puede leer líneas de pedido');
select tests.throws('select * from private.order_access', 'permission denied', 'anónimo: no puede leer los tokens');
select tests.throws('select * from public.restaurant_staff', 'permission denied', 'anónimo: no puede leer el personal');
select tests.throws(format('update public.orders set prep_status = %L', 'listo'), 'permission denied', 'anónimo: no puede modificar pedidos');
select tests.throws($$insert into public.orders (restaurant_id, number, mode, table_number, total_cents, payment_method, payment_status)
  values ('5e5e0000-0000-4000-8000-000000000001', 999, 'mesa', 1, 0, 'caja', 'cobrado_caja')$$, 'permission denied', 'anónimo: no puede insertar pedidos directamente');
select tests.throws(format('select public.staff_set_prep_status(%L, %L)', tests.id('o1'), 'listo'), 'permission denied', 'anónimo: no puede usar funciones del personal');
select tests.throws(format('select public.staff_mark_paid_at_counter(%L)', tests.id('o1')), 'permission denied', 'anónimo: no puede marcar cobros');
select tests.throws($$update public.products set price_cents = 1$$, 'permission denied', 'anónimo: no puede cambiar precios');
select tests.ok((select count(*) from public.products where restaurant_id = tests.piazza()) = 17, 'anónimo: puede leer la carta');

-- ===================== 3. PAGOS =====================
-- Cambio a caja por el cliente: solo con su token y si el pago online está pendiente
select tests.throws(format('select public.customer_switch_to_counter(%L, %L)', tests.id('o1'), tests.tok(1)), 'ya no puede cambiar', 'pasar a caja: rechazado si ya es pago en caja');
reset role;
-- Pedido online en el restaurante con pago online activado
select tests.claims('anon', null);
set role anon;
insert into tests.vars select 'on1', public.create_order(jsonb_build_object('restaurantId', tests.otro(), 'mode', 'mesa', 'table', 2,
  'paymentMethod', 'online', 'accessToken', tests.tok(100), 'items', jsonb_build_array(jsonb_build_object('productId', tests.otro_prod(), 'quantity', 1))));
insert into tests.vars select 'on2', public.create_order(jsonb_build_object('restaurantId', tests.otro(), 'mode', 'mesa', 'table', 3,
  'paymentMethod', 'online', 'accessToken', tests.tok(101), 'items', jsonb_build_array(jsonb_build_object('productId', tests.otro_prod(), 'quantity', 2))));
insert into tests.vars select 'on3', public.create_order(jsonb_build_object('restaurantId', tests.otro(), 'mode', 'mesa', 'table', 4,
  'paymentMethod', 'online', 'accessToken', tests.tok(102), 'items', jsonb_build_array(jsonb_build_object('productId', tests.otro_prod(), 'quantity', 1))));
select tests.ok(tests.v('on1') ->> 'paymentStatus' = 'pendiente_online', 'pedido online: queda pendiente de pago');
select tests.throws(format('select public.customer_switch_to_counter(%L, %L)', tests.id('on1'), tests.tok(999)), 'no encontrado', 'pasar a caja: rechazado con token ajeno');
select tests.ok(public.customer_switch_to_counter(tests.id('on3'), tests.tok(102)) ->> 'paymentStatus' = 'pendiente_caja', 'pasar a caja: el cliente puede abandonar el pago online');

-- El personal no puede tocar importes ni pagos directamente
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000a1');
set role authenticated;
select tests.throws(format('update public.orders set total_cents = 1 where id = %L', tests.id('o1')), 'permission denied', 'owner: no puede cambiar el total con UPDATE');
select tests.throws(format('update public.orders set payment_status = %L where id = %L', 'pagado_verificado', tests.id('o1')), 'permission denied', 'owner: no puede marcar un pago como verificado');
select tests.throws(format('update public.order_items set unit_price_cents = 1'), 'permission denied', 'owner: no puede cambiar precios de líneas');
select tests.throws(format('select public.staff_mark_paid_at_counter(%L)', tests.id('o_rec')), '', 'owner: marcar cobrado funciona (comprobación inversa abajo)');
reset role;
select tests.ok((select payment_status = 'cobrado_caja' from public.orders where id = tests.id('o_rec')), 'owner: cobro en caja registrado');
-- La prueba anterior «throws» con patrón vacío no debe contar como fallo si no hubo error: se retira.
delete from tests.results where name = 'owner: marcar cobrado funciona (comprobación inversa abajo)';

-- El servidor solo LEE pedidos: los cambia únicamente con las funciones de pago (M4)
select tests.claims('service_role', null);
set role service_role;
select tests.throws(format('update public.orders set total_cents = 1 where id = %L', tests.id('o1')), 'permission denied', 'service_role: no puede cambiar el total');
select tests.throws(format('update public.orders set payment_status = %L where id = %L', 'pagado_verificado', tests.id('o1')), 'permission denied', 'service_role: no puede marcar pagos con UPDATE directo');
select tests.throws(format('update public.order_items set quantity = 9 where order_id = %L', tests.id('o1')), 'permission denied', 'service_role: no puede cambiar líneas de pedido');
select tests.throws(format('delete from public.orders where id = %L', tests.id('o1')), 'permission denied', 'service_role: no puede borrar pedidos');
select tests.ok((select count(*) from public.orders) > 0, 'service_role: puede leer pedidos');
reset role;
-- El SQL Editor (propietario, sin sesión) tiene permisos, pero el trigger sigue protegiendo
select tests.claims(null, null);
select tests.throws(format('update public.orders set total_cents = 1 where id = %L', tests.id('o1')), 'no se pueden modificar', 'SQL Editor: no puede cambiar el total');
select tests.throws(format('update public.order_items set quantity = 9 where order_id = %L', tests.id('o1')), 'no se pueden modificar', 'SQL Editor: no puede cambiar líneas de pedido');
select tests.throws(format('update public.orders set payment_status = %L where id = %L', 'pagado_verificado', tests.id('on1')), 'no permitido', 'SQL Editor: no puede marcar un pago como verificado');
select tests.throws(format('update public.orders set payment_ref = %L where id = %L', 'x', tests.id('on1')), 'solo la puede registrar el servidor', 'SQL Editor: no puede inventar una referencia de pago');

-- El personal no puede activar el pago online
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000a1');
set role authenticated;
select tests.throws(format('update public.restaurants set online_payment_enabled = true where id = %L', tests.piazza()), 'no se puede activar', 'owner: no puede activar el pago online');
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000ad');
select tests.throws($$insert into public.restaurants (slug, name, online_payment_enabled) values ('nuevo', 'Nuevo', true)$$, 'no se puede activar', 'admin: no puede crear restaurantes con pago online');
reset role;

-- ===================== 4. ROLES Y AISLAMIENTO =====================
-- Owner del otro restaurante: no ve ni toca La Piazza
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000b1');
set role authenticated;
select tests.ok((select count(*) from public.orders where restaurant_id = tests.piazza()) = 0, 'otro restaurante: no ve pedidos de La Piazza');
select tests.ok((select count(*) from public.order_items i join public.orders o on o.id = i.order_id where o.restaurant_id = tests.piazza()) = 0, 'otro restaurante: no ve líneas de La Piazza');
select tests.ok(tests.affected(format('update public.products set price_cents = 1 where id = %L', tests.marg())) = 0, 'otro restaurante: no puede cambiar precios de La Piazza');
select tests.ok(tests.affected(format('update public.restaurants set name = %L where id = %L', 'Hackeado', tests.piazza())) = 0, 'otro restaurante: no puede editar La Piazza');
select tests.ok(tests.affected(format('delete from public.products where id = %L', tests.marg())) = 0, 'otro restaurante: no puede borrar productos de La Piazza');
select tests.throws(format('select public.staff_set_prep_status(%L, %L)', tests.id('o1'), 'en_preparacion'), 'no encontrado', 'otro restaurante: no puede cambiar la preparación de La Piazza');
select tests.throws(format('select public.staff_mark_paid_at_counter(%L)', tests.id('o1')), 'no encontrado', 'otro restaurante: no puede cobrar pedidos de La Piazza');
select tests.ok((select count(*) from public.restaurant_staff where restaurant_id = tests.piazza()) = 0, 'otro restaurante: no ve el personal de La Piazza');
select tests.throws(format('insert into public.products (restaurant_id, category_id, name, price_cents) values (%L, %L, %L, 100)', tests.piazza(), '5e5e0000-0000-4000-8000-000000000101', 'Intruso'), 'row-level security', 'otro restaurante: no puede crear productos en La Piazza');
select tests.ok(not exists (select 1 from public.my_memberships() where restaurant_id = tests.piazza()), 'otro restaurante: mis restaurantes no incluye La Piazza');

-- Cocina: prepara, pero no cobra, no cancela, no cambia precios ni configuración
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000a4');
select public.staff_set_prep_status(tests.id('o1'), 'en_preparacion');
reset role;
select tests.ok((select prep_status = 'en_preparacion' from public.orders where id = tests.id('o1')), 'cocina: puede empezar a preparar');
set role authenticated;
select public.staff_set_prep_status(tests.id('o1'), 'nuevo');
select tests.throws(format('select public.staff_set_prep_status(%L, %L)', tests.id('o1'), 'cancelado'), 'no puede cancelar', 'cocina: no puede cancelar');
select tests.throws(format('select public.staff_mark_paid_at_counter(%L)', tests.id('o1')), 'no encontrado', 'cocina: no puede marcar cobros');
select tests.ok(tests.affected(format('update public.products set price_cents = 1 where id = %L', tests.marg())) = 0, 'cocina: no puede cambiar precios');
select tests.ok(tests.affected(format('update public.restaurants set prep_minutes = 99 where id = %L', tests.piazza())) = 0, 'cocina: no puede cambiar la configuración');
select tests.throws(format('insert into public.categories (restaurant_id, name) values (%L, %L)', tests.piazza(), 'Nueva'), 'row-level security', 'cocina: no puede crear categorías');
select tests.ok((select count(*) from public.restaurant_staff) = 1, 'cocina: solo ve su propia fila de personal');
select tests.throws(format('insert into public.restaurant_staff (restaurant_id, user_id, role) values (%L, %L, %L)', tests.piazza(), 'a0000000-0000-4000-8000-0000000000a4', 'owner'), 'permission denied', 'cocina: no puede ascenderse a owner');
select tests.throws(format('update public.orders set prep_status = %L where id = %L', 'listo', tests.id('o1')), 'permission denied', 'cocina: no puede actualizar pedidos sin pasar por las funciones');

-- Transiciones de preparación
select tests.throws(format('select public.staff_set_prep_status(%L, %L)', tests.id('o1'), 'entregado'), 'no permitido', 'transición inválida: de nuevo a entregado');

-- Sala (waiter): cobra y cancela, pero no cambia precios
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000a3');
select tests.ok(tests.affected(format('update public.products set price_cents = 1 where id = %L', tests.marg())) = 0, 'sala: no puede cambiar precios');
select public.staff_mark_paid_at_counter(tests.id('o1'));
select tests.throws(format('select public.staff_mark_paid_at_counter(%L)', tests.id('o1')), 'no está pendiente de cobro', 'sala: no puede cobrar dos veces');
select public.staff_set_prep_status(tests.id('o_precio'), 'cancelado');
select tests.throws(format('select public.staff_set_prep_status(%L, %L)', tests.id('o_precio'), 'en_preparacion'), 'no permitido', 'transición inválida: un pedido cancelado no vuelve');
reset role;
select tests.ok((select payment_status = 'cobrado_caja' from public.orders where id = tests.id('o1')), 'sala: puede registrar el cobro en caja');
select tests.ok((select prep_status = 'cancelado' from public.orders where id = tests.id('o_precio')), 'sala: puede cancelar');

-- Manager: puede editar la carta de su restaurante
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000a2');
set role authenticated;
select tests.ok(tests.affected(format('update public.products set price_cents = 1100 where id = %L', tests.marg())) = 1, 'manager: puede cambiar precios de su restaurante');
select tests.ok(tests.affected(format('update public.products set price_cents = 1 where id = %L', tests.otro_prod())) = 0, 'manager: no puede cambiar precios de otro restaurante');
-- Un pedido ya creado conserva su precio
select tests.ok((select unit_price_cents from public.order_items where order_id = tests.id('o1') and product_id = tests.marg()) = 1050, 'cambiar un precio no altera pedidos ya hechos');
select tests.throws($$insert into public.restaurants (slug, name) values ('mio', 'Mío')$$, 'row-level security', 'manager: no puede crear restaurantes');

-- Usuario autenticado sin rol
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000ee');
select tests.ok((select count(*) from public.orders) = 0, 'sin rol: no ve ningún pedido');
select tests.ok((select count(*) from public.my_memberships()) = 0, 'sin rol: no tiene restaurantes');
select tests.ok(tests.affected('update public.products set price_cents = 1') = 0, 'sin rol: no puede cambiar precios');
select tests.throws($$insert into public.platform_admins (user_id) values ('a0000000-0000-4000-8000-0000000000ee')$$, 'permission denied', 'sin rol: no puede hacerse administrador');

-- Administrador de plataforma
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000ad');
select tests.ok((select count(*) from public.orders) = 0, 'admin: NO ve pedidos de ningún restaurante (sin acceso operativo)');
select tests.ok((select count(*) from public.my_memberships()) = 0, 'admin: no aparece como personal de ningún restaurante');
select tests.ok(tests.affected($$insert into public.restaurants (slug, name) values ('nuevo-sitio', 'Nuevo Sitio')$$) = 1, 'admin: puede crear restaurantes');
reset role;

-- ===================== 5. DATOS =====================
select tests.claims(null, null);
select tests.throws(format('insert into public.products (restaurant_id, category_id, name, price_cents) values (%L, %L, %L, 100)',
  tests.otro(), '5e5e0000-0000-4000-8000-000000000101', 'Cruzado'), 'products_category_same_restaurant', 'un producto no puede usar la categoría de otro restaurante');
select tests.throws(format('update public.products set category_id = %L where id = %L', 'b0000000-0000-4000-8000-000000000101', tests.marg()),
  'products_category_same_restaurant', 'no se puede mover un producto a una categoría de otro restaurante');
select tests.throws($$insert into public.products (restaurant_id, category_id, name, price_cents) values
  ('5e5e0000-0000-4000-8000-000000000001', '5e5e0000-0000-4000-8000-000000000101', 'Carísimo', 100001)$$, 'violates check', 'precio máximo 1.000 €');

-- ===================== 6. PEDIDOS ONLINE PENDIENTES Y COCINA =====================
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000b4');
set role authenticated;
select tests.ok(not tests.in_kitchen(tests.otro(), tests.id('on1')) and not tests.in_kitchen(tests.otro(), tests.id('on2')), 'cocina: no ve pedidos con pago online pendiente');
select tests.ok(tests.in_kitchen(tests.otro(), tests.id('on3')), 'cocina: sí ve el pedido que pasó a pagar en caja');
select tests.throws(format('select public.staff_set_prep_status(%L, %L)', tests.id('on1'), 'en_preparacion'), 'no encontrado', 'cocina: no puede preparar un pedido online pendiente');
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000b1');
select tests.ok((select count(*) from public.orders where id = tests.id('on1')) = 1, 'owner: sí ve el pedido online pendiente');
select tests.throws(format('select public.staff_set_prep_status(%L, %L)', tests.id('on1'), 'en_preparacion'), 'pendiente de pago online', 'owner: no puede mandar a cocina un pedido online pendiente');
reset role;

-- ===================== 7. PAGOS ONLINE: SERVIDOR Y AVISOS TARDÍOS (I1) =====================
-- Nadie salvo el servidor puede usar las funciones de pago
select tests.claims('anon', null);
set role anon;
select tests.throws(format('select public.payment_record_result(%L, %L, %L, 900)', 'evt_x', 'cs_x', 'pagado'), 'permission denied', 'anónimo: no puede registrar pagos');
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000b1');
set role authenticated;
select tests.throws(format('select public.payment_checkout_started(%L, %L, 900)', tests.id('on1'), 'cs_x'), 'permission denied', 'owner: no puede abrir cobros');
select tests.throws(format('select public.payment_record_result(%L, %L, %L, 900)', 'evt_x', 'cs_x', 'pagado'), 'permission denied', 'owner: no puede registrar pagos');
reset role;
-- El SQL Editor es el propietario y puede llamarlas, pero el trigger le impide abrir cobros
select tests.claims(null, null);
select tests.throws(format('select public.payment_checkout_started(%L, %L, 900)', tests.id('on1'), 'cs_editor'), 'solo la puede registrar el servidor', 'SQL Editor: no puede abrir cobros');
select tests.ok((select payment_ref is null and payment_status = 'pendiente_online' from public.orders where id = tests.id('on1')), 'SQL Editor: el intento no deja rastro en el pedido');

select tests.claims('service_role', null);
set role service_role;
-- Abrir cobro: importe del pedido, restaurante con pago online y pedido online pendiente
select tests.throws(format('select public.payment_checkout_started(%L, %L, 1)', tests.id('on1'), 'cs_1'), 'no coincide con el total', 'abrir cobro: rechaza importe distinto del pedido');
select tests.throws(format('select public.payment_checkout_started(%L, %L, 900)', tests.id('on3'), 'cs_caja'), 'no admite un pago online', 'abrir cobro: rechaza pedidos de pago en caja');
select tests.throws(format('select public.payment_checkout_started(%L, %L, 2320)', tests.id('o1'), 'cs_piazza'), 'pago online no está disponible', 'abrir cobro: rechaza restaurantes sin pago online (La Piazza)');
select tests.ok((public.payment_checkout_started(tests.id('on1'), 'cs_1', 900) ->> 'amountCents') = '900', 'abrir cobro: devuelve el importe del pedido');
select tests.ok((public.payment_checkout_started(tests.id('on1'), 'cs_1', 900) ->> 'amountCents') = '900', 'abrir cobro: repetir con la misma referencia no cambia nada');
select tests.throws(format('select public.payment_checkout_started(%L, %L, 900)', tests.id('on1'), 'cs_1_bis'), 'Ya hay un pago en curso', 'abrir cobro: no abre un segundo cobro a la vez');
reset role;

-- Con un cobro en curso, el cliente no puede pasar a caja (evita el doble cobro)
select tests.claims('anon', null);
set role anon;
select tests.throws(format('select public.customer_switch_to_counter(%L, %L)', tests.id('on1'), tests.tok(100)), 'pago online en curso', 'pasar a caja: bloqueado mientras hay un cobro en curso');
reset role;
-- Con un cobro real abierto, el SQL Editor tampoco puede darlo por pagado
select tests.claims(null, null);
select tests.throws(format('select public.payment_record_result(%L, %L, %L, 900)', 'evt_editor', 'cs_1', 'pagado'), 'no permitido', 'SQL Editor: no puede simular un cobro');
select tests.ok((select payment_status = 'pendiente_online' from public.orders where id = tests.id('on1')), 'SQL Editor: el pedido sigue sin pagar');
select tests.ok(not exists (select 1 from public.payment_events where provider_event_id = 'evt_editor'), 'SQL Editor: no queda ningún aviso registrado');

select tests.claims('service_role', null);
set role service_role;
select tests.ok(public.payment_record_result('evt_1', 'cs_1', 'pagado', 900) = 'aplicado', 'aviso de pago correcto: aplicado');
select tests.ok(public.payment_record_result('evt_1', 'cs_1', 'pagado', 900) = 'aplicado', 'aviso repetido: misma respuesta');
select tests.ok((select count(*) from public.payment_events where provider_event_id = 'evt_1') = 1, 'aviso repetido: se registra una sola vez');
select tests.ok(public.payment_record_result('evt_1_fallo', 'cs_1', 'fallido', null) = 'ignorado', 'un fallo tardío no deshace un pago verificado');
select tests.throws(format('select public.payment_record_result(%L, %L, %L, 900)', 'evt_mal', 'cs_1', 'reembolsado'), 'Resultado de pago no válido', 'aviso con resultado desconocido: rechazado');

-- on2: falla, el cliente reintenta y llega tarde el cobro del primer intento
select public.payment_checkout_started(tests.id('on2'), 'cs_2', 1800);
select tests.ok(public.payment_record_result('evt_2', 'cs_2', 'fallido', null) = 'aplicado', 'aviso de pago fallido: aplicado');
select tests.ok((public.payment_checkout_started(tests.id('on2'), 'cs_2b', 1800) ->> 'orderId')::uuid = tests.id('on2'), 'tras un fallo se puede abrir un nuevo cobro');
select tests.ok(public.payment_record_result('evt_2_tarde', 'cs_2', 'pagado', 1800) = 'requiere_revision', 'cobro tardío de un intento anterior: requiere revisión');

-- Importe cobrado distinto del pedido
reset role;
select tests.claims('anon', null);
set role anon;
insert into tests.vars select 'on4', public.create_order(tests.online(104, 1));
reset role;
select tests.claims('service_role', null);
set role service_role;
select public.payment_checkout_started(tests.id('on4'), 'cs_4', 900);
select tests.ok(public.payment_record_result('evt_4', 'cs_4', 'pagado', 1) = 'requiere_revision', 'importe cobrado distinto: requiere revisión');
select tests.ok(public.payment_record_result('evt_desconocido', 'cs_no_existe', 'pagado', 900) = 'requiere_revision', 'cobro con referencia desconocida: requiere revisión');
reset role;
select tests.ok((select payment_status = 'pendiente_online' from public.orders where id = tests.id('on4')), 'importe distinto: el pedido NO se da por pagado');
select tests.ok((select payment_status = 'pendiente_online' from public.orders where id = tests.id('on2')), 'cobro tardío de otro intento: el pedido NO se da por pagado');

-- on6: falla, el cliente pasa a caja y después llega un cobro tardío
select tests.claims('anon', null);
set role anon;
insert into tests.vars select 'on6', public.create_order(tests.online(106, 1));
reset role;
select tests.claims('service_role', null);
set role service_role;
select public.payment_checkout_started(tests.id('on6'), 'cs_6', 900);
select public.payment_record_result('evt_6_fallo', 'cs_6', 'fallido', null);
reset role;
select tests.claims('anon', null);
set role anon;
select tests.ok(public.customer_switch_to_counter(tests.id('on6'), tests.tok(106)) ->> 'paymentStatus' = 'pendiente_caja', 'tras un fallo, el cliente puede pasar a caja');
reset role;
select tests.claims('service_role', null);
set role service_role;
select tests.ok(public.payment_record_result('evt_6_tarde', 'cs_6', 'pagado', 900) = 'requiere_revision', 'cobro tardío de un pedido que pasó a caja: requiere revisión');
reset role;
select tests.ok((select payment_method = 'caja' and payment_status = 'pendiente_caja' from public.orders where id = tests.id('on6')), 'pedido que pasó a caja: no cambia con el cobro tardío');

-- on7: el personal cancela mientras se paga; el cobro llega después
select tests.claims('anon', null);
set role anon;
insert into tests.vars select 'on7', public.create_order(tests.online(107, 1));
reset role;
select tests.claims('service_role', null);
set role service_role;
select public.payment_checkout_started(tests.id('on7'), 'cs_7', 900);
reset role;
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000b1');
set role authenticated;
select public.staff_set_prep_status(tests.id('on7'), 'cancelado');
reset role;
select tests.claims('service_role', null);
set role service_role;
select tests.ok(public.payment_record_result('evt_7', 'cs_7', 'pagado', 900) = 'requiere_revision', 'pedido cancelado y cobrado: requiere revisión (devolución)');
select tests.throws($$insert into public.payment_events (provider_event_id, payment_ref, outcome, resolution) values ('x', 'x', 'pagado', 'aplicado')$$, 'permission denied', 'service_role: no puede inventar avisos de pago');
reset role;

-- Restaurante sin pago online: no se abren cobros
update public.restaurants set online_payment_enabled = false where id = tests.otro();
select tests.claims('service_role', null);
set role service_role;
select tests.throws(format('select public.payment_checkout_started(%L, %L, 900)', tests.id('on4'), 'cs_4b'), 'Ya hay un pago en curso|pago online no está disponible', 'abrir cobro: rechazado si el restaurante no tiene pago online');
reset role;
select tests.claims(null, null);
update public.restaurants set online_payment_enabled = true where id = tests.otro();

-- Quién ve los avisos de pago
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000b1');
set role authenticated;
select tests.ok((select count(*) from public.payment_events where restaurant_id = tests.otro()) >= 6, 'owner: ve los avisos de pago de su restaurante');
select tests.ok((select count(*) from public.payment_events where resolution = 'requiere_revision') = 4, 'owner: ve los 4 avisos pendientes de revisión de su restaurante');
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000b4');
select tests.ok((select count(*) from public.payment_events) = 0, 'cocina: no ve avisos de pago');
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000a1');
select tests.ok((select count(*) from public.payment_events) = 0, 'otro restaurante: no ve avisos de pago ajenos');
select tests.claims('anon', null);
set role anon;
select tests.throws('select * from public.payment_events', 'permission denied', 'anónimo: no puede leer avisos de pago');
reset role;

-- Cocina: ve el pedido pagado, no el pendiente
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000b4');
set role authenticated;
select tests.ok(tests.in_kitchen(tests.otro(), tests.id('on1')), 'cocina: ve el pedido cuando el pago está verificado');
select tests.ok(not tests.in_kitchen(tests.otro(), tests.id('on2')) and not tests.in_kitchen(tests.otro(), tests.id('on4')), 'cocina: no ve pedidos con el pago pendiente');
reset role;

-- ===================== 8. PASAR A CAJA: RESTAURANTE ACTIVO Y CADUCIDAD (M1) =====================
select tests.claims('anon', null);
set role anon;
insert into tests.vars select 'on8', public.create_order(tests.online(108, 1));
reset role;
update public.restaurants set active = false where id = tests.otro();
set role anon;
select tests.throws(format('select public.customer_switch_to_counter(%L, %L)', tests.id('on8'), tests.tok(108)), 'no acepta pedidos', 'pasar a caja: rechazado si el restaurante está inactivo');
reset role;
update public.restaurants set active = true where id = tests.otro();
-- Pedido online de hace 3 horas (insertado directamente: el trigger impide cambiar created_at)
insert into public.orders (id, restaurant_id, number, mode, table_number, total_cents, payment_method, payment_status, created_at)
values ('c0000000-0000-4000-8000-000000000001', tests.otro(), 9999, 'mesa', 1, 900, 'online', 'pendiente_online', now() - interval '3 hours');
insert into private.order_access (order_id, token_hash) values ('c0000000-0000-4000-8000-000000000001', private.token_hash(tests.tok(109)));
set role anon;
select tests.throws(format('select public.customer_switch_to_counter(%L, %L)', 'c0000000-0000-4000-8000-000000000001', tests.tok(109)), 'caducado', 'pasar a caja: rechazado si el pedido tiene más de 2 horas');
select tests.ok(public.customer_switch_to_counter(tests.id('on8'), tests.tok(108)) ->> 'paymentStatus' = 'pendiente_caja', 'pasar a caja: permitido en un pedido reciente sin cobro en curso');
reset role;

-- ===================== 9. HISTORIAL Y RETIRADA DE PRODUCTOS (I2) =====================
select tests.claims(null, null);
select tests.throws(format('delete from public.restaurants where id = %L', tests.piazza()), 'orders_restaurant_id_fkey', 'no se puede borrar un restaurante con pedidos');
select tests.ok((select count(*) from public.orders where restaurant_id = tests.piazza()) >= 3, 'el intento de borrado no elimina pedidos');
-- Un restaurante sin pedidos sí se puede borrar
insert into public.restaurants (id, slug, name) values ('d0000000-0000-4000-8000-000000000001', 'vacio', 'Vacío');
insert into public.categories (id, restaurant_id, name) values ('d0000000-0000-4000-8000-000000000101', 'd0000000-0000-4000-8000-000000000001', 'Cat');
insert into public.products (restaurant_id, category_id, name, price_cents) values ('d0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000101', 'Prod', 100);
select tests.ok(tests.affected($$delete from public.restaurants where id = 'd0000000-0000-4000-8000-000000000001'$$) = 1, 'un restaurante sin pedidos sí se puede borrar');

-- El manager retira del catálogo un producto ya pedido (Agua, pedida en o1)
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000a4');
set role authenticated;
select tests.ok(tests.affected(format('delete from public.products where id = %L', tests.agua())) = 0, 'cocina: no puede retirar productos');
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000a2');
select tests.ok(tests.affected(format('delete from public.products where id = %L', tests.agua())) = 1, 'manager: puede retirar un producto ya pedido');
reset role;
select tests.ok((select name = 'Agua mineral 50 cl' and unit_price_cents = 220 and quantity = 1 and product_id is null
  from public.order_items where order_id = tests.id('o1') and name like 'Agua%'), 'la línea conserva nombre, precio y cantidad históricos');
select tests.claims(null, null);
select tests.throws(format('update public.order_items set name = %L, product_id = null where order_id = %L and product_id is not null', 'Otro', tests.id('o1')), 'no se pueden modificar', 'la excepción no permite cambiar otros datos de la línea');
select tests.throws(format('update public.order_items set product_id = %L where order_id = %L and product_id is null', tests.marg(), tests.id('o1')), 'no se pueden modificar', 'no se puede volver a enlazar una línea a otro producto');
-- Borrar una categoría con productos pedidos (Pizzas, con Margherita) tampoco borra historial
select tests.claims('authenticated', 'a0000000-0000-4000-8000-0000000000a1');
set role authenticated;
select tests.ok(tests.affected($$delete from public.categories where id = '5e5e0000-0000-4000-8000-000000000102'$$) = 1, 'owner: puede borrar una categoría con productos pedidos');
reset role;
select tests.ok((select count(*) from public.order_items where order_id = tests.id('o1') and name = 'Margherita' and unit_price_cents = 1050) = 1, 'las líneas de la categoría borrada se conservan');

-- ===================== 10. ROL DE LA PETICIÓN (M2) =====================
-- private.request_role() debe devolver exactamente lo mismo que auth.role() de Supabase
create function tests.same_role(claims text, legacy text) returns boolean language plpgsql as $$
declare a text; b text;
begin
  perform set_config('request.jwt.claims', coalesce(claims, ''), true);
  perform set_config('request.jwt.claim.role', coalesce(legacy, ''), true);
  a := auth.role(); b := private.request_role();
  return a is not distinct from b;
end $$;
select tests.ok(tests.same_role('{"role":"anon"}', null), 'rol de la petición = auth.role(): anon');
select tests.ok(tests.same_role('{"role":"authenticated","sub":"a0000000-0000-4000-8000-0000000000a1"}', null), 'rol de la petición = auth.role(): authenticated');
select tests.ok(tests.same_role('{"role":"service_role"}', null), 'rol de la petición = auth.role(): service_role');
select tests.ok(tests.same_role(null, null), 'rol de la petición = auth.role(): SQL Editor (sin JWT)');
select tests.ok(tests.same_role('{}', null), 'rol de la petición = auth.role(): JWT sin rol');
select tests.ok(tests.same_role(null, 'authenticated'), 'rol de la petición = auth.role(): formato antiguo de PostgREST');
select tests.ok(tests.same_role('{"role":"anon"}', 'service_role'), 'rol de la petición = auth.role(): ambos formatos a la vez');
select tests.claims(null, null);
select tests.ok(private.request_role() is null, 'SQL Editor: sin rol de petición');
select tests.ok(tests.affected(format('update public.restaurants set online_payment_enabled = true where id = %L', tests.otro())) = 1,
  'SQL Editor: puede activar el pago online (cuando exista la integración)');
select tests.claims('service_role', null);
set role service_role;
select tests.ok(tests.affected(format('update public.restaurants set prep_minutes = 20 where id = %L', tests.otro())) = 1, 'service_role: el trigger le deja administrar restaurantes');
reset role;

-- ===================== 11. RE-EJECUCIÓN, PERMISOS DEL SERVIDOR Y CONFIGURACIÓN INICIAL (M3, M4) =====================
select tests.claims(null, null);
select tests.ok(exists (select 1 from pg_policies where tablename = 'products' and policyname = 'politica_ajena_prueba'),
  'reejecutar el esquema conserva las políticas ajenas al proyecto');
select tests.ok((select count(*) from pg_policies where schemaname = 'public' and policyname <> 'politica_ajena_prueba') = 12,
  'reejecutar el esquema deja exactamente las 12 políticas del proyecto');
select tests.ok(not has_table_privilege('service_role', 'public.tabla_ajena', 'select')
  and not has_table_privilege('service_role', 'public.tabla_ajena', 'delete'), 'el esquema no da permisos al servidor sobre tablas ajenas');
select tests.ok(has_table_privilege('service_role', 'public.products', 'update')
  and not has_table_privilege('service_role', 'public.orders', 'update')
  and not has_table_privilege('service_role', 'public.order_items', 'insert'), 'servidor: administra la carta pero no escribe pedidos');
select tests.ok((select column_default from information_schema.columns where table_schema = 'public' and table_name = 'restaurants'
  and column_name = 'online_payment_enabled') = 'false', 'pago online desactivado por defecto en restaurantes nuevos');
select tests.ok((select not online_payment_enabled from public.restaurants where id = tests.piazza()), 'La Piazza (seed) tiene el pago online desactivado');
select tests.ok((select not online_payment_enabled from public.restaurants where slug = 'nuevo-sitio'), 'restaurante creado desde la app: pago online desactivado');


-- ===================== 12. ROLES Y PERMISOS (FASE 3) =====================
select tests.claims(null, null);
insert into auth.users (id, email) values
  (tests.u('a5'), 'nuevo@piazza.test'), (tests.u('a6'), 'extra@piazza.test'), (tests.u('a7'), 'socio@piazza.test'),
  (tests.u('a8'), 'Mayus@Piazza.test'), (tests.u('b2'), 'manager@otro.test'), (tests.u('ae'), 'admin2@plataforma.test');
insert into public.restaurant_staff (restaurant_id, user_id, role) values (tests.otro(), tests.u('b2'), 'manager');
insert into public.platform_admins (user_id) values (tests.u('ae'));

-- 12.1 La plataforma no tiene acceso operativo a ningún restaurante
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select tests.ok((select count(*) from public.orders) = 0, 'plataforma: no ve pedidos');
select tests.ok((select count(*) from public.order_items) = 0, 'plataforma: no ve líneas de pedido');
select tests.ok((select count(*) from public.payment_events) = 0, 'plataforma: no ve avisos de pago');
select tests.throws(format('select public.kitchen_orders(%L)', tests.piazza()), 'No tienes acceso', 'plataforma: no ve la cocina');
select tests.throws(format('select public.staff_set_prep_status(%L, %L)', tests.id('o_rec'), 'en_preparacion'), 'no encontrado', 'plataforma: no cambia la preparación');
select tests.throws(format('select public.staff_mark_paid_at_counter(%L)', tests.id('o1')), 'no encontrado', 'plataforma: no registra cobros');
select tests.ok(tests.affected(format('update public.products set price_cents = 1 where restaurant_id = %L', tests.piazza())) = 0, 'plataforma: no cambia precios');
select tests.throws(format('insert into public.categories (restaurant_id, name) values (%L, %L)', tests.piazza(), 'X'), 'row-level security', 'plataforma: no crea categorías');
select tests.throws(format('select public.staff_add_member(%L, %L, %L)', tests.piazza(), 'admin@plataforma.test', 'owner'), 'propio acceso', 'plataforma: no puede añadirse a un restaurante');
select tests.throws(format('select public.staff_add_member(%L, %L, %L)', tests.piazza(), 'admin2@plataforma.test', 'owner'), 'plataforma no pueden ser personal', 'plataforma: no puede añadir a otra cuenta de plataforma');
reset role;
select tests.claims(null, null);
select tests.throws(format('insert into public.restaurant_staff (restaurant_id, user_id, role) values (%L, %L, %L)', tests.piazza(), tests.u('ae'), 'owner'), 'plataforma no pueden ser personal', 'SQL Editor: una cuenta de plataforma no puede ser personal');
select tests.throws(format('insert into public.platform_admins (user_id) values (%L)', tests.u('a1')), 'personal de un restaurante', 'SQL Editor: el personal de un restaurante no puede ser plataforma');

-- 12.2 Gestión de equipo: owner
select tests.claims('authenticated', tests.u('a1'));
set role authenticated;
select tests.ok((select count(*) from public.staff_list(tests.piazza())) = 4 and (select bool_or(is_me and role = 'owner') from public.staff_list(tests.piazza())), 'owner: ve su equipo con emails');
select public.staff_add_member(tests.piazza(), 'nuevo@piazza.test', 'waiter');
select public.staff_add_member(tests.piazza(), '  MAYUS@piazza.TEST ', 'kitchen');
select tests.ok((select count(*) from public.staff_list(tests.piazza())) = 6, 'owner: da de alta sala y cocina (email sin distinguir mayúsculas)');
select tests.throws(format('select public.staff_add_member(%L, %L, %L)', tests.piazza(), 'socio@piazza.test', 'owner'), 'No puedes asignar esa función', 'owner: no puede nombrar propietarios');
select tests.throws(format('select public.staff_add_member(%L, %L, %L)', tests.piazza(), 'nadie@piazza.test', 'waiter'), 'No hay ninguna cuenta', 'owner: email sin cuenta');
select tests.throws(format('select public.staff_add_member(%L, %L, %L)', tests.piazza(), 'nuevo@piazza.test', 'kitchen'), 'ya forma parte', 'owner: no duplica miembros');
select public.staff_change_role(tests.piazza(), tests.u('a5'), 'manager');
select tests.throws(format('select public.staff_change_role(%L, %L, %L)', tests.piazza(), tests.u('a1'), 'manager'), 'propio acceso', 'owner: no cambia su propio rol');
select tests.throws(format('select public.staff_remove_member(%L, %L)', tests.piazza(), tests.u('a1')), 'propio acceso', 'owner: no se quita a sí mismo');
select tests.throws(format('select public.staff_change_role(%L, %L, %L)', tests.piazza(), tests.u('a3'), 'owner'), 'No puedes asignar esa función', 'owner: no asciende a nadie a propietario');
select tests.throws(format('insert into public.restaurant_staff (restaurant_id, user_id, role) values (%L, %L, %L)', tests.piazza(), tests.u('a7'), 'waiter'), 'permission denied', 'owner: no escribe directamente en el equipo');
select tests.throws(format('update public.restaurant_staff set role = %L where user_id = %L', 'owner', tests.u('a3')), 'permission denied', 'owner: no cambia roles directamente');
select tests.throws(format('insert into public.platform_admins (user_id) values (%L)', tests.u('a1')), 'permission denied', 'owner: no puede hacerse plataforma');

-- 12.3 Gestión de equipo: manager (solo sala y cocina)
select tests.claims('authenticated', tests.u('a2'));
select tests.ok((select count(*) from public.staff_list(tests.piazza())) = 6, 'manager: ve su equipo');
select public.staff_add_member(tests.piazza(), 'extra@piazza.test', 'kitchen');
select tests.ok(exists (select 1 from public.staff_list(tests.piazza()) where email = 'extra@piazza.test' and role = 'kitchen'), 'manager: da de alta cocina');
select public.staff_change_role(tests.piazza(), tests.u('a6'), 'waiter');
select tests.ok(exists (select 1 from public.staff_list(tests.piazza()) where email = 'extra@piazza.test' and role = 'waiter'), 'manager: cambia cocina ↔ sala');
select tests.throws(format('select public.staff_add_member(%L, %L, %L)', tests.piazza(), 'socio@piazza.test', 'manager'), 'No puedes asignar esa función', 'manager: no nombra encargados');
select tests.throws(format('select public.staff_add_member(%L, %L, %L)', tests.piazza(), 'socio@piazza.test', 'owner'), 'No puedes asignar esa función', 'manager: no nombra propietarios');
select tests.throws(format('select public.staff_change_role(%L, %L, %L)', tests.piazza(), tests.u('a6'), 'manager'), 'No puedes asignar esa función', 'manager: no asciende a encargado');
select tests.throws(format('select public.staff_change_role(%L, %L, %L)', tests.piazza(), tests.u('a6'), 'owner'), 'No puedes asignar esa función', 'manager: no asciende a propietario');
select tests.throws(format('select public.staff_change_role(%L, %L, %L)', tests.piazza(), tests.u('a2'), 'owner'), 'propio acceso', 'manager: no se asciende a sí mismo');
select tests.throws(format('select public.staff_change_role(%L, %L, %L)', tests.piazza(), tests.u('a1'), 'waiter'), 'No puedes gestionar a esa persona', 'manager: no cambia al propietario');
select tests.throws(format('select public.staff_remove_member(%L, %L)', tests.piazza(), tests.u('a1')), 'No puedes gestionar a esa persona', 'manager: no quita al propietario');
select tests.throws(format('select public.staff_remove_member(%L, %L)', tests.piazza(), tests.u('a5')), 'No puedes gestionar a esa persona', 'manager: no quita a otro encargado');
select public.staff_remove_member(tests.piazza(), tests.u('a6'));
select tests.ok(not exists (select 1 from public.staff_list(tests.piazza()) where email = 'extra@piazza.test'), 'manager: retira el acceso a sala/cocina');
select tests.throws(format('select public.staff_add_member(%L, %L, %L)', tests.otro(), 'socio@piazza.test', 'waiter'), 'No puedes asignar esa función', 'manager: no gestiona otro restaurante');

-- 12.4 Sala, cocina, usuarios sin rol y otros restaurantes no gestionan equipos
select tests.claims('authenticated', tests.u('a3'));
select tests.throws(format('select * from public.staff_list(%L)', tests.piazza()), 'No tienes acceso', 'sala: no ve la lista del equipo');
select tests.throws(format('select public.staff_add_member(%L, %L, %L)', tests.piazza(), 'socio@piazza.test', 'kitchen'), 'No puedes asignar esa función', 'sala: no da de alta a nadie');
select tests.throws(format('select public.staff_remove_member(%L, %L)', tests.piazza(), tests.u('a4')), 'No puedes gestionar a esa persona', 'sala: no quita a nadie');
select tests.claims('authenticated', tests.u('a4'));
select tests.throws(format('select public.staff_change_role(%L, %L, %L)', tests.piazza(), tests.u('a4'), 'owner'), 'propio acceso', 'cocina: no se asciende');
select tests.throws(format('select public.staff_change_role(%L, %L, %L)', tests.piazza(), tests.u('a3'), 'kitchen'), 'No puedes gestionar a esa persona', 'cocina: no cambia a otros');
select tests.throws(format('select public.platform_set_suspension(%L, false, %L)', tests.piazza(), ''), 'Solo la plataforma', 'cocina: no toca la suspensión');
select tests.claims('authenticated', tests.u('b1'));
select tests.throws(format('select * from public.staff_list(%L)', tests.piazza()), 'No tienes acceso', 'otro restaurante: no ve el equipo de La Piazza');
select tests.throws(format('select public.staff_add_member(%L, %L, %L)', tests.piazza(), 'socio@piazza.test', 'waiter'), 'No puedes asignar esa función', 'otro restaurante: no da de alta en La Piazza');
select tests.throws(format('select public.staff_remove_member(%L, %L)', tests.piazza(), tests.u('a3')), 'No puedes gestionar a esa persona', 'otro restaurante: no quita personal de La Piazza');
select tests.claims('authenticated', tests.u('b2'));
select tests.throws(format('select public.staff_change_role(%L, %L, %L)', tests.piazza(), tests.u('a3'), 'kitchen'), 'No puedes gestionar a esa persona', 'manager de otro restaurante: no gestiona La Piazza');
select tests.claims('authenticated', tests.u('ee'));
select tests.throws(format('select * from public.staff_list(%L)', tests.piazza()), 'No tienes acceso', 'sin rol: no ve equipos');
select tests.claims('anon', null);
set role anon;
select tests.throws(format('select public.staff_add_member(%L, %L, %L)', tests.piazza(), 'socio@piazza.test', 'owner'), 'permission denied', 'anónimo: no puede gestionar equipos');
reset role;

-- 12.5 Último propietario y propietarios gestionados por la plataforma
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select tests.ok((select count(*) from public.staff_list(tests.piazza())) >= 5, 'plataforma: ve el equipo (consulta registrada)');
select tests.throws(format('select public.staff_remove_member(%L, %L)', tests.piazza(), tests.u('a1')), 'al menos un propietario', 'plataforma: no quita al último propietario');
select tests.throws(format('select public.staff_change_role(%L, %L, %L)', tests.piazza(), tests.u('a1'), 'manager'), 'al menos un propietario', 'plataforma: no degrada al último propietario');
select public.staff_add_member(tests.piazza(), 'socio@piazza.test', 'owner');
select tests.ok((select count(*) from public.staff_list(tests.piazza()) where role = 'owner') = 2, 'plataforma: nombra un segundo propietario');
reset role;
select tests.claims('authenticated', tests.u('a1'));
set role authenticated;
select tests.throws(format('select public.staff_remove_member(%L, %L)', tests.piazza(), tests.u('a7')), 'No puedes gestionar a esa persona', 'owner: no quita a otro propietario');
reset role;
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select public.staff_remove_member(tests.piazza(), tests.u('a7'));
select tests.ok((select count(*) from public.staff_list(tests.piazza()) where role = 'owner') = 1, 'plataforma: quita un propietario si queda otro');
reset role;

-- 12.6 Cocina sin datos personales
select tests.claims('authenticated', tests.u('a4'));
set role authenticated;
select tests.ok((select count(*) from public.orders) = 0 and (select count(*) from public.order_items) = 0, 'cocina: no lee la tabla de pedidos');
select tests.ok((select count(*) from jsonb_array_elements(public.kitchen_orders(tests.piazza()))) >= 1, 'cocina: ve sus comandas');
select tests.ok(not exists (select 1 from jsonb_array_elements(public.kitchen_orders(tests.piazza())) t
  where t ? 'customerPhone' or t ? 'total' or t ? 'paymentStatus' or t ? 'paymentRef'), 'cocina: las comandas no incluyen teléfono, importe ni pago');
select tests.ok(exists (select 1 from jsonb_array_elements(public.kitchen_orders(tests.piazza())) t
  where (t ->> 'id')::uuid = tests.id('o_rec') and t ->> 'customerName' = 'Ana'), 'cocina: ve el nombre solo para identificar pedidos para recoger');
select tests.throws(format('select public.kitchen_orders(%L)', tests.otro()), 'No tienes acceso', 'cocina: no ve la cocina de otro restaurante');
select tests.claims('authenticated', tests.u('a3'));
select tests.ok((select customer_phone from public.orders where id = tests.id('o_rec')) = '600 000 000', 'sala: sí ve el teléfono para avisar al cliente');
reset role;

-- 12.7 Suspensión controlada por la plataforma
select tests.claims('authenticated', tests.u('a1'));
set role authenticated;
select tests.throws(format('update public.restaurants set slug = %L where id = %L', 'otra-direccion', tests.piazza()), 'Solo la plataforma', 'owner: no cambia la dirección web (QR)');
select tests.throws(format('update public.restaurants set suspended_at = now() where id = %L', tests.piazza()), 'Solo la plataforma', 'owner: no suspende su restaurante');
select tests.throws(format('select public.platform_set_suspension(%L, true, %L)', tests.piazza(), 'prueba'), 'Solo la plataforma', 'owner: no usa la suspensión de la plataforma');
select tests.ok(tests.affected(format('update public.restaurants set prep_minutes = 20 where id = %L', tests.piazza())) = 1, 'owner: cambia la configuración de su restaurante');
select tests.claims('authenticated', tests.u('a2'));
select tests.ok(tests.affected(format('update public.restaurants set prep_minutes = 30 where id = %L', tests.piazza())) = 0, 'manager: no cambia la configuración del restaurante');
reset role;
select tests.claims('anon', null);
set role anon;
insert into tests.vars select 'on9', public.create_order(tests.online(109, 1));
reset role;
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select tests.throws(format('select public.platform_set_suspension(%L, true, %L)', tests.piazza(), ' '), 'motivo', 'suspender exige un motivo');
select public.platform_set_suspension(tests.piazza(), true, 'Prueba de impago');
select public.platform_set_suspension(tests.otro(), true, 'Revisión');
select tests.ok(tests.affected(format('update public.restaurants set slug = %L where id = %L', 'la-piazza-centro', tests.piazza())) = 1, 'plataforma: cambia la dirección web');
reset role;
select tests.claims('anon', null);
set role anon;
select tests.throws(format('select public.create_order(%L)', tests.payload(500)), 'no acepta pedidos', 'suspendido: no acepta pedidos');
select tests.throws(format('select public.customer_switch_to_counter(%L, %L)', tests.id('on9'), tests.tok(109)), 'no acepta pedidos', 'suspendido: no se puede pasar a caja');
reset role;
select tests.claims('service_role', null);
set role service_role;
select tests.throws(format('select public.payment_checkout_started(%L, %L, 900)', tests.id('on9'), 'cs_9'), 'no está disponible', 'suspendido: no se abren cobros');
reset role;
select tests.claims('authenticated', tests.u('a1'));
set role authenticated;
select tests.ok(tests.affected(format('update public.restaurants set active = false where id = %L', tests.piazza())) = 1, 'owner: puede cerrar su restaurante');
select tests.ok(tests.affected(format('update public.restaurants set active = true where id = %L', tests.piazza())) = 1, 'owner: puede volver a abrirlo');
select tests.throws(format('update public.restaurants set suspended_at = null where id = %L', tests.piazza()), 'Solo la plataforma', 'owner: no levanta la suspensión');
reset role;
select tests.claims('anon', null);
set role anon;
select tests.throws(format('select public.create_order(%L)', tests.payload(501)), 'no acepta pedidos', 'suspendido: abrir el restaurante no basta');
reset role;
select tests.claims('authenticated', tests.u('a3'));
set role authenticated;
select public.staff_set_prep_status(tests.id('o_rec'), 'en_preparacion');
reset role;
select tests.ok((select prep_status = 'en_preparacion' from public.orders where id = tests.id('o_rec')), 'suspendido: el personal termina los pedidos ya hechos');
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select public.platform_set_suspension(tests.piazza(), false, 'Pago recibido');
select public.platform_set_suspension(tests.otro(), false, '');
reset role;
select tests.claims('anon', null);
set role anon;
select tests.ok((public.create_order(tests.payload(502, jsonb_build_object('items', jsonb_build_array(
  jsonb_build_object('productId', '5e5e0000-0000-4000-8000-000000000201', 'quantity', 1))))) ->> 'total') = '650', 'reactivado: vuelve a aceptar pedidos');
reset role;

-- 12.8 Registro de auditoría
select tests.claims(null, null);
create function tests.logged(rid uuid, act text) returns boolean language sql as $$
  select exists (select 1 from private.audit_log where restaurant_id is not distinct from rid and action = act) $$;
select tests.ok(tests.logged(tests.piazza(), 'personal.alta') and tests.logged(tests.piazza(), 'personal.cambio_funcion')
  and tests.logged(tests.piazza(), 'personal.baja'), 'auditoría: altas, cambios y bajas de personal');
select tests.ok(tests.logged(tests.piazza(), 'carta.precio') and tests.logged(tests.piazza(), 'carta.baja_producto'), 'auditoría: cambios de precio y retirada de productos');
select tests.ok(tests.logged(tests.piazza(), 'pedido.cancelacion') and tests.logged(tests.piazza(), 'pedido.cobro_caja'), 'auditoría: cancelaciones y cobros');
select tests.ok(tests.logged(tests.piazza(), 'restaurante.suspension') and tests.logged(tests.piazza(), 'restaurante.reactivacion')
  and tests.logged(tests.piazza(), 'restaurante.slug'), 'auditoría: suspensiones, reactivaciones y dirección web');
select tests.ok(tests.logged(tests.otro(), 'pago.verificado') and tests.logged(null, 'plataforma.alta_admin'), 'auditoría: pagos verificados y altas de plataforma');
select tests.ok(exists (select 1 from private.audit_log where action = 'personal.alta' and target_id = tests.u('a5')::text
  and actor_user_id = tests.u('a1') and actor_kind = 'personal'), 'auditoría: registra quién dio de alta (owner, personal)');
select tests.ok(exists (select 1 from private.audit_log where action = 'carta.precio' and actor_user_id = tests.u('a2')), 'auditoría: registra quién cambió un precio (manager)');
select tests.ok(exists (select 1 from private.audit_log where action = 'pedido.cobro_caja' and actor_user_id = tests.u('a3')), 'auditoría: registra quién cobró (sala)');
select tests.ok(exists (select 1 from private.audit_log where action = 'restaurante.suspension' and actor_user_id = tests.u('ad')
  and actor_kind = 'plataforma' and details ->> 'motivo' = 'Prueba de impago'), 'auditoría: suspensión con autor y motivo');
select tests.ok(exists (select 1 from private.audit_log where action = 'pago.verificado' and actor_kind = 'servidor'), 'auditoría: pago verificado por el servidor');
select tests.ok(exists (select 1 from private.audit_log where action = 'plataforma.consulta_equipo' and actor_user_id = tests.u('ad')
  and restaurant_id = tests.piazza()), 'auditoría: la plataforma no consulta equipos sin dejar rastro');
select tests.throws('update private.audit_log set action = $$x$$', 'no se puede modificar', 'auditoría: no se puede modificar');
select tests.throws('delete from private.audit_log', 'no se puede modificar', 'auditoría: no se puede borrar');
select tests.throws('truncate private.audit_log', 'no se puede modificar', 'auditoría: no se puede vaciar');
select tests.claims('authenticated', tests.u('a1'));
set role authenticated;
select tests.ok((select count(*) from public.audit_list(tests.piazza(), 500)) = (select count(*) from public.audit_list(tests.piazza(), 500) where true)
  and (select count(*) from public.audit_list(tests.piazza(), 500)) > 10, 'owner: lee el registro de su restaurante');
select tests.ok(not exists (select 1 from public.audit_list(tests.piazza(), 500) where details ->> 'motivo' = 'Revisión'), 'owner: el registro no incluye otros restaurantes');
select tests.throws('select * from private.audit_log', 'permission denied', 'owner: no lee la tabla del registro directamente');
select tests.throws(format('select * from public.audit_list(%L, 10)', tests.otro()), 'No tienes acceso', 'owner: no lee el registro de otro restaurante');
select tests.throws('select * from public.audit_list(null, 10)', 'No tienes acceso', 'owner: no lee el registro de la plataforma');
select tests.claims('authenticated', tests.u('a2'));
select tests.throws(format('select * from public.audit_list(%L, 10)', tests.piazza()), 'No tienes acceso', 'manager: no lee el registro');
select tests.claims('authenticated', tests.u('a4'));
select tests.throws(format('select * from public.audit_list(%L, 10)', tests.piazza()), 'No tienes acceso', 'cocina: no lee el registro');
select tests.claims('authenticated', tests.u('ad'));
select tests.ok((select count(*) from public.audit_list(null, 500)) > 10, 'plataforma: lee el registro completo');
reset role;
select tests.ok(exists (select 1 from private.audit_log where action = 'plataforma.consulta_registro' and actor_user_id = tests.u('ad')), 'auditoría: la consulta del registro por la plataforma queda registrada');
select tests.claims('service_role', null);
set role service_role;
select tests.throws('select * from private.audit_log', 'permission denied', 'servidor: no lee la tabla del registro');
reset role;
select tests.claims('anon', null);
set role anon;
select tests.throws(format('select * from public.audit_list(%L, 10)', tests.piazza()), 'permission denied', 'anónimo: no lee el registro');
reset role;


-- ===================== 13. MODO SOPORTE (FASE 4) =====================
select tests.claims(null, null);
create function tests.g_status(gid uuid) returns text language sql as $$
  select private.support_status(status, expires_at) from private.support_grants where id = gid $$;
create function tests.gid(k text) returns uuid language sql stable as $$ select (val #>> '{}')::uuid from tests.vars where key = k $$;

-- 13.1 Sin solicitud ni aprobación no hay acceso
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select tests.ok((public.support_view_orders(tests.piazza()) ->> 'ok') = 'false', 'soporte: sin aprobación no hay acceso a pedidos');
select tests.ok((public.support_view_restaurant(tests.piazza()) ->> 'ok') = 'false', 'soporte: sin aprobación no hay acceso al estado');
select tests.throws(format('select public.support_request(%L, %L)', tests.piazza(), 'corto'), 'de 10 a 300', 'soporte: la solicitud exige un motivo');
insert into tests.vars select 'g1', to_jsonb(public.support_request(tests.piazza(), 'Incidencia: los pedidos no llegan a cocina'));
select tests.throws(format('select public.support_request(%L, %L)', tests.piazza(), 'Otra solicitud para lo mismo'), 'pendiente o un acceso activo', 'soporte: no se acumulan solicitudes');
select tests.ok((public.support_view_orders(tests.piazza()) ->> 'ok') = 'false', 'soporte: una solicitud pendiente no da acceso');
select tests.throws(format('select public.support_decide(%L, true)', tests.gid('g1')), 'Solo el propietario', 'soporte: la plataforma no aprueba su propia solicitud');
select tests.claims('authenticated', tests.u('ae'));
select tests.throws(format('select public.support_decide(%L, true)', tests.gid('g1')), 'Solo el propietario', 'soporte: otra cuenta de plataforma no aprueba');
reset role;
select tests.claims('authenticated', tests.u('a1'));
set role authenticated;
select tests.throws(format('select public.support_request(%L, %L)', tests.piazza(), 'Quiero ver mis propios pedidos'), 'Solo la plataforma', 'soporte: el personal no solicita accesos de soporte');
select tests.claims('authenticated', tests.u('a2'));
select tests.throws(format('select public.support_decide(%L, true)', tests.gid('g1')), 'Solo el propietario', 'soporte: el encargado no aprueba');
select tests.throws(format('select * from public.support_list_for_restaurant(%L)', tests.piazza()), 'Solo el propietario', 'soporte: el encargado no ve las solicitudes');
select tests.claims('authenticated', tests.u('a3'));
select tests.throws(format('select public.support_decide(%L, true)', tests.gid('g1')), 'Solo el propietario', 'soporte: sala no aprueba');
select tests.claims('authenticated', tests.u('b1'));
select tests.throws(format('select public.support_decide(%L, true)', tests.gid('g1')), 'Solo el propietario', 'soporte: el propietario de otro restaurante no aprueba');
select tests.throws(format('select * from public.support_list_for_restaurant(%L)', tests.piazza()), 'Solo el propietario', 'soporte: otro restaurante no ve las solicitudes');

-- 13.2 El propietario ve y aprueba: 2 horas exactas
select tests.claims('authenticated', tests.u('a1'));
select tests.ok(exists (select 1 from public.support_list_for_restaurant(tests.piazza())
  where id = tests.gid('g1') and status = 'pendiente' and requested_by_email = 'admin@plataforma.test'
  and reason like 'Incidencia%'), 'soporte: el propietario ve la solicitud, quién la pide y el motivo');
select public.support_decide(tests.gid('g1'), true);
select tests.throws(format('select public.support_decide(%L, true)', tests.gid('g1')), 'ya no está pendiente', 'soporte: no se aprueba dos veces');
reset role;
select tests.ok((select expires_at - decided_at = interval '2 hours' and decided_by = tests.u('a1') and decided_by_email = 'owner@piazza.test'
  from private.support_grants where id = tests.gid('g1')), 'soporte: dura exactamente 2 horas desde la aprobación y registra quién aprobó');

-- 13.3 Consultas de solo lectura, sin datos personales y registradas
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
insert into tests.vars select 'sv_orders', public.support_view_orders(tests.piazza(), 20) -> 'data';
insert into tests.vars select 'sv_estado', public.support_view_restaurant(tests.piazza()) -> 'data';
insert into tests.vars select 'sv_pagos', public.support_view_payment_events(tests.piazza()) -> 'data';
select tests.ok(jsonb_array_length(tests.v('sv_orders')) >= 3, 'soporte: consulta los pedidos del restaurante');
select tests.ok(not exists (select 1 from jsonb_array_elements(tests.v('sv_orders')) t
  where t ? 'customerName' or t ? 'customerPhone' or t ? 'notes' or t ? 'paymentRef' or t ? 'id'),
  'soporte: los pedidos no incluyen nombre, teléfono, notas ni referencia de pago');
select tests.ok(exists (select 1 from jsonb_array_elements(tests.v('sv_orders')) t, jsonb_array_elements(t -> 'items') i
  where not (i ? 'notes') and i ? 'hasNotes'), 'soporte: las líneas indican si hay notas, sin mostrarlas');
select tests.ok(tests.v('sv_estado') -> 'staff' ? 'owner' and tests.v('sv_estado')::text not like '%@%',
  'soporte: el estado resume el equipo por funciones, sin emails');
select tests.ok((tests.v('sv_estado') ->> 'expiresAt') is not null, 'soporte: el estado indica cuándo caduca el acceso');
select tests.ok(jsonb_typeof(tests.v('sv_pagos')) = 'array', 'soporte: consulta los avisos de pago');
select tests.ok(jsonb_array_length(public.support_view_orders(tests.piazza(), 1000) -> 'data') <= 100, 'soporte: como máximo 100 pedidos por consulta');
-- Solo lectura: ninguna vía de escritura ni de lectura directa
select tests.ok((select count(*) from public.orders) = 0 and (select count(*) from public.order_items) = 0, 'soporte: sigue sin leer las tablas de pedidos');
select tests.throws('select * from private.support_grants', 'permission denied', 'soporte: no lee la tabla de accesos');
select tests.throws(format('select public.kitchen_orders(%L)', tests.piazza()), 'No tienes acceso', 'soporte: no ve la cocina');
select tests.throws(format('select public.staff_set_prep_status(%L, %L)', tests.id('o_rec'), 'listo'), 'no encontrado', 'soporte: no cambia la preparación');
select tests.throws(format('select public.staff_mark_paid_at_counter(%L)', tests.id('o_rec')), 'no encontrado', 'soporte: no registra cobros');
select tests.ok(tests.affected(format('update public.products set price_cents = 1 where restaurant_id = %L', tests.piazza())) = 0, 'soporte: no cambia precios');
select tests.throws(format('insert into public.categories (restaurant_id, name) values (%L, %L)', tests.piazza(), 'X'), 'row-level security', 'soporte: no crea productos ni categorías');
select tests.throws(format('select public.staff_add_member(%L, %L, %L)', tests.piazza(), 'admin@plataforma.test', 'owner'), 'propio acceso', 'soporte: no se convierte en personal');
select tests.throws(format('select public.support_decide(%L, true)', tests.gid('g1')), 'Solo el propietario', 'soporte: no puede ampliar ni reaprobar su acceso');
-- Aislamiento: el acceso es solo para ese restaurante y esa cuenta
select tests.ok((public.support_view_orders(tests.otro()) ->> 'ok') = 'false', 'soporte: el acceso de La Piazza no sirve para otro restaurante');
select tests.claims('authenticated', tests.u('ae'));
select tests.ok((public.support_view_orders(tests.piazza()) ->> 'ok') = 'false', 'soporte: otra cuenta de plataforma no usa el acceso ajeno');
select tests.throws(format('select public.support_cancel(%L)', tests.gid('g1')), 'Solicitud no encontrada', 'soporte: otra cuenta de plataforma no cancela solicitudes ajenas');
select tests.claims('authenticated', tests.u('a4'));
select tests.ok((public.support_view_orders(tests.piazza()) ->> 'ok') = 'false', 'soporte: el personal no usa las funciones de soporte');
reset role;
select tests.ok((select count(*) from private.audit_log where action = 'soporte.consulta' and actor_user_id = tests.u('ad')
  and target_id = tests.gid('g1')::text and details ->> 'consulta' in ('pedidos', 'estado', 'avisos_pago')) >= 3,
  'soporte: cada consulta queda registrada con el acceso y lo consultado');
select tests.ok(not exists (select 1 from public.restaurant_staff where user_id = tests.u('ad')), 'soporte: aprobar no convierte a la plataforma en personal');

-- 13.4 Caducidad: al pasar las 2 horas no hay acceso, aunque la sesión siga abierta
select tests.claims(null, null);
update private.support_grants set decided_at = decided_at - interval '3 hours', expires_at = expires_at - interval '3 hours' where id = tests.gid('g1');
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select tests.ok((public.support_view_orders(tests.piazza()) ->> 'ok') = 'false', 'caducidad: sin acceso tras 2 horas');
select tests.ok(exists (select 1 from public.support_my_requests() where id = tests.gid('g1') and status = 'caducada'), 'caducidad: la plataforma ve su acceso como caducado');
reset role;
select tests.claims('authenticated', tests.u('a1'));
set role authenticated;
select tests.throws(format('select public.support_revoke(%L)', tests.gid('g1')), 'ya no está activo', 'caducidad: no se revoca un acceso caducado');
reset role;
select tests.claims(null, null);
select tests.throws(format('update private.support_grants set expires_at = now() + interval %L where id = %L', '1 day', tests.gid('g1')), 'no se puede ampliar|violates check', 'caducidad: nadie puede ampliar un acceso');
select tests.throws(format('update private.support_grants set decided_at = now(), expires_at = now() + interval %L where id = %L', '2 hours', tests.gid('g1')),
  'no se puede ampliar', 'caducidad: no se reactiva un acceso caducado (ni desde el SQL Editor)');
select tests.ok(tests.g_status(tests.gid('g1')) = 'caducada', 'caducidad: sigue caducado tras los intentos');
select tests.throws($$insert into private.support_grants (restaurant_id, requested_by, requested_by_email, reason, status, decided_at, expires_at)
  values ('5e5e0000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-0000000000ad', 'x', 'Acceso directo sin aprobar', 'aprobada', now(), now() + interval '2 hours')$$,
  'siempre empieza pendiente', 'nadie crea un acceso ya aprobado (ni desde el SQL Editor)');
select tests.throws(format('delete from private.support_grants where id = %L', tests.gid('g1')), 'no se puede borrar', 'el historial de accesos no se puede borrar');

-- 13.5 Rechazo
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
insert into tests.vars select 'g2', to_jsonb(public.support_request(tests.piazza(), 'Revisar configuración de pagos'));
reset role;
select tests.claims('authenticated', tests.u('a1'));
set role authenticated;
select public.support_decide(tests.gid('g2'), false);
reset role;
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select tests.ok((public.support_view_orders(tests.piazza()) ->> 'ok') = 'false', 'rechazo: una solicitud rechazada no da acceso');
reset role;
select tests.ok(tests.g_status(tests.gid('g2')) = 'rechazada', 'rechazo: queda como rechazada');

-- 13.6 Revocación: efecto inmediato en la misma sesión
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
insert into tests.vars select 'g3', to_jsonb(public.support_request(tests.piazza(), 'Diagnóstico de pedidos duplicados'));
reset role;
select tests.claims('authenticated', tests.u('a1'));
set role authenticated;
select public.support_decide(tests.gid('g3'), true);
reset role;
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select tests.ok(jsonb_typeof(public.support_view_orders(tests.piazza(), 5) -> 'data') = 'array', 'revocación: antes de revocar, hay acceso');
reset role;
select tests.claims('authenticated', tests.u('a1'));
set role authenticated;
select public.support_revoke(tests.gid('g3'));
reset role;
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select tests.ok((public.support_view_orders(tests.piazza()) ->> 'ok') = 'false', 'revocación: sin acceso inmediatamente después');
select tests.ok((public.support_view_restaurant(tests.piazza()) ->> 'ok') = 'false', 'revocación: ninguna consulta funciona');
reset role;
select tests.ok((select status = 'revocada' and revoked_by = tests.u('a1') and revoked_at is not null from private.support_grants where id = tests.gid('g3')),
  'revocación: registra quién revocó y cuándo');

-- 13.7 Cancelación por quien lo pidió y requisito de seguir siendo plataforma
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
insert into tests.vars select 'g4', to_jsonb(public.support_request(tests.piazza(), 'Solicitud que ya no hace falta'));
select public.support_cancel(tests.gid('g4'));
reset role;
select tests.claims('authenticated', tests.u('a1'));
set role authenticated;
select tests.throws(format('select public.support_decide(%L, true)', tests.gid('g4')), 'ya no está pendiente', 'cancelación: una solicitud cancelada no se puede aprobar');
reset role;
select tests.claims('authenticated', tests.u('ae'));
set role authenticated;
insert into tests.vars select 'g5', to_jsonb(public.support_request(tests.otro(), 'Incidencia en cobros online'));
reset role;
select tests.claims('authenticated', tests.u('b1'));
set role authenticated;
select public.support_decide(tests.gid('g5'), true);
reset role;
select tests.claims('authenticated', tests.u('ae'));
set role authenticated;
select tests.ok(jsonb_typeof(public.support_view_payment_events(tests.otro()) -> 'data') = 'array', 'otro restaurante: su propietario concede su propio acceso');
select tests.ok((public.support_view_orders(tests.piazza()) ->> 'ok') = 'false', 'otro restaurante: ese acceso no sirve para La Piazza');
reset role;
select tests.claims(null, null);
delete from public.platform_admins where user_id = tests.u('ae');
select tests.claims('authenticated', tests.u('ae'));
set role authenticated;
select tests.ok((public.support_view_orders(tests.otro()) ->> 'ok') = 'false', 'quien deja de ser plataforma pierde el acceso al momento');
reset role;

-- 13.8 Registro completo y visibilidad para el propietario
select tests.claims(null, null);
select tests.ok(tests.logged(tests.piazza(), 'soporte.solicitud') and tests.logged(tests.piazza(), 'soporte.aprobacion')
  and tests.logged(tests.piazza(), 'soporte.rechazo') and tests.logged(tests.piazza(), 'soporte.revocacion')
  and tests.logged(tests.piazza(), 'soporte.cancelacion') and tests.logged(tests.piazza(), 'soporte.caducidad_adelantada'),
  'registro: solicitud, aprobación, rechazo, revocación, cancelación y cambios de caducidad');
select tests.ok(exists (select 1 from private.audit_log where action = 'soporte.solicitud' and actor_user_id = tests.u('ad') and details ->> 'motivo' like 'Incidencia%'),
  'registro: quién solicitó y con qué motivo');
select tests.ok(exists (select 1 from private.audit_log where action = 'soporte.aprobacion' and actor_user_id = tests.u('a1')
  and details ? 'inicio' and details ? 'caduca'), 'registro: quién aprobó, inicio y caducidad');
select tests.ok(exists (select 1 from private.audit_log where action = 'soporte.revocacion' and actor_user_id = tests.u('a1') and details ? 'fin'),
  'registro: quién revocó y cuándo');
select tests.claims('authenticated', tests.u('a1'));
set role authenticated;
select tests.ok((select count(*) from public.audit_list(tests.piazza(), 500) where action = 'soporte.consulta') >= 3,
  'el propietario ve en su registro cada consulta de soporte');
select tests.ok(not exists (select 1 from public.audit_list(tests.piazza(), 500) where details ->> 'motivo' = 'Incidencia en cobros online'),
  'el registro de La Piazza no incluye el soporte de otro restaurante');
reset role;
select tests.claims('anon', null);
set role anon;
select tests.throws(format('select public.support_request(%L, %L)', tests.piazza(), 'Intento anónimo de soporte'), 'permission denied', 'anónimo: no usa el modo soporte');
select tests.throws(format('select public.support_view_orders(%L)', tests.piazza()), 'permission denied', 'anónimo: no consulta datos de soporte');
reset role;
select tests.claims('authenticated', tests.u('ee'));
set role authenticated;
select tests.throws('select * from public.support_my_requests()', 'Solo la plataforma', 'sin rol: no tiene solicitudes de soporte');
reset role;


-- ===================== 14. CADUCIDAD DE SOLICITUDES Y REGISTRO DE DENEGACIONES (FASE 5) =====================
select tests.claims(null, null);
-- Motivo de la última denegación anotada para (usuario, restaurante, operación)
create function tests.denial(uid uuid, rid uuid, op text) returns text language sql as $$
  select reason from private.support_denials where actor_user_id = uid and restaurant_id is not distinct from rid and operation = op
  order by last_at desc limit 1 $$;
-- Consulta de soporte como el usuario indicado; devuelve la respuesta
create function tests.view(fn text, rid uuid) returns jsonb language plpgsql as $$
declare r jsonb; begin execute format('select public.%I(%L)', fn, rid) into r; return r; end $$;
create function tests.reason(r jsonb) returns text language sql immutable as $$ select r ->> 'reason' $$;

-- 14.1 Una solicitud pendiente caduca a las 24 horas
-- (insertada desde el SQL Editor con 25 h de antigüedad para simular el paso del tiempo)
insert into private.support_grants (restaurant_id, requested_by, requested_by_email, reason, requested_at)
values (tests.otro(), tests.u('ad'), 'admin@plataforma.test', 'Solicitud de hace 25 horas', now() - interval '25 hours');
insert into tests.vars select 'g6', to_jsonb((select id from private.support_grants where reason = 'Solicitud de hace 25 horas'));
select tests.claims('authenticated', tests.u('b1'));
set role authenticated;
select tests.ok(exists (select 1 from public.support_list_for_restaurant(tests.otro()) where id = tests.gid('g6') and status = 'solicitud_caducada'),
  'caducidad 24 h: el propietario la ve como caducada');
select tests.throws(format('select public.support_decide(%L, true)', tests.gid('g6')), 'caducó sin respuesta', 'caducidad 24 h: no se puede aprobar');
select tests.throws(format('select public.support_decide(%L, false)', tests.gid('g6')), 'caducó sin respuesta', 'caducidad 24 h: tampoco se rechaza (ya está cerrada)');
reset role;
select tests.claims(null, null);
select tests.throws(format('update private.support_grants set status = %L, decided_at = now(), expires_at = now() + interval %L where id = %L',
  'aprobada', '2 hours', tests.gid('g6')), 'caducó sin respuesta', 'caducidad 24 h: no se reactiva ni desde el SQL Editor');
select tests.throws($$insert into private.support_grants (restaurant_id, requested_by, requested_by_email, reason, requested_at)
  values ('b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-0000000000ad', 'x', 'Solicitud con fecha futura', now() + interval '1 day')$$,
  'fecha futura', 'caducidad 24 h: no se crean solicitudes con fecha futura');
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select tests.ok(tests.reason(tests.view('support_view_orders', tests.otro())) = 'solicitud_caducada', 'denegación: solicitud caducada');
select tests.ok(exists (select 1 from public.support_my_requests() where id = tests.gid('g6') and status = 'solicitud_caducada'), 'caducidad 24 h: la plataforma la ve caducada');
select tests.throws(format('select public.support_cancel(%L)', tests.gid('g6')), 'ya está cerrada', 'caducidad 24 h: no se puede cancelar ni reabrir');
insert into tests.vars select 'g7', to_jsonb(public.support_request(tests.otro(), 'Nueva solicitud tras la caducada'));
select tests.ok(tests.reason(tests.view('support_view_orders', tests.otro())) = 'pendiente', 'denegación: solicitud pendiente');
reset role;
select tests.claims('authenticated', tests.u('b1'));
set role authenticated;
select public.support_decide(tests.gid('g7'), true);
reset role;
select tests.ok((select expires_at - decided_at = interval '2 hours' from private.support_grants where id = tests.gid('g7')), 'aprobada: sigue durando exactamente 2 horas');

-- Una solicitud de 23 h todavía se puede aprobar (2 h desde la aprobación)
insert into private.support_grants (restaurant_id, requested_by, requested_by_email, reason, requested_at)
values (tests.piazza(), tests.u('ad'), 'admin@plataforma.test', 'Solicitud de hace 23 horas', now() - interval '23 hours');
insert into tests.vars select 'g9', to_jsonb((select id from private.support_grants where reason = 'Solicitud de hace 23 horas'));
select tests.claims('authenticated', tests.u('a1'));
set role authenticated;
select public.support_decide(tests.gid('g9'), true);
reset role;
select tests.ok((select status = 'aprobada' and expires_at - decided_at = interval '2 hours' from private.support_grants where id = tests.gid('g9')),
  'caducidad 24 h: antes de las 24 h se aprueba con 2 h desde la aprobación');

-- 14.2 Aprobada: funciona en su restaurante; en otro, denegado y anotado
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select tests.ok((tests.view('support_view_orders', tests.otro()) ->> 'ok') = 'true', 'aprobada: consulta permitida');
select tests.ok((tests.view('support_view_orders', tests.piazza()) ->> 'ok') = 'true', 'aprobada: el otro acceso aprobado también funciona');
reset role;
select tests.claims('authenticated', tests.u('a1'));
set role authenticated;
select public.support_revoke(tests.gid('g9'));
reset role;
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select tests.ok(tests.reason(tests.view('support_view_orders', tests.piazza())) = 'revocada', 'denegación: acceso revocado (al instante)');
select tests.ok(tests.reason(tests.view('support_view_orders', (select id from public.restaurants where slug = 'nuevo-sitio'))) = 'otro_restaurante',
  'denegación: intento de consultar otro restaurante');
select tests.ok(tests.reason(tests.view('support_view_orders', '00000000-0000-4000-8000-0000000000ff')) = 'restaurante_inexistente',
  'denegación: restaurante inexistente');
select public.support_cancel(tests.gid('g7'));
select tests.ok(tests.reason(tests.view('support_view_orders', tests.otro())) = 'cancelada', 'denegación: acceso cancelado');
select tests.ok(tests.reason(tests.view('support_view_orders', (select id from public.restaurants where slug = 'nuevo-sitio'))) = 'sin_solicitud',
  'denegación: sin solicitud');
insert into tests.vars select 'g10', to_jsonb(public.support_request(tests.otro(), 'Otra incidencia que caducará'));
reset role;
select tests.claims('authenticated', tests.u('b1'));
set role authenticated;
select public.support_decide(tests.gid('g10'), true);
reset role;
select tests.claims(null, null);
update private.support_grants set decided_at = decided_at - interval '3 hours', expires_at = expires_at - interval '3 hours' where id = tests.gid('g10');
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select tests.ok(tests.reason(tests.view('support_view_orders', tests.otro())) = 'caducada', 'denegación: acceso caducado (2 h)');
insert into tests.vars select 'g12', to_jsonb(public.support_request(tests.piazza(), 'Solicitud que será rechazada'));
reset role;
select tests.claims('authenticated', tests.u('a1'));
set role authenticated;
select public.support_decide(tests.gid('g12'), false);
select tests.ok(tests.reason(tests.view('support_view_orders', tests.piazza())) = 'no_es_plataforma', 'denegación: el personal intenta usar el soporte');
reset role;
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select tests.ok(tests.reason(tests.view('support_view_orders', tests.piazza())) = 'rechazada', 'denegación: solicitud rechazada');

-- 14.3 Las denegaciones no devuelven datos y quedan anotadas aunque la consulta se deniegue
select tests.ok((select array_agg(k order by k) from jsonb_object_keys(tests.view('support_view_orders', tests.piazza())) k) = array['message', 'ok', 'reason'],
  'denegación: la respuesta solo trae el motivo, ningún dato');
reset role;
select tests.claims(null, null);
select tests.ok(tests.denial(tests.u('ad'), tests.otro(), 'pedidos') is not null and tests.denial(tests.u('ad'), tests.piazza(), 'pedidos') = 'rechazada'
  and tests.denial(tests.u('a1'), tests.piazza(), 'pedidos') = 'no_es_plataforma', 'registro: las denegaciones persisten tras la petición');
select tests.ok((select count(distinct reason) from private.support_denials where actor_user_id = tests.u('ad')) >= 8,
  'registro: anota cada motivo de rechazo');
select tests.ok(exists (select 1 from private.support_denials where actor_user_id = tests.u('a1') and actor_kind = 'personal')
  and exists (select 1 from private.support_denials where actor_user_id = tests.u('ad') and actor_kind = 'plataforma'),
  'registro: guarda quién lo intentó y de qué tipo');
select tests.ok((select array_agg(column_name::text order by column_name) from information_schema.columns
  where table_schema = 'private' and table_name = 'support_denials')
  = array['actor_kind', 'actor_user_id', 'attempts', 'first_at', 'id', 'last_at', 'operation', 'reason', 'restaurant_id', 'window_start'],
  'registro: solo guarda usuario, restaurante, fechas, operación, motivo y contador (sin emails, tokens ni datos de clientes)');

-- 14.4 Intentos repetidos: se cuentan, no se multiplican
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select tests.view('support_view_restaurant', tests.piazza()) from generate_series(1, 5);
reset role;
select tests.claims(null, null);
select tests.ok((select attempts = 5 and count(*) over () = 1 from private.support_denials
  where actor_user_id = tests.u('ad') and restaurant_id = tests.piazza() and operation = 'estado' and reason = 'rechazada'),
  'repetidos: 5 intentos iguales ocupan una sola fila con contador 5');

-- 14.5 Saturación: con muchos restaurantes distintos, el registro no crece sin límite
select tests.claims('authenticated', tests.u('ee'));
set role authenticated;
select tests.view('support_view_orders', gen_random_uuid()) from generate_series(1, 80);
reset role;
select tests.claims(null, null);
select tests.ok((select count(*) from private.support_denials where actor_user_id = tests.u('ee')) <= 51,
  'saturación: como máximo 50 combinaciones por usuario y ventana (+1 fila de límite)');
select tests.ok((select attempts from private.support_denials where actor_user_id = tests.u('ee') and reason = 'limite_superado') = 30,
  'saturación: el exceso se suma en la fila «límite superado»');

-- 14.6 Nadie puede falsificar, leer ni borrar las denegaciones
select tests.claims('authenticated', tests.u('ad'));
set role authenticated;
select tests.throws('select * from private.support_denials', 'permission denied', 'falsificación: la plataforma no lee la tabla directamente');
select tests.throws($$insert into private.support_denials (window_start, actor_kind, operation, reason) values (now(), 'plataforma', 'pedidos', 'pendiente')$$,
  'permission denied', 'falsificación: nadie inserta denegaciones a mano');
select tests.throws(format('select private.support_log_denial(%L, %L, %L)', tests.piazza(), 'pedidos', 'revocada'), 'permission denied',
  'falsificación: nadie llama a la función interna de anotación');
reset role;
select tests.claims('anon', null);
set role anon;
select tests.throws(format('select public.support_view_orders(%L)', tests.piazza()), 'permission denied', 'anónimo: ni consulta ni anota');
reset role;
select tests.claims(null, null);
select tests.throws('delete from private.support_denials', 'no se puede borrar', 'inmutable: no se borran denegaciones');
select tests.throws('update private.support_denials set attempts = 1 where attempts > 1', 'no se puede modificar', 'inmutable: no se rebaja el contador');
select tests.throws(format('update private.support_denials set actor_user_id = %L', tests.u('ee')), 'no se puede modificar', 'inmutable: no se cambia el autor');
select tests.throws('truncate private.support_denials', 'no se puede borrar', 'inmutable: no se vacía');

-- 14.7 Quién ve las denegaciones: el propietario las de su restaurante; la plataforma, todas
select tests.claims('authenticated', tests.u('a1'));
set role authenticated;
select tests.ok((select count(*) from public.support_denials_list(tests.piazza())) >= 3
  and not exists (select 1 from public.support_denials_list(tests.piazza()) where restaurant_id <> tests.piazza()),
  'owner: ve los intentos sobre su restaurante y solo esos');
select tests.ok(exists (select 1 from public.support_denials_list(tests.piazza()) where actor_email = 'admin@plataforma.test' and reason = 'rechazada'),
  'owner: ve quién lo intentó (email al leer) y por qué');
select tests.throws(format('select * from public.support_denials_list(%L)', tests.otro()), 'No tienes acceso', 'owner: no ve los intentos de otro restaurante');
select tests.throws('select * from public.support_denials_list(null)', 'No tienes acceso', 'owner: no ve los intentos de toda la plataforma');
select tests.claims('authenticated', tests.u('b1'));
select tests.ok(exists (select 1 from public.support_denials_list(tests.otro()) where reason = 'caducada')
  and not exists (select 1 from public.support_denials_list(tests.otro()) where restaurant_id = tests.piazza()),
  'otro restaurante: su propietario ve solo los suyos');
select tests.claims('authenticated', tests.u('a2'));
select tests.throws(format('select * from public.support_denials_list(%L)', tests.piazza()), 'No tienes acceso', 'manager: no ve los intentos');
select tests.claims('authenticated', tests.u('ad'));
select tests.ok(exists (select 1 from public.support_denials_list(null) where reason = 'limite_superado'), 'plataforma: ve todos los intentos, incluido el límite');
reset role;

-- ===================== Resultado =====================
\o
\set QUIET 0
select case when pass then 'OK   ' else 'FALLO' end as estado, name as prueba, case when not pass then detail end as detalle
from tests.results order by id;
select count(*) filter (where pass) as superadas, count(*) filter (where not pass) as fallidas from tests.results;
do $$ begin
  if exists (select 1 from tests.results where not pass) then
    raise exception 'Hay pruebas fallidas';
  end if;
end $$;
