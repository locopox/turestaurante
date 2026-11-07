#!/usr/bin/env bash
# Límites de pedidos sin pagar con peticiones SIMULTÁNEAS (sesiones de PostgreSQL en paralelo).
# Lo ejecuta supabase/tests/run.sh en una base de datos LOCAL propia (esquema + La Piazza, sin más datos).
# Comprueba que, aunque lleguen muchas peticiones a la vez, nunca entran más pedidos de los permitidos,
# que un mismo código no duplica pedidos y que no hay bloqueos mutuos (deadlocks).
set -euo pipefail
DB=${1:?base de datos}
P="psql -v ON_ERROR_STOP=1 -q -X -tA -d $DB"
R=f1000000-0000-4000-8000-000000000001      # restaurante de esta prueba
PROD=f1000000-0000-4000-8000-000000000201
SALA=a0000000-0000-4000-8000-0000000000f6
fallo() { echo "FALLO: $1" >&2; exit 1; }
TMPDIR_C=${TMPDIR_C:-$(mktemp -d)}
tok() { printf '%064x' "$1"; }
pedido() {  # pedido(token, mesa, método) → payload JSON
  echo "{\"restaurantId\":\"$R\",\"mode\":\"mesa\",\"table\":$2,\"paymentMethod\":\"$3\",\"accessToken\":\"$(tok "$1")\",\"items\":[{\"productId\":\"$PROD\",\"quantity\":1}]}"
}
# Como cliente anónimo, empezando todos a la vez (barrera en $1). Escribe «id|motivo» o ERROR.
como_cliente() {
  $P -c "select set_config('request.jwt.claims', '{\"role\":\"anon\"}', false)" -c "set role anon" \
     -c "select pg_sleep(greatest(0, extract(epoch from ('$1'::timestamptz - clock_timestamp()))))" \
     -c "select coalesce(j ->> 'id', '') || '|' || coalesce(j ->> 'reason', '') from ($2) x(j)" 2>&1 | tail -1
}
como_sala() {
  $P -c "select set_config('request.jwt.claims', '{\"role\":\"authenticated\",\"sub\":\"$SALA\"}', false)" -c "set role authenticated" \
     -c "select pg_sleep(greatest(0, extract(epoch from ('$1'::timestamptz - clock_timestamp()))))" -c "$2" 2>&1 | tail -1
}
barrera() { $P -c "select (clock_timestamp() + interval '1.5 seconds')::text"; }
abiertos() { $P -c "select count(*) from public.orders where restaurant_id = '$R' and payment_status = 'pendiente_caja' and prep_status in ('nuevo','en_preparacion','listo') ${1:-}"; }

# Restaurante propio con límites bajos: 3 por mesa, 2 para recoger, 5 en el restaurante, 2 online.
$P -c "insert into public.restaurants (id, slug, name, active, tables, pickup_enabled, online_payment_enabled, counter_payment_enabled)
       values ('$R', 'limites-paralelo', 'Límites en paralelo', true, 20, true, true, true)" \
   -c "insert into public.categories (id, restaurant_id, name) values ('f1000000-0000-4000-8000-000000000101', '$R', 'Carta')" \
   -c "insert into public.products (id, restaurant_id, category_id, name, price_cents) values ('$PROD', '$R', 'f1000000-0000-4000-8000-000000000101', 'Menú', 500)" \
   -c "insert into private.order_limits (restaurant_id, per_table, pickup, per_restaurant, online_pending, window_minutes) values ('$R', 3, 2, 5, 2, 30)" \
   -c "insert into auth.users (id, email) values ('$SALA', 'sala@paralelo.test')" \
   -c "insert into public.restaurant_staff (restaurant_id, user_id, role) values ('$R', '$SALA', 'waiter')" > /dev/null

# 1) 20 pedidos a la vez en la MISMA mesa (límite 3) → entran exactamente 3.
T=$(barrera)
for i in $(seq 20); do como_cliente "$T" "select public.create_order('$(pedido $((1000 + i)) 1 caja)')" > "$TMPDIR_C/a$i" & done; wait
grep -L '^[0-9a-f-]*|' "$TMPDIR_C"/a* | grep -q . && fallo "alguna petición terminó con error: $(cat "$TMPDIR_C"/a* | grep -v '|' | head -1)"
OK=$(cat "$TMPDIR_C"/a* | grep -c '^[0-9a-f-]\{36\}|$' || true)
REJ=$(cat "$TMPDIR_C"/a* | grep -c '^|mesa$' || true)
[ "$OK" = 3 ] && [ "$REJ" = 17 ] || fallo "20 pedidos simultáneos en una mesa con límite 3: $OK creados y $REJ rechazados (debían ser 3 y 17)"
[ "$(abiertos "and table_number = 1")" = 3 ] || fallo "la mesa tiene $(abiertos "and table_number = 1") pedidos (debían ser 3)"
echo "OK  20 pedidos simultáneos en la misma mesa (límite 3): entran exactamente 3"
[ "$($P -c "select sum(attempts) from private.order_limit_hits where restaurant_id = '$R' and limit_kind = 'mesa'")" = 17 ] \
  || fallo "el registro no cuenta los 17 intentos frenados"
