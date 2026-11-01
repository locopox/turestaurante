#!/usr/bin/env bash
# Prueba la cadena de migraciones en un PostgreSQL LOCAL y desechable. Nunca contra Supabase.
#   a5d5a87 (fase 2) + datos → fase 3 → fase 4  ==  instalación nueva de schema.sql
#   las subidas se pueden repetir y no alteran datos
#   bajar fase 4  ==  esquema de la fase 3 (07348e4) · bajar fase 3  ==  esquema de la fase 2 (a5d5a87)
set -euo pipefail
export PGOPTIONS="-c client_min_messages=warning"
cd "$(dirname "$0")/.."
case "${PGHOST:-localhost}" in *supabase.co*|*supabase.com*) echo "Solo para una base de datos local." >&2; exit 1;; esac
UP3=migrations/20261101120000_fase3_seguridad_roles.sql
UP4=migrations/20261102120000_fase4_modo_soporte.sql
DOWN3=migrations_down/20261101120000_fase3_seguridad_roles.down.sql
DOWN4=migrations_down/20261102120000_fase4_modo_soporte.down.sql
TMP=$(mktemp -d)
git show a5d5a87:supabase/schema.sql > "$TMP/schema_f2.sql"
git show 07348e4:supabase/schema.sql > "$TMP/schema_f3.sql"
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
nuevo_db mig_ref4; P mig_ref4 -f schema.sql; volcado mig_ref4 "$TMP/f4.sql"

nuevo_db mig_cadena; P mig_cadena -f "$TMP/schema_f2.sql"; con_datos mig_cadena; D0=$(datos mig_cadena)
P mig_cadena -f "$UP3"; volcado mig_cadena "$TMP/c3.sql"; iguales "$TMP/f3.sql" "$TMP/c3.sql" "fase 2 + subida fase 3 = esquema de la fase 3"
P mig_cadena -f "$UP4"; volcado mig_cadena "$TMP/c4.sql"; iguales "$TMP/f4.sql" "$TMP/c4.sql" "fase 3 + subida fase 4 = instalación nueva"
[ "$(datos mig_cadena)" = "$D0" ] || fallo "las subidas han cambiado datos"
echo "OK  las subidas conservan los datos ($D0: restaurantes/productos/pedidos/líneas/personal/importe)"
P mig_cadena -f "$UP3"; P mig_cadena -f "$UP4"; volcado mig_cadena "$TMP/c4b.sql"
diff -q "$TMP/c4.sql" "$TMP/c4b.sql" > /dev/null || fallo "repetir las subidas cambia la estructura"
[ "$(datos mig_cadena)" = "$D0" ] || fallo "repetir las subidas ha cambiado datos"
echo "OK  las subidas se pueden repetir"
P mig_cadena -f "$DOWN4"; volcado mig_cadena "$TMP/b3.sql"; iguales "$TMP/f3.sql" "$TMP/b3.sql" "bajada fase 4 = esquema de la fase 3"
P mig_cadena -f "$DOWN3"; volcado mig_cadena "$TMP/b2.sql"; iguales "$TMP/f2.sql" "$TMP/b2.sql" "bajada fase 3 = esquema de la fase 2"
[ "$(datos mig_cadena)" = "$D0" ] || fallo "las bajadas han cambiado datos"
echo "OK  las bajadas conservan pedidos, carta, restaurantes y personal"
psql -q -d postgres -c "drop database mig_ref2" -c "drop database mig_ref3" -c "drop database mig_ref4" -c "drop database mig_cadena"
rm -rf "$TMP"
echo "Migraciones: todas las comprobaciones superadas"
