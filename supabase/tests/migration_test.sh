#!/usr/bin/env bash
# Prueba la cadena de migraciones en un PostgreSQL LOCAL y desechable. Nunca contra Supabase.
#   a5d5a87 (fase 2) + datos → fase 3 → fase 4 → fase 5 → fase 6  ==  instalación nueva de schema.sql
#   las subidas se pueden repetir y no alteran datos
#   … → fase 6 (ad26da1) → límites de pedidos (fase 7, 886a37c) → base comercial (fase 8)  ==  instalación nueva
#   cada bajada restaura la fase anterior: 8 → 7 (886a37c) → 7 → 6 (ad26da1) → 5 (55c6837) → 4 (b48fb53) → 3 (07348e4) → 2 (a5d5a87)
set -euo pipefail
export PGOPTIONS="-c client_min_messages=warning"
cd "$(dirname "$0")/.."
case "${PGHOST:-localhost}" in *supabase.co*|*supabase.com*) echo "Solo para una base de datos local." >&2; exit 1;; esac
UP3=migrations/20261101120000_fase3_seguridad_roles.sql
UP4=migrations/20261102120000_fase4_modo_soporte.sql
UP5=migrations/20261103120000_fase5_soporte_caducidad_registro.sql
DOWN5=migrations_down/20261103120000_fase5_soporte_caducidad_registro.down.sql
UP6=migrations/20261104120000_fase6_invitaciones.sql
DOWN6=migrations_down/20261104120000_fase6_invitaciones.down.sql
DOWN3=migrations_down/20261101120000_fase3_seguridad_roles.down.sql
DOWN4=migrations_down/20261102120000_fase4_modo_soporte.down.sql
UP7=migrations/20261108120000_limites_pedidos.sql
DOWN7=migrations_down/20261108120000_limites_pedidos.down.sql
UP8=migrations/20261112120000_base_comercial.sql
DOWN8=migrations_down/20261112120000_base_comercial.down.sql
TMP=$(mktemp -d)
git show a5d5a87:supabase/schema.sql > "$TMP/schema_f2.sql"
git show 07348e4:supabase/schema.sql > "$TMP/schema_f3.sql"
git show b48fb53:supabase/schema.sql > "$TMP/schema_f4.sql"
git show 55c6837:supabase/schema.sql > "$TMP/schema_f5.sql"
git show ad26da1:supabase/schema.sql > "$TMP/schema_f6.sql"
git show 886a37c:supabase/schema.sql > "$TMP/schema_f7.sql"
P() { psql -v ON_ERROR_STOP=1 -q -d "$1" "${@:2}"; }
nuevo_db() { psql -q -d postgres -c "drop database if exists $1" -c "create database $1"; P "$1" -f tests/supabase_shim.sql 2>/dev/null; }
volcado() { pg_dump --schema-only -d "$1" | grep -vE '^(--|SET |SELECT pg_catalog|\\(un)?restrict )' | sed '/^$/d' > "$2"; }
datos() { P "$1" -tAc "select (select count(*) from restaurants)||'/'||(select count(*) from products)||'/'||(select count(*) from orders)||'/'||(select count(*) from order_items)||'/'||(select count(*) from restaurant_staff)||'/'||(select coalesce(sum(total_cents),0) from orders)"; }
con_datos() {
  P "$1" -f seed.sql
  P "$1" -c "insert into auth.users (id, email) values ('a0000000-0000-4000-8000-0000000000a1', 'owner@piazza.test')" \
         -c "insert into public.restaurant_staff values ('5e5e0000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-0000000000a1', 'owner')"
  P "$1" -c "select set_config('request.jwt.claims', '{\"role\":\"anon\"}', false)" -c "set role anon" \
         -c "select public.create_order('{\"restaurantId\":\"5e5e0000-0000-4000-8000-000000000001\",\"mode\":\"mesa\",\"table\":3,\"paymentMethod\":\"caja\",\"accessToken\":\"$(printf '%064d' 7)\",\"items\":[{\"productId\":\"5e5e0000-0000-4000-8000-000000000201\",\"quantity\":2}]}')" > /dev/null
}
fallo() { echo "FALLO: $1" >&2; exit 1; }
# Igual, o con las mismas líneas en otro orden (PostgreSQL puede listar permisos en otro orden).
iguales() {
  if diff -q "$1" "$2" > /dev/null; then echo "OK  $3 (estructura idéntica)"
  elif diff -q <(sort "$1") <(sort "$2") > /dev/null; then echo "OK  $3 (mismas líneas; solo cambia el orden de algunos permisos)"
  else diff -u "$1" "$2" | head -40; fallo "$3"; fi
}

