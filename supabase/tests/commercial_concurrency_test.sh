#!/usr/bin/env bash
# Protección comercial de los pedidos con peticiones SIMULTÁNEAS (sesiones de PostgreSQL en paralelo).
# Lo ejecuta supabase/tests/run.sh en una base de datos LOCAL propia (esquema + La Piazza, sin más datos).
# Comprueba que:
#  1. si el estado comercial cambia mientras llegan pedidos, los pedidos esperan y deciden con el estado
#     ya confirmado (si pasa a «vencida», no entra ninguno; si el cambio se deshace, entran todos);
#  2. una prueba que termina MIENTRAS el pedido espera un bloqueo ya no lo autoriza (hora real, no la
#     del inicio de la transacción);
#  3. los reintentos simultáneos de un pedido ya creado devuelven ese pedido, también tras el vencimiento;
#  4. los límites contra pedidos masivos siguen igual;
#  5. pedidos, cambios de estado comercial, cambios de cocina y pasos a caja a la vez no producen
#     bloqueos mutuos (deadlocks) ni pedidos de más.
set -euo pipefail
DB=${1:?base de datos}
P="psql -v ON_ERROR_STOP=1 -v VERBOSITY=terse -q -X -tA -d $DB"
R=f3000000-0000-4000-8000-000000000001     # «activa», límites altos
R2=f3000000-0000-4000-8000-000000000002    # «prueba» que termina durante la prueba, límites altos
R3=f3000000-0000-4000-8000-000000000003    # «activa», límites bajos (3 por mesa)
ADMIN=a0000000-0000-4000-8000-0000000000f7
SALA=a0000000-0000-4000-8000-0000000000f8
prod() { echo "f3000000-0000-4000-8000-00000000020${1: -1}"; }   # producto del restaurante (…201, …202, …203)
fallo() { echo "FALLO: $1" >&2; exit 1; }
TMPDIR_C=${TMPDIR_C:-$(mktemp -d)}
tok() { printf '%064x' "$1"; }
pedido() {  # pedido(restaurante, token, mesa, [método]) → payload JSON
  echo "{\"restaurantId\":\"$1\",\"mode\":\"mesa\",\"table\":$3,\"paymentMethod\":\"${4:-caja}\",\"accessToken\":\"$(tok "$2")\",\"items\":[{\"productId\":\"$(prod "$1")\",\"quantity\":1}]}"
}
espera() { echo "select pg_sleep(greatest(0, extract(epoch from (($1)::timestamptz - clock_timestamp()))))"; }
# Como cliente anónimo, empezando todos a la vez (barrera en $1). Escribe «id|», «|motivo» (límite) o el error.
como_cliente() {
  $P -c "select set_config('request.jwt.claims', '{\"role\":\"anon\"}', false)" -c "set role anon" -c "$(espera "'$1'")" \
     -c "select coalesce(j ->> 'id', '') || '|' || coalesce(j ->> 'reason', '') from ($2) x(j)" 2>&1 | tail -1
}
pedir() {  # sin esperar
  $P -c "select set_config('request.jwt.claims', '{\"role\":\"anon\"}', false)" -c "set role anon" \
     -c "select coalesce(j ->> 'id', '') || '|' || coalesce(j ->> 'reason', '') from (select public.create_order('$1')) x(j)" 2>&1 | tail -1
}
como_plataforma() { $P -c "select set_config('request.jwt.claims', '{\"role\":\"authenticated\",\"sub\":\"$ADMIN\"}', false)" -c "set role authenticated" "$@"; }
como_sala() { $P -c "select set_config('request.jwt.claims', '{\"role\":\"authenticated\",\"sub\":\"$SALA\"}', false)" -c "set role authenticated" "$@"; }
barrera() { $P -c "select (clock_timestamp() + interval '${1:-1.5} seconds')::text"; }
cuenta() { cat "$TMPDIR_C"/$1 2>/dev/null | grep -c "$2" || true; }
pedidos() { $P -c "select count(*) from public.orders where restaurant_id = '$1'"; }
estado() { $P -c "update private.tenant_accounts set status = '$2' where restaurant_id = '$1'" > /dev/null; }