echo "OK  los 17 intentos frenados quedan anotados (agrupados)"

# 2) 20 envíos simultáneos con el MISMO código → un solo pedido, y todos reciben ese pedido.
T=$(barrera); rm -f "$TMPDIR_C"/a*
for i in $(seq 20); do como_cliente "$T" "select public.create_order('$(pedido 2000 2 caja)')" > "$TMPDIR_C/a$i" & done; wait
[ "$(cat "$TMPDIR_C"/a* | sort -u | wc -l)" = 1 ] && grep -q '^[0-9a-f-]\{36\}|$' "$TMPDIR_C/a1" \
  || fallo "20 envíos con el mismo código: respuestas distintas ($(sort -u "$TMPDIR_C"/a* | head -3 | tr '\n' ' '))"
[ "$(abiertos "and table_number = 2")" = 1 ] || fallo "el mismo código ha creado $(abiertos "and table_number = 2") pedidos"
echo "OK  20 envíos simultáneos con el mismo código: un solo pedido, sin duplicados"

# 3) Pedidos nuevos, cambios a caja y cambios de preparación A LA VEZ, con 1 solo hueco en el
#    restaurante (4 de 5): entra exactamente 1, los cambios a caja frenados no cambian y no hay deadlocks.
ON1=$(como_cliente "$($P -c "select clock_timestamp()::text")" "select public.create_order('$(pedido 3001 10 online)')" | cut -d'|' -f1)
ON2=$(como_cliente "$($P -c "select clock_timestamp()::text")" "select public.create_order('$(pedido 3002 11 online)')" | cut -d'|' -f1)
[ -n "$ON1" ] && [ -n "$ON2" ] || fallo "no se pudieron crear los pedidos online"
PREP=$($P -c "select id from public.orders where restaurant_id = '$R' and table_number = 1 order by number limit 1")
T=$(barrera); rm -f "$TMPDIR_C"/a* "$TMPDIR_C"/s*
for i in $(seq 10); do como_cliente "$T" "select public.create_order('$(pedido $((3100 + i)) $((12 + i % 4)) caja)')" > "$TMPDIR_C/a$i" & done
como_cliente "$T" "select public.customer_switch_to_counter('$ON1', '$(tok 3001)')" > "$TMPDIR_C/a_sw1" &
como_cliente "$T" "select public.customer_switch_to_counter('$ON2', '$(tok 3002)')" > "$TMPDIR_C/a_sw2" &
for i in 1 2 3; do como_sala "$T" "select public.staff_set_prep_status('$PREP', case when (select prep_status from public.orders where id = '$PREP') = 'nuevo' then 'en_preparacion'::public.prep_status else 'nuevo' end)" > "$TMPDIR_C/s$i" & done
wait
cat "$TMPDIR_C"/a* "$TMPDIR_C"/s* | grep -qi deadlock && fallo "se ha producido un bloqueo mutuo (deadlock)"
grep -l -i 'error' "$TMPDIR_C"/a* | grep -q . && fallo "alguna petición de cliente terminó con error: $(grep -h -i error "$TMPDIR_C"/a* | head -1)"
OK=$(cat "$TMPDIR_C"/a* | grep -c '^[0-9a-f-]\{36\}|$' || true)
[ "$OK" = 1 ] || fallo "con 1 hueco y 12 peticiones simultáneas entraron $OK (debía ser 1)"
[ "$(abiertos)" = 5 ] || fallo "el restaurante tiene $(abiertos) pedidos de caja sin pagar (límite 5)"
echo "OK  12 peticiones simultáneas (pedidos y cambios a caja) con 1 hueco: entra exactamente 1"
N=$($P -c "select count(*) from public.orders where id in ('$ON1', '$ON2') and payment_method = 'online' and payment_status = 'pendiente_online'")
SW=$(cat "$TMPDIR_C"/a_sw1 "$TMPDIR_C"/a_sw2 | grep -c '^[0-9a-f-]\{36\}|$' || true)
[ "$((N + SW))" = 2 ] || fallo "los cambios a caja frenados han modificado el pedido"
echo "OK  los cambios a caja frenados dejan el pedido online sin tocar"
echo "OK  pedidos, cambios a caja y cambios de preparación a la vez: sin bloqueos mutuos"
echo "Límites con peticiones simultáneas: todas las comprobaciones superadas"
