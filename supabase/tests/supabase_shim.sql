-- SOLO PARA PRUEBAS LOCALES. NO ejecutar en Supabase.
-- Reproduce lo mínimo de un proyecto de Supabase en un PostgreSQL vacío:
-- roles anon / authenticated / service_role, esquema auth con auth.uid() y auth.role(),
-- privilegios por defecto que Supabase concede en el esquema public y la publicación de Realtime.

-- Los roles son globales en el servidor: se crean solo si no existen.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin noinherit bypassrls; end if;
end $$;

create schema auth;
-- email_confirmed_at: como en Supabase Auth (null hasta que la persona confirma su correo).
create table auth.users (id uuid primary key, email text, email_confirmed_at timestamptz default now());

create function auth.uid() returns uuid language sql stable as $$
  select nullif(coalesce(current_setting('request.jwt.claim.sub', true),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')), '')::uuid
$$;
-- Definición vigente en Supabase Auth (github.com/supabase/auth,
-- migrations/20220224000811_update_auth_functions.up.sql), copiada tal cual.
create function auth.role() returns text language sql stable as $$
  select
  coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on all functions in schema auth to anon, authenticated, service_role;

-- Supabase concede todo en public a estos roles; la seguridad depende de RLS y de los revoke del esquema.
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

create publication supabase_realtime;