# ---------- Preparación ----------
$P -c "insert into auth.users (id, email) values ('$ADMIN', 'plataforma@comercial-paralelo.test'), ('$SALA', 'sala@comercial-paralelo.test')" \
   -c "insert into public.platform_admins (user_id) values ('$ADMIN')" > /dev/null
for n in 1 2 3; do
  RID=f3000000-0000-4000-8000-00000000000$n
  $P -c "insert into public.restaurants (id, slug, name, active, tables, pickup_enabled, online_payment_enabled, counter_payment_enabled)
         values ('$RID', 'comercial-paralelo-$n', 'Comercial en paralelo $n', true, 50, true, true, true)" \
     -c "insert into public.categories (id, restaurant_id, name) values ('f3000000-0000-4000-8000-00000000010$n', '$RID', 'Carta')" \
     -c "insert into public.products (id, restaurant_id, category_id, name, price_cents) values ('$(prod $RID)', '$RID', 'f3000000-0000-4000-8000-00000000010$n', 'Menú', 500)" > /dev/null
done
$P -c "insert into private.order_limits (restaurant_id, per_table, pickup, per_restaurant, online_pending, window_minutes) values
         ('$R', 500, 500, 1000, 1000, 30), ('$R2', 500, 500, 1000, 1000, 30), ('$R3', 3, 2, 40, 30, 30)" \
   -c "insert into public.restaurant_staff (restaurant_id, user_id, role) values ('$R', '$SALA', 'waiter')" > /dev/null
# Todo restaurante nuevo empieza en «borrador»: a R y R3 se les asigna expresamente «activa».
estado "$R" activa; estado "$R3" activa

# ---------- 1. El estado pasa a «vencida» mientras 20 pedidos esperan → no entra ninguno ----------
T=$(barrera 1.5)
( $P -c "begin" -c "update private.tenant_accounts set status = 'vencida' where restaurant_id = '$R'" -c "select pg_sleep(3)" -c "commit" > /dev/null ) &
sleep 0.3
for i in $(seq 20); do como_cliente "$T" "select public.create_order('$(pedido $R $((1000 + i)) $i)')" > "$TMPDIR_C/a$i" & done
wait
[ "$(cuenta 'a*' '^[0-9a-f-]\{36\}|$')" = 0 ] && [ "$(cuenta 'a*' 'no acepta pedidos')" = 20 ] \
  || fallo "20 pedidos mientras el estado pasa a «vencida»: $(cuenta 'a*' '^[0-9a-f-]\{36\}|$') aceptados (debían ser 0): $(sort -u "$TMPDIR_C"/a* | head -2 | tr '\n' ' ')"
[ "$(pedidos $R)" = 0 ] || fallo "se han guardado pedidos de un restaurante que pasó a «vencida»"
echo "OK  20 pedidos esperando mientras el estado pasa a «vencida»: no entra ninguno"

# ---------- 2. La plataforma empieza a cambiarlo y lo deshace → entran todos ----------
estado "$R" activa; rm -f "$TMPDIR_C"/a*
T=$(barrera 1.5)
( como_plataforma -c "begin" -c "select public.platform_set_commercial_status('$R', 'vencida', 'Prueba de concurrencia')" \
    -c "select pg_sleep(3)" -c "rollback" > /dev/null ) &
sleep 0.3
for i in $(seq 20); do como_cliente "$T" "select public.create_order('$(pedido $R $((2000 + i)) $i)')" > "$TMPDIR_C/a$i" & done
wait
OK=$(cuenta 'a*' '^[0-9a-f-]\{36\}|$')
[ "$OK" = 20 ] && [ "$(cat "$TMPDIR_C"/a* | sort -u | wc -l)" = 20 ] \
  || fallo "20 pedidos mientras un cambio de estado se deshace: $OK aceptados (debían ser 20): $(sort -u "$TMPDIR_C"/a* | grep -v '|$' | head -2 | tr '\n' ' ')"
[ "$(pedidos $R)" = 20 ] || fallo "deberían existir 20 pedidos (hay $(pedidos $R))"
echo "OK  20 pedidos esperando mientras la plataforma cambia el estado y lo deshace: entran los 20, sin duplicados"

