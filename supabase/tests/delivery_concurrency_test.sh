#!/usr/bin/env bash
# Entregas de invitaciones con procesos SIMULTÁNEOS (sesiones de PostgreSQL en paralelo).
# Lo ejecuta supabase/tests/run.sh en una base de datos LOCAL propia (esquema + La Piazza, sin más datos).
# Comprueba que ninguna entrega se reserva dos veces aunque muchos procesos lo intenten a la vez.
set -euo pipefail
DB=${1:?base de datos}
P="psql -v ON_ERROR_STOP=1 -q -X -tA -d $DB"
PIAZZA=5e5e0000-0000-4000-8000-000000000001
OWNER=a0000000-0000-4000-8000-0000000000a1
fallo() { echo "FALLO: $1" >&2; exit 1; }
TMPDIR_C=${TMPDIR_C:-$(mktemp -d)}

# Como servidor (rol service_role), empezando todos a la vez (barrera en $1).
como_servidor() {
  $P -c "select set_config('request.jwt.claims', '{\"role\":\"service_role\"}', false)" -c "set role service_role" \
     -c "select pg_sleep(greatest(0, extract(epoch from ('$1'::timestamptz - clock_timestamp()))))" -c "$2" | tail -1
}
nueva() {  # invitación pendiente creada hace $2 (como postgres)
  $P -c "insert into private.invitations (restaurant_id, email, role, invited_by, invited_by_kind, created_at, expires_at)
         select '$PIAZZA', '$1', 'waiter', '$OWNER', 'personal', t, t + interval '168 hours'
         from (select now() - interval '$2' as t) x returning id" | head -1
}
barrera() { $P -c "select (clock_timestamp() + interval '1.5 seconds')::text"; }
# Base limpia: el propietario de La Piazza (quien invita en estas pruebas).
$P -c "insert into auth.users (id, email) values ('$OWNER', 'owner@piazza.test')" \
   -c "insert into public.restaurant_staff (restaurant_id, user_id, role) values ('$PIAZZA', '$OWNER', 'owner')" > /dev/null

# 1) 20 procesos reservan la MISMA entrega a la vez → exactamente 1 la obtiene.
ID=$(nueva paralelo1@x.test '1 second'); T=$(barrera)
for i in $(seq 20); do como_servidor "$T" "select count(*) from public.invitation_delivery_claim('$ID')" > "$TMPDIR_C/c$i" & done; wait
TOTAL=$(cat "$TMPDIR_C"/c* | awk "{s+=\$1} END {print s+0}")
[ "$TOTAL" = 1 ] || fallo "20 reservas simultáneas de la misma entrega: $TOTAL obtuvieron la reserva (debía ser 1)"
echo "OK  20 reservas simultáneas de la misma entrega: solo 1 la obtiene"
[ "$($P -c "select send_attempts from private.invitations where id = '$ID'")" = 1 ] || fallo "los intentos fallidos de reserva cuentan como intentos"
echo "OK  las reservas que no se obtienen no gastan intentos"

# 2) 20 procesos anotan el resultado con la MISMA reserva a la vez → solo 1 lo anota.
CLAIM=$($P -c "select send_claim from private.invitations where id = '$ID'"); T=$(barrera); rm -f "$TMPDIR_C"/c*
for i in $(seq 20); do como_servidor "$T" "select public.invitation_delivery_finish('$ID', '$CLAIM', 'enviada')::int" > "$TMPDIR_C/c$i" & done; wait
TOTAL=$(cat "$TMPDIR_C"/c* | awk "{s+=\$1} END {print s+0}")
[ "$TOTAL" = 1 ] || fallo "20 anotaciones simultáneas con la misma reserva: $TOTAL (debía ser 1)"
echo "OK  20 anotaciones simultáneas del resultado: solo 1 cuenta"
N=$($P -c "select count(*) from private.audit_log where action = 'invitacion.entrega' and target_id = '$ID'")
[ "$N" = 1 ] || fallo "la entrega quedó registrada $N veces en la auditoría"
echo "OK  la entrega queda registrada una sola vez"

# 3) 10 procesos de recuperación a la vez sobre 6 entregas atrasadas → cada una se reserva 1 vez.
IDS=""; for i in $(seq 6); do IDS="$IDS,'$(nueva "recuperar$i@x.test" '3 minutes')'"; done; IDS=${IDS#,}
T=$(barrera); rm -f "$TMPDIR_C"/c*
for i in $(seq 10); do
  como_servidor "$T" "select count(*) from public.invitation_delivery_pending(10) p, lateral public.invitation_delivery_claim(p) c where p in ($IDS)" > "$TMPDIR_C/c$i" &
done; wait
TOTAL=$(cat "$TMPDIR_C"/c* | awk "{s+=\$1} END {print s+0}")
[ "$TOTAL" = 6 ] || fallo "10 recuperaciones simultáneas de 6 entregas: $TOTAL reservas (debían ser 6)"
[ "$($P -c "select count(*) from private.invitations where id in ($IDS) and send_status = 'enviando' and send_attempts = 1")" = 6 ] \
  || fallo "alguna entrega se reservó más de una vez"
echo "OK  10 recuperaciones simultáneas: cada entrega atrasada se reserva una sola vez"

# 4) Una reserva en curso (transacción abierta) bloquea a la segunda, que después no obtiene nada.
ID=$(nueva paralelo2@x.test '1 second')
( $P -c "select set_config('request.jwt.claims', '{\"role\":\"service_role\"}', false)" -c "set role service_role" \
     -c "begin" -c "select count(*) from public.invitation_delivery_claim('$ID')" -c "select pg_sleep(1.5)" -c "commit" | grep -E '^[0-9]+$' | head -1 > "$TMPDIR_C/a" ) &
sleep 0.5
B=$(como_servidor "$(date -u +%FT%T.%NZ)" "select count(*) from public.invitation_delivery_claim('$ID')"); wait
[ "$(cat "$TMPDIR_C/a")" = 1 ] && [ "$B" = 0 ] || fallo "reserva con transacción abierta: primera=$(cat "$TMPDIR_C/a") segunda=$B (debían ser 1 y 0)"
echo "OK  una segunda reserva espera a la primera y después no obtiene nada"
echo "Entregas simultáneas: todas las comprobaciones superadas"
