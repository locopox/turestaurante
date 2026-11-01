#!/usr/bin/env bash
# Recuperación PROGRAMADA de invitaciones (migración 20261105120000) en un PostgreSQL LOCAL y desechable.
# Nunca contra Supabase.
#
# Necesita pg_cron REAL en el servidor local:
#   shared_preload_libraries = 'pg_cron'
#   cron.database_name = 'turestaurante_cron'
#   cron.use_background_workers = on        (para que pg_cron no se conecte por red con contraseña)
# Si falta, la prueba se OMITE y lo dice.
#
# pg_net y Supabase Vault: si el servidor no los tiene, se carga tests/pg_net_vault_stub.sql, que NO
# es equivalente (no hace peticiones HTTP ni cifra): solo permite comprobar NUESTRO SQL. La salida
# indica cuál se usó.
#
# Opcional (RECOVERY_E2E=1, con node y DENO=<ruta a deno>): lanza la Edge Function real
# «invitations-recovery» con Deno y le reenvía la petición que preparó la tarea, contra un servidor
# que imita la API de Supabase y ejecuta las funciones SQL en ESTA base de datos.
set -euo pipefail
export PGOPTIONS="-c client_min_messages=warning"
cd "$(dirname "$0")/.."
case "${PGHOST:-localhost}" in *supabase.co*|*supabase.com*) echo "Solo para una base de datos local." >&2; exit 1;; esac
DB=turestaurante_cron
UP=migrations/20261105120000_fase6_recuperacion_programada.sql
DOWN=migrations_down/20261105120000_fase6_recuperacion_programada.down.sql
JOB=turestaurante-recuperar-invitaciones
PIAZZA=5e5e0000-0000-4000-8000-000000000001
OWNER=a0000000-0000-4000-8000-0000000000a1
ADMIN=a0000000-0000-4000-8000-0000000000ad
SECRET=$(printf 'secreto-de-prueba-%s' "$(date +%s%N)" | sha256sum | cut -c1-48)

pre=$(psql -X -tA -d postgres -c "select current_setting('shared_preload_libraries', true) || '|' || coalesce(current_setting('cron.database_name', true), '')")
if [[ "$pre" != *pg_cron* || "${pre#*|}" != "$DB" ]]; then
  echo "PRUEBA OMITIDA: pg_cron no está cargado en este PostgreSQL con cron.database_name = '$DB' (ver cabecera de $0)."
  exit 0
fi

Q() { psql -v ON_ERROR_STOP=1 -q -X -tA -d $DB "$@"; }
AS() {  # AS <rol> <sub|-> <sql>: ejecuta como ese rol de la API (devuelve la última línea)
  local claims; if [ "$2" = - ]; then claims="{\"role\":\"$1\"}"; else claims="{\"role\":\"$1\",\"sub\":\"$2\"}"; fi
  Q -c "select set_config('request.jwt.claims', '$claims', false)" -c "set role $1" -c "$3" | tail -1
}
ok() { echo "OK  $1"; }
fallo() { echo "FALLO: $1" >&2; exit 1; }
igual() { [ "$1" = "$2" ] || fallo "$3 (obtenido «$1», esperado «$2»)"; ok "$3"; }
deniega() {  # deniega <rol> <sub> <sql> <patrón> <nombre>
  local out; if out=$(AS "$1" "$2" "$3" 2>&1); then fallo "$5 (no dio error)"; fi
  echo "$out" | grep -qiE "$4" || fallo "$5 (error inesperado: $out)"; ok "$5"
}
ultimo() { Q -c "select outcome from private.invitations_recovery_runs order by id desc limit 1"; }
peticiones() { Q -c "select count(*) from net.stub_requests"; }
pendiente() {  # invitación pendiente creada hace $2, sin enviar
  Q -c "insert into private.invitations (restaurant_id, email, role, invited_by, invited_by_kind, created_at, expires_at)
        select '$PIAZZA', '$1', 'waiter', '$OWNER', 'personal', t, t + interval '168 hours' from (select now() - interval '$2' as t) x
        returning id" | head -1
}