# ---------- 3. Una prueba que termina MIENTRAS el pedido espera ya no lo autoriza ----------
E=$($P -c "select (clock_timestamp() + interval '3 seconds')::text")
# Solo en esta base desechable: se desactiva un momento el vigilante de la cuenta para que la prueba termine en E.
$P -c "alter table private.tenant_accounts disable trigger tenant_accounts_guard" \
   -c "update private.tenant_accounts set status = 'prueba', plan_code = 'profesional', trial_ends_at = '$E',
         trial_started_at = '$E'::timestamptz - interval '14 days' where restaurant_id = '$R2'" \
   -c "alter table private.tenant_accounts enable trigger tenant_accounts_guard" > /dev/null
CONTROL=$(pedir "$(pedido $R2 3000 1)" || true)
[[ "$CONTROL" =~ ^[0-9a-f-]{36}\|$ ]] || fallo "antes del fin de la prueba debería aceptarse un pedido ($CONTROL)"
( $P -c "begin" -c "select 1 from private.tenant_accounts where restaurant_id = '$R2' for update" \
     -c "$(espera "'$E'::timestamptz + interval '1.5 seconds'")" -c "commit" > /dev/null ) &
TB=$($P -c "select ('$E'::timestamptz - interval '1 second')::text"); rm -f "$TMPDIR_C"/a*
sleep 0.3
for i in $(seq 10); do como_cliente "$TB" "select public.create_order('$(pedido $R2 $((3000 + i)) $((1 + i)))')" > "$TMPDIR_C/a$i" & done
wait
[ "$(cuenta 'a*' '^[0-9a-f-]\{36\}|$')" = 0 ] && [ "$(cuenta 'a*' 'no acepta pedidos')" = 10 ] \
  || fallo "pedidos que empiezan antes del fin de la prueba y esperan hasta después: $(cuenta 'a*' '^[0-9a-f-]\{36\}|$') aceptados (debían ser 0)"
[ "$(pedidos $R2)" = 1 ] || fallo "solo debería existir el pedido de control (hay $(pedidos $R2))"
echo "OK  10 pedidos que empiezan antes del fin de la prueba pero esperan un bloqueo hasta después: ninguno entra"

# ---------- 4. Reintentos simultáneos de un pedido ya creado, con el restaurante ya «vencido» ----------
estado "$R" vencida; rm -f "$TMPDIR_C"/a*
T=$(barrera 1.5)
for i in $(seq 20); do como_cliente "$T" "select public.create_order('$(pedido $R 2001 1)')" > "$TMPDIR_C/a$i" & done
wait
[ "$(cat "$TMPDIR_C"/a* | sort -u | wc -l)" = 1 ] && grep -q '^[0-9a-f-]\{36\}|$' "$TMPDIR_C/a1" \
  || fallo "20 reintentos del mismo pedido tras el vencimiento: respuestas distintas ($(sort -u "$TMPDIR_C"/a* | head -3 | tr '\n' ' '))"
[ "$(pedidos $R)" = 20 ] || fallo "los reintentos han creado pedidos (hay $(pedidos $R))"
echo "OK  20 reintentos simultáneos de un pedido ya creado (restaurante vencido): devuelven ese pedido, sin duplicados"

# ---------- 5. Los límites contra pedidos masivos siguen igual ----------
rm -f "$TMPDIR_C"/a*
T=$(barrera 1.5)
for i in $(seq 20); do como_cliente "$T" "select public.create_order('$(pedido $R3 $((5000 + i)) 7)')" > "$TMPDIR_C/a$i" & done
wait
[ "$(cuenta 'a*' '^[0-9a-f-]\{36\}|$')" = 3 ] && [ "$(cuenta 'a*' '^|mesa$')" = 17 ] \
  || fallo "20 pedidos a la vez en una mesa con límite 3: $(cuenta 'a*' '^[0-9a-f-]\{36\}|$') creados y $(cuenta 'a*' '^|mesa$') frenados (debían ser 3 y 17)"
echo "OK  con la protección comercial, los límites siguen igual: 20 pedidos a la vez en una mesa con límite 3 → entran 3"