nuevo_db mig_ref2; P mig_ref2 -f "$TMP/schema_f2.sql"; volcado mig_ref2 "$TMP/f2.sql"
nuevo_db mig_ref3; P mig_ref3 -f "$TMP/schema_f3.sql"; volcado mig_ref3 "$TMP/f3.sql"
nuevo_db mig_ref4; P mig_ref4 -f "$TMP/schema_f4.sql"; volcado mig_ref4 "$TMP/f4.sql"
nuevo_db mig_ref5; P mig_ref5 -f "$TMP/schema_f5.sql"; volcado mig_ref5 "$TMP/f5.sql"
nuevo_db mig_ref6; P mig_ref6 -f "$TMP/schema_f6.sql"; volcado mig_ref6 "$TMP/f6.sql"
nuevo_db mig_ref7; P mig_ref7 -f "$TMP/schema_f7.sql"; volcado mig_ref7 "$TMP/f7.sql"
nuevo_db mig_ref8; P mig_ref8 -f schema.sql; volcado mig_ref8 "$TMP/f8.sql"
# La base comercial NO cambia nada de los pedidos: mismas funciones y mismos triggers que en la fase 7.
fpedidos() { P "$1" -tAc "select md5(string_agg(pg_get_functiondef(p.oid), '' order by p.proname, p.oid::regprocedure::text))
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public', 'private') and p.proname in (
  'create_order', 'get_customer_order', 'customer_switch_to_counter', 'staff_set_prep_status', 'staff_mark_paid_at_counter',
  'kitchen_orders', 'payment_checkout_started', 'payment_record_result', 'guard_order_update', 'guard_order_items',
  'order_limit_exceeded', 'order_limit_reject', 'order_limits_effective', 'audit_order_changes', 'customer_order_json')"; }
