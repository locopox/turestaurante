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
select tests.throws(format('insert into public.restaurant_staff (restaurant_id, user_id, role) values (%L, %L, %L)', tests.piazza(), 'a0000000-0000-4000-8000-0000000000a4', 'owner'), 'row-level security', 'cocina: no puede ascenderse a owner');
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
select tests.ok((select count(distinct restaurant_id) from public.orders) = 2, 'admin: ve pedidos de todos los restaurantes');
select tests.ok((select count(*) from public.my_memberships()) = 2, 'admin: gestiona todos los restaurantes');
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
select tests.ok((select count(*) from public.orders where id in (tests.id('on1'), tests.id('on2'))) = 0, 'cocina: no ve pedidos con pago online pendiente');
select tests.ok((select count(*) from public.orders where id = tests.id('on3')) = 1, 'cocina: sí ve el pedido que pasó a pagar en caja');
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
select tests.ok((select count(*) from public.orders where id = tests.id('on1')) = 1, 'cocina: ve el pedido cuando el pago está verificado');
select tests.ok((select count(*) from public.orders where id in (tests.id('on2'), tests.id('on4'))) = 0, 'cocina: no ve pedidos con el pago pendiente');
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
select tests.ok((select count(*) from pg_policies where schemaname = 'public' and policyname <> 'politica_ajena_prueba') = 15,
  'reejecutar el esquema deja exactamente las 15 políticas del proyecto');
select tests.ok(not has_table_privilege('service_role', 'public.tabla_ajena', 'select')
  and not has_table_privilege('service_role', 'public.tabla_ajena', 'delete'), 'el esquema no da permisos al servidor sobre tablas ajenas');
select tests.ok(has_table_privilege('service_role', 'public.products', 'update')
  and not has_table_privilege('service_role', 'public.orders', 'update')
  and not has_table_privilege('service_role', 'public.order_items', 'insert'), 'servidor: administra la carta pero no escribe pedidos');
select tests.ok((select column_default from information_schema.columns where table_schema = 'public' and table_name = 'restaurants'
  and column_name = 'online_payment_enabled') = 'false', 'pago online desactivado por defecto en restaurantes nuevos');
select tests.ok((select not online_payment_enabled from public.restaurants where id = tests.piazza()), 'La Piazza (seed) tiene el pago online desactivado');
select tests.ok((select not online_payment_enabled from public.restaurants where slug = 'nuevo-sitio'), 'restaurante creado desde la app: pago online desactivado');

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