psql -q -X -d postgres -c "drop database if exists $DB with (force)" -c "create database $DB"
Q -f tests/supabase_shim.sql -f schema.sql -f seed.sql > /dev/null
Q -c "insert into auth.users (id, email) values ('$OWNER', 'owner@piazza.test'), ('$ADMIN', 'admin@plataforma.test')" \
  -c "insert into public.restaurant_staff values ('$PIAZZA', '$OWNER', 'owner')" -c "insert into public.platform_admins values ('$ADMIN')" > /dev/null
if [ "$(Q -c "select count(*) from pg_available_extensions where name in ('pg_net', 'supabase_vault')")" = 2 ]; then
  echo "pg_net y Vault: extensiones REALES"; STUB=0
else
  Q -f tests/pg_net_vault_stub.sql > /dev/null
  echo "pg_net y Vault: NO disponibles en este servidor → SUSTITUTO de prueba (sin HTTP ni cifrado; no equivalente)"; STUB=1
fi

# ---------- Migración: la tarea y su frecuencia ----------
Q -f "$UP" > /dev/null
igual "$(Q -c "select count(*) from cron.job where jobname = '$JOB'")" 1 "migración: crea UNA tarea programada"
igual "$(Q -c "select schedule || ' | ' || command || ' | ' || active from cron.job where jobname = '$JOB'")" \
  "*/5 * * * * | select private.invitations_recovery_tick() | true" "la tarea se ejecuta cada 5 minutos y llama a la recuperación"
J1=$(Q -c "select jobid from cron.job where jobname = '$JOB'")
Q -f "$UP" > /dev/null; Q -f "$UP" > /dev/null
igual "$(Q -c "select count(*) || ':' || min(jobid) from cron.job where jobname = '$JOB'")" "1:$J1" "repetir la migración no duplica la tarea (la misma tarea)"
# Una copia antigua con el mismo nombre (versiones anteriores de pg_cron lo permitían): la migración deja una.
Q -c "insert into cron.job (schedule, command, nodename, nodeport, database, username, jobname)
      values ('*/5 * * * *', 'select 1', 'localhost', 5432, '$DB', current_user, '$JOB')" > /dev/null 2>&1 && {
  Q -f "$UP" > /dev/null
  igual "$(Q -c "select count(*) from cron.job where jobname = '$JOB'")" 1 "si hubiera tareas duplicadas, la migración deja solo una"
} || echo "--  (no se pudo insertar una copia directa en cron.job: comprobación de duplicados antiguos omitida)"

# ---------- Sin entregas pendientes: no llama a nada ----------
igual "$(Q -c "select coalesce(private.invitations_recovery_tick()::text, 'nada')")" nada "sin entregas pendientes no se llama a la función"
igual "$(ultimo):$(peticiones)" "sin_pendientes:0" "queda anotado «sin_pendientes» (se puede comprobar que la tarea corre)"
FRESCA=$(pendiente fresca@x.test '30 seconds')
Q -c "select private.invitations_recovery_tick()" > /dev/null
igual "$(ultimo):$(peticiones)" "sin_pendientes:0" "una invitación recién creada (menos de 2 min) la envía su propio proceso"

# ---------- Configuración en Vault ----------
P1=$(pendiente atrasada@x.test '3 minutes')
Q -c "select private.invitations_recovery_tick()" > /dev/null
igual "$(ultimo):$(peticiones)" "sin_configurar:0" "sin secretos en Vault: no llama y anota «sin_configurar»"
Q -c "select vault.create_secret('$SECRET', 'turestaurante_recovery_secret', 'Recuperación de invitaciones')" > /dev/null
for URL in "http://malo.example.com/functions/v1/invitations-recovery" "https://x.supabase.co/functions/v1/invitations" \
           "https://x.supabase.co/functions/v1/invitations-recovery?x=1" "ftp://x.supabase.co/functions/v1/invitations-recovery"; do
  Q -c "delete from vault.secrets where name = 'turestaurante_recovery_url'" -c "select vault.create_secret('$URL', 'turestaurante_recovery_url')" > /dev/null
  Q -c "select private.invitations_recovery_tick()" > /dev/null
  igual "$(ultimo):$(peticiones)" "sin_configurar:0" "no envía el secreto a una URL no válida: $URL"
