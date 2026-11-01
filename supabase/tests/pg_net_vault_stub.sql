-- SOLO PARA PRUEBAS LOCALES. NO ejecutar en Supabase.
--
-- ESTO NO ES pg_net NI SUPABASE VAULT. Es un sustituto mínimo que imita los nombres que usa la
-- migración 20261105120000 (net.http_post, net._http_response, vault.decrypted_secrets) para probar
-- NUESTRO SQL en un PostgreSQL local sin esas extensiones:
--   * net.http_post NO hace ninguna petición HTTP: anota la petición en net.stub_requests (para
--     comprobar URL, cabeceras y cuerpo) o falla si net.stub_config.fail = true.
--   * vault.secrets NO cifra nada: guarda el texto tal cual.
-- No prueba el envío HTTP real de pg_net ni el cifrado de Vault: eso queda para Supabase (local o
-- remoto). supabase/tests/recovery_test.sh solo carga este archivo si las extensiones reales no
-- están disponibles, y lo dice en su salida.

create schema if not exists net;
create table if not exists net._http_response (
  id bigint primary key, status_code int, content_type text, headers jsonb, content text,
  timed_out boolean, error_msg text, created timestamptz not null default now()
);
create table if not exists net.stub_requests (
  id bigint generated always as identity primary key, url text, body jsonb, params jsonb, headers jsonb,
  timeout_milliseconds int, created timestamptz not null default now()
);
create table if not exists net.stub_config (fail boolean not null default false);
insert into net.stub_config select where not exists (select 1 from net.stub_config);

-- Misma firma que pg_net 0.20 (url, body, params, headers, timeout_milliseconds) → id de la petición.
create or replace function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb,
  headers jsonb default '{"Content-Type": "application/json"}'::jsonb, timeout_milliseconds int default 5000)
returns bigint language plpgsql as $$
declare v bigint;
begin
  if (select fail from net.stub_config limit 1) then
    raise exception 'sustituto de pg_net: fallo simulado al encolar la petición';
  end if;
  insert into net.stub_requests (url, body, params, headers, timeout_milliseconds)
  values (url, body, params, headers, timeout_milliseconds) returning id into v;
  return v;
end $$;

create schema if not exists vault;
create table if not exists vault.secrets (
  id uuid primary key default gen_random_uuid(), name text unique, secret text not null, description text not null default ''
);
create or replace view vault.decrypted_secrets as
  select s.id, s.name, s.description, s.secret, s.secret as decrypted_secret from vault.secrets s;
create or replace function vault.create_secret(new_secret text, new_name text default null, new_description text default '')
returns uuid language sql as $$
  insert into vault.secrets (name, secret, description) values (new_name, new_secret, new_description) returning id
$$;