tpedidos() { P "$1" -tAc "select string_agg(tgrelid::regclass || '.' || tgname || ':' || tgfoid::regproc, ',' order by 1)
  from pg_trigger where tgrelid in ('public.orders'::regclass, 'public.order_items'::regclass) and not tgisinternal"; }
[ "$(fpedidos mig_ref7)" = "$(fpedidos mig_ref8)" ] && [ "$(tpedidos mig_ref7)" = "$(tpedidos mig_ref8)" ] \
  || fallo "la base comercial ha cambiado funciones o triggers de los pedidos"
echo "OK  la base comercial no cambia ninguna función ni trigger de los pedidos (15 funciones, $(tpedidos mig_ref8 | tr ',' '\n' | wc -l) triggers)"

nuevo_db mig_cadena; P mig_cadena -f "$TMP/schema_f2.sql"; con_datos mig_cadena; D0=$(datos mig_cadena)
P mig_cadena -f "$UP3"; volcado mig_cadena "$TMP/c3.sql"; iguales "$TMP/f3.sql" "$TMP/c3.sql" "fase 2 + subida fase 3 = esquema de la fase 3"
P mig_cadena -f "$UP4"; volcado mig_cadena "$TMP/c4.sql"; iguales "$TMP/f4.sql" "$TMP/c4.sql" "fase 3 + subida fase 4 = esquema de la fase 4"
# Un acceso de soporte de la fase 4: la fase 5 (subida y bajada) no debe tocarlo.
P mig_cadena -c "insert into auth.users (id, email) values ('a0000000-0000-4000-8000-0000000000ad', 'admin@plataforma.test')" \
  -c "insert into public.platform_admins values ('a0000000-0000-4000-8000-0000000000ad')" \
  -c "insert into private.support_grants (restaurant_id, requested_by, requested_by_email, reason) values ('5e5e0000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-0000000000ad', 'admin@plataforma.test', 'Solicitud anterior a la fase 5')"
soporte() { P mig_cadena -tAc "select count(*) || ':' || string_agg(reason || '/' || status, ',') from private.support_grants"; }
S0=$(soporte)
P mig_cadena -f "$UP5"; volcado mig_cadena "$TMP/c5.sql"; iguales "$TMP/f5.sql" "$TMP/c5.sql" "fase 4 + subida fase 5 = esquema de la fase 5"
[ "$(soporte)" = "$S0" ] || fallo "la subida de la fase 5 ha cambiado los accesos de soporte"
echo "OK  la subida de la fase 5 conserva los accesos de soporte ($S0)"
# Cuentas y propietario de La Piazza antes de la fase 6 (no deben cambiar).
cuentas() { P mig_cadena -tAc "select string_agg(id || ':' || email, ',' order by id) || '|' || (select string_agg(user_id || ':' || role, ',' order by user_id) from restaurant_staff) || '|' || (select active::text from restaurants where id = '5e5e0000-0000-4000-8000-000000000001') from auth.users"; }
U0=$(cuentas)
P mig_cadena -f "$UP6"; volcado mig_cadena "$TMP/c6.sql"; iguales "$TMP/f6.sql" "$TMP/c6.sql" "fase 5 + subida fase 6 = esquema de la fase 6"
[ "$(soporte)" = "$S0" ] || fallo "la subida de la fase 6 ha cambiado los accesos de soporte"
[ "$(cuentas)" = "$U0" ] || fallo "la subida de la fase 6 ha cambiado cuentas, personal o la apertura de La Piazza"
echo "OK  la subida de la fase 6 conserva cuentas, personal, apertura de La Piazza y accesos de soporte"
[ "$(datos mig_cadena)" = "$D0" ] || fallo "las subidas han cambiado datos"
echo "OK  las subidas conservan los datos ($D0: restaurantes/productos/pedidos/líneas/personal/importe)"
# Pedidos de La Piazza en estados distintos (online pendiente, en preparación, cobrado, cancelado) antes
# de los límites: la subida y la bajada de la fase 7 no deben cambiar ni uno (estado, importe, fechas).
P mig_cadena -c "update public.restaurants set online_payment_enabled = true where id = '5e5e0000-0000-4000-8000-000000000001'" > /dev/null
for n in 8 9 10 11; do
  M=$([ "$n" = 8 ] && echo online || echo caja)
  P mig_cadena -c "select set_config('request.jwt.claims', '{\"role\":\"anon\"}', false)" -c "set role anon" \
    -c "select public.create_order('{\"restaurantId\":\"5e5e0000-0000-4000-8000-000000000001\",\"mode\":\"mesa\",\"table\":4,\"paymentMethod\":\"$M\",\"accessToken\":\"$(printf '%064d' $n)\",\"items\":[{\"productId\":\"5e5e0000-0000-4000-8000-000000000201\",\"quantity\":$n}]}')" > /dev/null
done
P mig_cadena -c "update public.orders set prep_status = 'en_preparacion' where total_cents = (select min(total_cents) from public.orders where payment_method = 'caja' and total_cents > 0 and table_number = 4)" \
  -c "update public.orders set payment_status = 'cobrado_caja' where payment_method = 'caja' and table_number = 4 and prep_status = 'nuevo' and total_cents = (select max(total_cents) from public.orders where table_number = 4)" \
  -c "update public.orders set prep_status = 'cancelado' where table_number = 4 and payment_status = 'pendiente_caja' and prep_status = 'nuevo'" > /dev/null
pedidos() { P mig_cadena -tAc "select count(*) || ':' || md5(string_agg(id::text || payment_method::text || payment_status::text || prep_status::text || total_cents::text || created_at::text || updated_at::text, '|' order by id)) from public.orders"; }
estados() { P mig_cadena -tAc "select string_agg(distinct payment_status || '/' || prep_status, ',') from public.orders"; }
O0=$(pedidos); D0=$(datos mig_cadena)   # con los pedidos nuevos
P mig_cadena -f "$UP7"; volcado mig_cadena "$TMP/c7.sql"; iguales "$TMP/f7.sql" "$TMP/c7.sql" "fase 6 + subida de los límites = esquema de la fase 7"
[ "$(pedidos)" = "$O0" ] || fallo "la subida de los límites ha cambiado pedidos"
echo "OK  la subida de los límites conserva cada pedido, su estado, su importe y sus fechas ($(estados))"
[ "$(cuentas)" = "$U0" ] && [ "$(soporte)" = "$S0" ] || fallo "la subida de los límites ha cambiado cuentas, personal o soporte"
# Base comercial: cada restaurante que ya existe queda «sin_asignar»; uno nuevo nace «borrador».
P mig_cadena -f "$UP8"; volcado mig_cadena "$TMP/c8.sql"; iguales "$TMP/f8.sql" "$TMP/c8.sql" "fase 7 + subida de la base comercial = instalación nueva"
[ "$(pedidos)" = "$O0" ] && [ "$(datos mig_cadena)" = "$D0" ] && [ "$(cuentas)" = "$U0" ] && [ "$(soporte)" = "$S0" ] \
  || fallo "la subida de la base comercial ha cambiado pedidos, datos, cuentas o soporte"
comerciales() { P mig_cadena -tAc "select count(*) || ':' || count(*) filter (where status = 'sin_asignar' and origin = 'existente' and plan_code is null and trial_started_at is null) from private.tenant_accounts"; }
NR=$(P mig_cadena -tAc "select count(*) from public.restaurants")
[ "$(comerciales)" = "$NR:$NR" ] || fallo "no todos los restaurantes existentes tienen su cuenta «sin_asignar» ($(comerciales) de $NR)"
echo "OK  la subida de la base comercial conserva pedidos, datos y cuentas; los $NR restaurantes existentes quedan «sin_asignar»"
NUEVO=$(P mig_cadena -c "begin" -c "insert into public.restaurants (slug, name) values ('nuevo-tras-migracion', 'Nuevo')" \
  -c "select a.status || '/' || a.origin from private.tenant_accounts a join public.restaurants r on r.id = a.restaurant_id where r.slug = 'nuevo-tras-migracion'" -c "rollback" | grep '/' | tr -d ' ')
[ "$NUEVO" = "borrador/alta" ] || fallo "un restaurante creado tras la migración no empieza en borrador ($NUEVO)"
echo "OK  un restaurante creado después de la migración empieza en «borrador» (nunca «sin_asignar»)"
P mig_cadena -f "$UP3"; P mig_cadena -f "$UP4"; P mig_cadena -f "$UP5"; P mig_cadena -f "$UP6"; P mig_cadena -f "$UP7"; P mig_cadena -f "$UP8"; volcado mig_cadena "$TMP/c6b.sql"
diff -q "$TMP/c8.sql" "$TMP/c6b.sql" > /dev/null || fallo "repetir las subidas cambia la estructura"
[ "$(comerciales)" = "$NR:$NR" ] || fallo "repetir las subidas ha cambiado las cuentas comerciales"
[ "$(pedidos)" = "$O0" ] || fallo "repetir las subidas ha cambiado pedidos"
[ "$(datos mig_cadena)" = "$D0" ] || fallo "repetir las subidas ha cambiado datos"
[ "$(cuentas)" = "$U0" ] || fallo "repetir las subidas ha cambiado cuentas o personal"
echo "OK  las subidas se pueden repetir"
# Con la fase 6: una persona acepta una invitación de La Piazza y otra queda pendiente.
P mig_cadena -c "do \$\$ declare v uuid; begin
  insert into auth.users (id, email) values ('a0000000-0000-4000-8000-0000000000b9', 'invitado@piazza.test');
  insert into private.invitations (restaurant_id, email, role, invited_by, invited_by_kind, expires_at)
    values ('5e5e0000-0000-4000-8000-000000000001', 'invitado@piazza.test', 'waiter', 'a0000000-0000-4000-8000-0000000000a1', 'personal', now() + interval '168 hours')
    returning id into v;
  insert into private.invitations (restaurant_id, email, role, invited_by, invited_by_kind, expires_at)
    values ('5e5e0000-0000-4000-8000-000000000001', 'pendiente@piazza.test', 'kitchen', 'a0000000-0000-4000-8000-0000000000a1', 'personal', now() + interval '168 hours');
  perform set_config('request.jwt.claims', '{\"role\":\"authenticated\",\"sub\":\"a0000000-0000-4000-8000-0000000000b9\"}', true);
  perform public.invitation_accept(v);
end \$\$"
D1=$(datos mig_cadena); U1=$(cuentas)
[ "$D1" != "$D0" ] || fallo "la invitación aceptada no ha dado de alta a nadie"
P mig_cadena -c "insert into private.order_limits (restaurant_id, per_table) values ('5e5e0000-0000-4000-8000-000000000001', 3)" \
  -c "insert into private.order_limit_hits (restaurant_id, window_start, limit_kind, table_number) values ('5e5e0000-0000-4000-8000-000000000001', now(), 'mesa', 4)" > /dev/null
O1=$(pedidos)
P mig_cadena -f "$DOWN8"; volcado mig_cadena "$TMP/b7.sql"; iguales "$TMP/f7.sql" "$TMP/b7.sql" "bajada de la base comercial = esquema de la fase 7"
[ "$(pedidos)" = "$O1" ] && [ "$(datos mig_cadena)" = "$D1" ] && [ "$(cuentas)" = "$U1" ] || fallo "la bajada de la base comercial ha cambiado pedidos, datos o cuentas"
P mig_cadena -tAc "select count(*) from private.audit_log where action = 'comercial.alta'" | grep -qx "$NR" || fallo "la bajada de la base comercial ha perdido entradas de auditoría"
echo "OK  la bajada de la base comercial conserva pedidos, datos, cuentas y el registro de auditoría"
P mig_cadena -f "$DOWN7"; volcado mig_cadena "$TMP/b6.sql"; iguales "$TMP/f6.sql" "$TMP/b6.sql" "bajada de los límites = esquema de la fase 6"
[ "$(pedidos)" = "$O1" ] && [ "$(datos mig_cadena)" = "$D1" ] && [ "$(cuentas)" = "$U1" ] || fallo "la bajada de los límites ha cambiado pedidos, datos o cuentas"
echo "OK  la bajada de los límites conserva cada pedido, su estado, su importe y sus fechas"
P mig_cadena -f "$DOWN6"; volcado mig_cadena "$TMP/b5.sql"; iguales "$TMP/f5.sql" "$TMP/b5.sql" "bajada fase 6 = esquema de la fase 5"
[ "$(datos mig_cadena)" = "$D1" ] && [ "$(cuentas)" = "$U1" ] || fallo "la bajada de la fase 6 ha cambiado datos, cuentas o personal"
[ "$(soporte)" = "$S0" ] || fallo "la bajada de la fase 6 ha cambiado los accesos de soporte"
echo "OK  la bajada de la fase 6 conserva datos, cuentas, personal (incluida la persona que aceptó) y soporte"
P mig_cadena -tAc "select count(*) from private.audit_log where action like 'invitacion.%'" | grep -qx 3 || fallo "la bajada de la fase 6 ha perdido entradas de auditoría"
echo "OK  la bajada de la fase 6 conserva el registro de auditoría de las invitaciones"
P mig_cadena -f "$DOWN5"; volcado mig_cadena "$TMP/b4.sql"; iguales "$TMP/f4.sql" "$TMP/b4.sql" "bajada fase 5 = esquema de la fase 4"
[ "$(soporte)" = "$S0" ] || fallo "la bajada de la fase 5 ha cambiado los accesos de soporte"
echo "OK  la bajada de la fase 5 conserva los accesos de soporte"
P mig_cadena -f "$DOWN4"; volcado mig_cadena "$TMP/b3.sql"; iguales "$TMP/f3.sql" "$TMP/b3.sql" "bajada fase 4 = esquema de la fase 3"
P mig_cadena -f "$DOWN3"; volcado mig_cadena "$TMP/b2.sql"; iguales "$TMP/f2.sql" "$TMP/b2.sql" "bajada fase 3 = esquema de la fase 2"
[ "$(datos mig_cadena)" = "$D1" ] || fallo "las bajadas han cambiado datos"
echo "OK  las bajadas conservan pedidos, carta, restaurantes y personal"
psql -q -d postgres -c "drop database mig_ref2" -c "drop database mig_ref3" -c "drop database mig_ref4" -c "drop database mig_ref5" -c "drop database mig_ref6" -c "drop database mig_ref7" -c "drop database mig_ref8" -c "drop database mig_cadena"
rm -rf "$TMP"
echo "Migraciones: todas las comprobaciones superadas"