done
Q -c "delete from vault.secrets where name = 'turestaurante_recovery_url'" \
  -c "select vault.create_secret('http://127.0.0.1:54398/functions/v1/invitations-recovery', 'turestaurante_recovery_url')" \
  -c "update vault.secrets set secret = 'corto' where name = 'turestaurante_recovery_secret'" > /dev/null 2>&1 || \
  Q -c "select vault.update_secret((select id from vault.secrets where name = 'turestaurante_recovery_secret'), 'corto')" > /dev/null
Q -c "select private.invitations_recovery_tick()" > /dev/null
igual "$(ultimo):$(peticiones)" "sin_configurar:0" "secreto de menos de 32 caracteres: no llama"
Q -c "update vault.secrets set secret = '$SECRET' where name = 'turestaurante_recovery_secret'" > /dev/null 2>&1 || \
  Q -c "select vault.update_secret((select id from vault.secrets where name = 'turestaurante_recovery_secret'), '$SECRET')" > /dev/null

# ---------- Llamada a la función ----------
REQ=$(Q -c "select private.invitations_recovery_tick()")
[ -n "$REQ" ] || fallo "con entregas pendientes y Vault configurado, la tarea debe llamar a la función"
igual "$(ultimo)" solicitada "entrega pendiente y Vault configurado: llama a la función («solicitada»)"
if [ "$STUB" = 1 ]; then
  igual "$(Q -c "select url || ' | ' || (headers ->> 'x-turestaurante-recovery' = '$SECRET') || ' | ' || body::text || ' | ' || timeout_milliseconds from net.stub_requests where id = $REQ")" \
    "http://127.0.0.1:54398/functions/v1/invitations-recovery | true | {\"action\": \"recover\"} | 30000" \
    "la petición va a la URL de Vault, con el secreto de Vault en la cabecera y la acción «recover»"
  igual "$(Q -c "select count(*) from net.stub_requests where headers ? 'Authorization' or headers ? 'apikey'")" 0 \
    "la petición no lleva claves de Supabase (solo el secreto propio)"
  Q -c "update net.stub_config set fail = true" > /dev/null
  igual "$(Q -c "select coalesce(private.invitations_recovery_tick()::text, 'nada')")" nada "si pg_net falla, la tarea no se rompe"
  igual "$(ultimo)" error "el fallo queda anotado («error»)"
  igual "$(Q -c "select detail like '%fallo simulado%' from private.invitations_recovery_runs order by id desc limit 1")" t "con el mensaje del error"
  Q -c "update net.stub_config set fail = false" > /dev/null
  # Respuesta de la función tal como la guardaría pg_net (aquí la escribimos nosotros: sustituto)
  Q -c "insert into net._http_response (id, status_code, content_type, content, timed_out)
        values ($REQ, 200, 'application/json', '{\"ok\":true,\"procesadas\":1,\"resultados\":{\"enviada\":1}}', false)" > /dev/null
fi
igual "$(Q -c "select count(*) from private.invitations_recovery_runs where detail ~ '$SECRET' or detail ~* 'secret[o]?[^ ]*[a-f0-9]{32}'")" 0 \
  "el registro de ejecuciones no contiene el secreto"

# ---------- Permisos ----------
igual "$(AS authenticated $ADMIN "select count(*) > 0 from public.invitations_recovery_status(50) where outcome in ('solicitada', 'sin_configurar', 'sin_pendientes')")" t \
  "plataforma: ve las ejecuciones"
[ "$STUB" = 0 ] || igual "$(AS authenticated $ADMIN "select http_status || ' ' || (summary ->> 'procesadas') from public.invitations_recovery_status(50) where outcome = 'solicitada' and http_status is not null limit 1")" \
  "200 1" "plataforma: ve el estado HTTP y el resumen de la respuesta"
