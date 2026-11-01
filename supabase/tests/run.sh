#!/usr/bin/env bash
# Ejecuta las pruebas SQL en un PostgreSQL LOCAL y desechable. Nunca contra Supabase.
# Uso: PGHOST=... PGPORT=... PGUSER=postgres supabase/tests/run.sh
# Crea (y borra al empezar) una base de datos llamada turestaurante_test.
set -euo pipefail
export PGOPTIONS="-c client_min_messages=warning"
cd "$(dirname "$0")/.."
DB=turestaurante_test
case "${PGHOST:-localhost}" in
  *supabase.co*|*supabase.com*) echo "Este script solo se usa con una base de datos local." >&2; exit 1;;
esac
psql -v ON_ERROR_STOP=1 -q -d postgres -c "drop database if exists $DB" -c "create database $DB"
P="psql -v ON_ERROR_STOP=1 -q -d $DB"
$P -f tests/supabase_shim.sql
# Una tabla ajena al proyecto: el esquema no debe darle permisos al servidor
$P -c "create table public.tabla_ajena (id int); revoke all on public.tabla_ajena from service_role;"
$P -f schema.sql
# Una política ajena al proyecto: reejecutar el esquema no debe borrarla
$P -c "create policy politica_ajena_prueba on public.products for select to authenticated using (false);"
$P -f schema.sql   # se ejecuta dos veces: debe ser repetible
$P -f seed.sql
$P -f seed.sql                 # dos veces: no debe duplicar datos
$P -f tests/security_test.sql
# Entregas de invitaciones con procesos simultáneos (sesiones en paralelo), en otra base desechable
psql -v ON_ERROR_STOP=1 -q -d postgres -c "drop database if exists ${DB}_paralelo" -c "create database ${DB}_paralelo"
psql -v ON_ERROR_STOP=1 -q -d ${DB}_paralelo -f tests/supabase_shim.sql -f schema.sql -f seed.sql
bash tests/delivery_concurrency_test.sh ${DB}_paralelo
psql -q -d postgres -c "drop database ${DB}_paralelo"