# ---------- 6. Todo a la vez durante unos segundos: sin bloqueos mutuos ni pedidos de más ----------
estado "$R" activa; rm -f "$TMPDIR_C"/a* "$TMPDIR_C"/b*
# 15 pedidos online pendientes, para pasarlos a caja durante la prueba
for i in $(seq 15); do pedir "$(pedido $R $((6000 + i)) $((20 + i)) online)" >> "$TMPDIR_C/online"; done
[ "$(grep -c '^[0-9a-f-]\{36\}|$' "$TMPDIR_C/online")" = 15 ] || fallo "no se pudieron preparar los pedidos online"
BASE=$(pedidos $R)
FIN=$(barrera 6)
sigue() { [ "$($P -c "select clock_timestamp() < '$FIN'::timestamptz")" = t ]; }
clientes() { local k=$1 i=0; while sigue; do i=$((i + 1)); pedir "$(pedido $R $((100000 + k * 1000 + i)) $((1 + (k * 7 + i) % 50)))" >> "$TMPDIR_C/a$k" || true; done; }
plataforma() { while sigue; do como_plataforma -c "select public.platform_set_commercial_status('$R',
  case when public.restaurant_commercial_status('$R') ->> 'status' = 'activa' then 'vencida' else 'activa' end, 'Prueba de bloqueos')" >> "$TMPDIR_C/b_plat$1" 2>&1 || true; done; }
editor() { while sigue; do $P -c "update private.tenant_accounts set status = case status when 'activa' then 'vencida' else 'activa' end
  where restaurant_id = '$R'" >> "$TMPDIR_C/b_editor" 2>&1 || true; done; }
sala() { while sigue; do como_sala -c "select public.staff_set_prep_status(o.id, case o.prep_status when 'nuevo' then 'en_preparacion'::public.prep_status else 'nuevo' end)
  from public.orders o where o.restaurant_id = '$R' and o.payment_method = 'caja' and o.prep_status in ('nuevo', 'en_preparacion')
  order by random() limit 1" >> "$TMPDIR_C/b_sala$1" 2>&1 || true; done; }
caja() { for i in $(seq 15); do sigue || break
  ID=$(sed -n "${i}p" "$TMPDIR_C/online" | cut -d'|' -f1)   # el pedido online i, tal como lo devolvió create_order
  $P -c "select set_config('request.jwt.claims', '{\"role\":\"anon\"}', false)" -c "set role anon" \
     -c "select public.customer_switch_to_counter('$ID', '$(tok $((6000 + i)))') ->> 'paymentStatus'" >> "$TMPDIR_C/b_caja" 2>&1 || true
  sleep 0.2; done; }
for k in 1 2 3 4 5 6; do clientes $k & done
plataforma 1 & plataforma 2 & editor & sala 1 & sala 2 & caja &
wait
cat "$TMPDIR_C"/a* "$TMPDIR_C"/b* | grep -iE 'deadlock|could not|canceling statement|server closed|terminating' | head -1 | grep . \
  && fallo "con todo a la vez ha aparecido un error de bloqueo o de conexión"
RARO=$(cat "$TMPDIR_C"/a* | grep -vE '^[0-9a-f-]{36}\|$|no acepta pedidos|^\|[a-z]+$' | head -1 || true)
[ -z "$RARO" ] || fallo "respuesta inesperada a un pedido: $RARO"
ACEPT=$(cuenta 'a*' '^[0-9a-f-]\{36\}|$'); RECH=$(cuenta 'a*' 'no acepta pedidos')
[ "$ACEPT" -gt 0 ] || fallo "con todo a la vez no ha entrado ningún pedido: la prueba no ha comprobado nada"
[ "$(pedidos $R)" = "$((BASE + ACEPT))" ] || fallo "pedidos guardados ($(pedidos $R)) ≠ pedidos aceptados ($((BASE + ACEPT)))"
echo "OK  6 s con pedidos, cambios de estado (plataforma y SQL Editor), cocina y pasos a caja a la vez: sin bloqueos mutuos ($ACEPT pedidos aceptados, $RECH rechazados, ninguno de más)"
rm -rf "$TMPDIR_C"
echo "Protección comercial con peticiones simultáneas: todas las comprobaciones superadas"