igual "$(AS authenticated $ADMIN "select schedule || ' ' || active from public.invitations_recovery_job()")" "*/5 * * * * true" "plataforma: ve la tarea, su frecuencia y si está activa"
deniega authenticated $OWNER "select * from public.invitations_recovery_status(5)" "Solo la plataforma" "propietario: no ve las ejecuciones"
deniega authenticated $OWNER "select * from public.invitations_recovery_job()" "Solo la plataforma" "propietario: no ve la tarea"
deniega anon - "select * from public.invitations_recovery_status(5)" "permission denied" "anónimo: no ve nada"
for R in anon authenticated service_role; do
  deniega $R $OWNER "select private.invitations_recovery_tick()" "permission denied" "$R: no puede lanzar la tarea"
  deniega $R $OWNER "select * from private.invitations_recovery_runs" "permission denied" "$R: no lee el registro de ejecuciones"
done
deniega authenticated $ADMIN "select cron.schedule('x', '* * * * *', 'select 1')" "permission denied" "plataforma (API): no puede crear tareas de pg_cron"
deniega authenticated $ADMIN "select * from vault.decrypted_secrets" "permission denied" "plataforma (API): no lee los secretos de Vault"

# ---------- Reintentos, esperas y límites (la tarea respeta la cola) ----------
claim() { AS service_role - "select claim from public.invitation_delivery_claim('$1')"; }
fin() { AS service_role - "select public.invitation_delivery_finish('$1', '$2', '$3')"; }
Q -c "update private.invitations set send_status = 'enviada', send_attempts = 1 where id = '$FRESCA'" > /dev/null  # ya entregada
C=$(claim "$P1"); fin "$P1" "$C" reintentar > /dev/null    # fallo temporal: espera 5 min
Q -c "select private.invitations_recovery_tick()" > /dev/null
igual "$(ultimo)" sin_pendientes "fallo temporal: la tarea no reintenta antes de la espera"
Q -c "update private.invitations set send_next_at = now() - interval '1 second' where id = '$P1'" > /dev/null
Q -c "select private.invitations_recovery_tick()" > /dev/null
igual "$(ultimo)" solicitada "fallo temporal: pasada la espera, la tarea vuelve a llamar (la cola no se bloquea)"
C=$(claim "$P1"); fin "$P1" "$C" reintentar > /dev/null
Q -c "update private.invitations set send_next_at = now() - interval '1 second' where id = '$P1'" > /dev/null
C=$(claim "$P1"); fin "$P1" "$C" reintentar > /dev/null
igual "$(Q -c "select send_status || '/' || send_attempts from private.invitations where id = '$P1'")" fallida/3 "tras 3 intentos queda «fallida»"
Q -c "select private.invitations_recovery_tick()" > /dev/null
igual "$(ultimo)" sin_pendientes "una entrega «fallida» no vuelve a activar la tarea (sin envíos en masa)"
P2=$(pendiente colgada@x.test '20 minutes'); claim "$P2" > /dev/null
Q -c "update private.invitations set send_claimed_at = now() - interval '11 minutes' where id = '$P2'" > /dev/null
Q -c "select private.invitations_recovery_tick()" > /dev/null
igual "$(ultimo)" solicitada "una reserva interrumpida (más de 10 min) activa la tarea"

# ---------- Ejecuciones simultáneas: cada entrega se reserva una sola vez ----------
IDS=""; for i in $(seq 5); do IDS="$IDS,'$(pendiente "simultanea$i@x.test" '3 minutes')'"; done; IDS="${IDS#,},'$P2'"
T=$(Q -c "select (clock_timestamp() + interval '1 second')::text"); TMPD=$(mktemp -d)
for i in $(seq 8); do
  AS service_role - "select pg_sleep(greatest(0, extract(epoch from ('$T'::timestamptz - clock_timestamp()))));
    select count(*) from public.invitation_delivery_pending(10) p, lateral public.invitation_delivery_claim(p) c where p in ($IDS)" > "$TMPD/$i" &
done; wait
igual "$(cat "$TMPD"/* | awk '{s+=$1} END {print s}')" 6 "8 recuperaciones simultáneas: cada una de las 6 entregas se reserva una sola vez"
rm -rf "$TMPD"

# ---------- pg_cron ejecuta de verdad la recuperación ----------
Q -c "insert into private.invitations_recovery_runs (started_at, outcome) values (now() - interval '8 days', 'sin_pendientes')" > /dev/null
N0=$(Q -c "select count(*) from private.invitations_recovery_runs where started_at > now() - interval '1 day'")
Q -c "select cron.schedule('turestaurante-prueba-segundos', '2 seconds', 'select private.invitations_recovery_tick()')" > /dev/null
sleep 7
Q -c "select cron.unschedule('turestaurante-prueba-segundos')" > /dev/null
N1=$(Q -c "select count(*) from private.invitations_recovery_runs where started_at > now() - interval '1 day'")
[ "$N1" -gt "$N0" ] || fallo "pg_cron no ejecutó la recuperación (ejecuciones: $N0 → $N1)"
ok "pg_cron (real) ejecuta la recuperación programada: $((N1 - N0)) ejecuciones en 7 s con una tarea de prueba cada 2 s"
igual "$(Q -c "select count(*) > 0 from cron.job_run_details where command = 'select private.invitations_recovery_tick()' and status = 'succeeded'")" t \
  "pg_cron anota esas ejecuciones como correctas (cron.job_run_details)"
igual "$(Q -c "select count(*) from private.invitations_recovery_runs where started_at < now() - interval '7 days'")" 0 "las ejecuciones de más de 7 días se borran solas"

# ---------- Desactivar ----------
Q -c "select cron.alter_job((select jobid from cron.job where jobname = '$JOB'), active := false)" > /dev/null
igual "$(AS authenticated $ADMIN "select active from public.invitations_recovery_job()")" f "se puede desactivar (cron.alter_job) y se ve desactivada"
Q -c "select cron.alter_job((select jobid from cron.job where jobname = '$JOB'), active := true)" > /dev/null

# ---------- Prueba completa opcional con la Edge Function real (Deno) ----------
if [ "${RECOVERY_E2E:-0}" = 1 ] && [ "$STUB" = 1 ]; then
  bash tests/recovery_e2e.sh "$DB" "$SECRET"
fi

# ---------- Bajada (y nueva subida) ----------
INV=$(Q -c "select count(*) || '/' || string_agg(send_status, ',' order by id) from private.invitations")
Q -f "$DOWN" > /dev/null
igual "$(Q -c "select count(*) from cron.job where jobname = '$JOB'")" 0 "bajada: quita la tarea programada"
igual "$(Q -c "select to_regprocedure('private.invitations_recovery_tick()') is null and to_regclass('private.invitations_recovery_runs') is null
  and to_regprocedure('public.invitations_recovery_status(int)') is null")" t "bajada: quita sus funciones y el registro de ejecuciones"
igual "$(Q -c "select count(*) || '/' || string_agg(send_status, ',' order by id) from private.invitations")" "$INV" "bajada: no toca las invitaciones ni sus entregas"
igual "$(Q -c "select count(*) from vault.decrypted_secrets where name like 'turestaurante_recovery_%'")" 2 "bajada: no borra los secretos de Vault (se borran a mano)"
Q -f "$DOWN" > /dev/null
ok "la bajada se puede repetir"
Q -f "$UP" > /dev/null
igual "$(Q -c "select count(*) from cron.job where jobname = '$JOB'")" 1 "subida otra vez tras la bajada: una tarea"
Q -f "$DOWN" > /dev/null
psql -q -X -d postgres -c "drop database $DB with (force)"
echo "Recuperación programada: todas las comprobaciones superadas$([ "$STUB" = 1 ] && echo ' (pg_net y Vault: SUSTITUTO de prueba, no reales)')"
