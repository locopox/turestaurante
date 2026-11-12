-- =====================================================================================
-- Migración 20261112120000 · base comercial (fase 8, etapa 1): cuenta comercial de cada restaurante.
-- Se aplica DESPUÉS de 20261108120000_limites_pedidos.sql (rama correccion-qr, 886a37c).
-- Equivale a los bloques «-- >>> fase8» de supabase/schema.sql (generada a partir de ellos).
--
-- NO borra ni modifica datos: no toca restaurantes, carta, pedidos, personal, cuentas, invitaciones,
-- límites de pedidos ni el registro de auditoría. Añade private.commercial_plans («profesional») y
-- private.tenant_accounts, y crea la cuenta comercial de cada restaurante que ya existe con el estado
-- «sin_asignar» (conserva su situación actual). Los restaurantes creados después empiezan en «borrador».
-- EN ESTA ETAPA EL ESTADO COMERCIAL NO BLOQUEA NADA: los pedidos, la cocina y el resto funcionan igual.
-- Se puede ejecutar más de una vez.
-- Para deshacerla: supabase/migrations_down/20261112120000_base_comercial.down.sql
-- =====================================================================================

begin;

-- >>> fase8
-- Planes comerciales. De momento solo «profesional» (el de la prueba gratuita); los demás planes,
-- sus precios y sus funciones se añadirán cuando se decidan. Privada: no es accesible por la API.
create table if not exists private.commercial_plans (
  code text primary key check (code ~ '^[a-z][a-z0-9_]{1,30}$'),
  name text not null check (char_length(btrim(name)) between 2 and 40),
  created_at timestamptz not null default now()
);
insert into private.commercial_plans (code, name) values ('profesional', 'Profesional') on conflict (code) do nothing;

-- Cuenta comercial de cada restaurante (una por restaurante). Privada: solo la escriben funciones y
-- triggers del servidor; nadie la lee ni la escribe por la API (se consulta con
-- restaurant_commercial_status y platform_list_commercial_accounts).
-- Estados:
--   sin_asignar  SOLO restaurantes que ya existían al introducir el sistema comercial (origin = 'existente'):
--                conservan su situación hasta que se les asigne expresamente una modalidad.
--   borrador     estado inicial de TODO restaurante creado después (autorregistro, plataforma o SQL Editor).
--   prueba       prueba gratuita en curso (fechas y plan obligatorios).
--   activa       suscripción válida.
--   vencida      prueba o suscripción terminada.
-- En esta etapa el estado NO bloquea nada: solo se guarda. Los pedidos funcionan igual que antes.
create table if not exists private.tenant_accounts (
  restaurant_id uuid primary key references public.restaurants on delete cascade,
  status text not null default 'borrador'
    check (status in ('sin_asignar', 'borrador', 'prueba', 'activa', 'vencida')),
  plan_code text references private.commercial_plans (code),
  trial_started_at timestamptz,
  trial_ends_at timestamptz,
  -- 'existente': ya existía al crear este sistema (única forma de tener «sin_asignar») · 'alta': creado después.
  origin text not null default 'alta' check (origin in ('existente', 'alta')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint tenant_accounts_unassigned_only_existing check (status <> 'sin_asignar' or origin = 'existente'),
  constraint tenant_accounts_trial_dates check ((trial_started_at is null) = (trial_ends_at is null)
    and (trial_ends_at is null or trial_ends_at > trial_started_at)),
  constraint tenant_accounts_trial_complete check (status <> 'prueba' or (trial_started_at is not null and plan_code is not null)),
  constraint tenant_accounts_no_trial_before check (status not in ('sin_asignar', 'borrador') or trial_started_at is null)
);
create index if not exists tenant_accounts_status_idx on private.tenant_accounts (status);
-- <<< fase8

-- >>> fase8
-- ---------- Cuenta comercial de los restaurantes ----------
-- Reglas que se aplican a TODOS (también al servidor y al SQL Editor), para que nadie pueda manipular
-- estados, planes ni fechas aunque una función tuviera un error:
--  * Al crearla: solo «borrador», o «sin_asignar» si es de un restaurante que ya existía; sin prueba ni plan.
--  * No cambia de restaurante. No se borra mientras exista el restaurante.
--  * Transiciones permitidas: sin_asignar→activa · borrador→prueba|activa · prueba→activa|vencida ·
--    activa→vencida · vencida→activa. Nadie vuelve a «sin_asignar» ni a «borrador».
--  * La prueba empieza AHORA (hora de la base de datos) y dura exactamente 14 días; una vez empezada,
--    su inicio no cambia y su fin solo se puede retrasar (ampliación), nunca adelantar ni borrar.
create or replace function private.guard_tenant_accounts() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'TRUNCATE' then
    raise exception 'Las cuentas comerciales no se pueden vaciar' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then
    -- Solo desaparece junto con su restaurante (borrado en cascada).
    if exists (select 1 from public.restaurants r where r.id = old.restaurant_id) then
      raise exception 'La cuenta comercial no se puede borrar mientras exista su restaurante' using errcode = '42501';
    end if;
    return old;
  end if;
  if tg_op = 'INSERT' then
    if new.status not in ('borrador', 'sin_asignar') then
      raise exception 'Una cuenta comercial nueva empieza como borrador' using errcode = '42501';
    end if;
    if new.trial_started_at is not null or new.trial_ends_at is not null or new.plan_code is not null then
      raise exception 'Una cuenta comercial nueva no tiene prueba ni plan' using errcode = '42501';
    end if;
    new.created_at := now();
    new.updated_at := now();
    new.updated_by := (select auth.uid());
    return new;
  end if;
  if (new.restaurant_id, new.origin, new.created_at) is distinct from (old.restaurant_id, old.origin, old.created_at) then
    raise exception 'No se puede cambiar a qué restaurante pertenece la cuenta comercial ni su origen' using errcode = '42501';
  end if;
  if new.status is distinct from old.status and (old.status, new.status) not in (
      ('sin_asignar', 'activa'), ('borrador', 'prueba'), ('borrador', 'activa'),
      ('prueba', 'activa'), ('prueba', 'vencida'), ('activa', 'vencida'), ('vencida', 'activa')) then
    raise exception 'Cambio de estado comercial no permitido (% → %)', old.status, new.status using errcode = '42501';
  end if;
  if old.trial_started_at is null and new.trial_started_at is not null then
    -- Empieza la prueba: solo desde borrador, ahora mismo y por 14 días exactos.
    if old.status <> 'borrador' or new.status <> 'prueba' then
      raise exception 'La prueba gratuita solo puede empezar en un restaurante en borrador' using errcode = '42501';
    end if;
    if new.trial_started_at <> now() or new.trial_ends_at <> now() + interval '14 days' then
      raise exception 'La prueba gratuita empieza ahora y dura 14 días: sus fechas no se pueden elegir' using errcode = '42501';
    end if;
  elsif new.trial_started_at is distinct from old.trial_started_at then
    raise exception 'La fecha de inicio de la prueba no se puede cambiar' using errcode = '42501';
  elsif old.trial_ends_at is not null and (new.trial_ends_at is null or new.trial_ends_at < old.trial_ends_at) then
    raise exception 'El fin de la prueba no se puede adelantar ni borrar' using errcode = '42501';
  end if;
  new.updated_at := now();
  new.updated_by := (select auth.uid());
  return new;
end $$;

-- Cada restaurante nuevo nace con su cuenta comercial en «borrador» (nunca «sin_asignar»).
create or replace function private.create_tenant_account() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into private.tenant_accounts (restaurant_id, status, origin) values (new.id, 'borrador', 'alta')
  on conflict (restaurant_id) do nothing;
  return null;
end $$;

-- Registro de auditoría de la cuenta comercial (alta y cada cambio de estado, plan o fechas).
create or replace function private.audit_tenant_accounts() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.audit_insert(new.restaurant_id, 'comercial.alta', 'tenant_accounts', new.restaurant_id::text,
      jsonb_build_object('estado', new.status, 'origen', new.origin));
  elsif (new.status, new.plan_code, new.trial_started_at, new.trial_ends_at)
        is distinct from (old.status, old.plan_code, old.trial_started_at, old.trial_ends_at) then
    perform private.audit_insert(new.restaurant_id, 'comercial.cambio', 'tenant_accounts', new.restaurant_id::text,
      jsonb_build_object('antes', jsonb_build_object('estado', old.status, 'plan', old.plan_code, 'fin_prueba', old.trial_ends_at),
        'despues', jsonb_build_object('estado', new.status, 'plan', new.plan_code, 'fin_prueba', new.trial_ends_at)));
  end if;
  return null;
end $$;

drop trigger if exists tenant_accounts_guard on private.tenant_accounts;
create trigger tenant_accounts_guard before insert or update or delete on private.tenant_accounts
  for each row execute function private.guard_tenant_accounts();
drop trigger if exists tenant_accounts_no_truncate on private.tenant_accounts;
create trigger tenant_accounts_no_truncate before truncate on private.tenant_accounts
  for each statement execute function private.guard_tenant_accounts();
drop trigger if exists tenant_accounts_audit on private.tenant_accounts;
create trigger tenant_accounts_audit after insert or update on private.tenant_accounts
  for each row execute function private.audit_tenant_accounts();
drop trigger if exists restaurants_tenant_account on public.restaurants;
create trigger restaurants_tenant_account after insert on public.restaurants
  for each row execute function private.create_tenant_account();

-- Restaurantes que YA existían al introducir el sistema comercial: «sin_asignar», conservan su
-- situación actual. Solo crea las cuentas que falten: no cambia ninguna existente ni ningún dato.
insert into private.tenant_accounts (restaurant_id, status, origin)
select r.id, 'sin_asignar', 'existente' from public.restaurants r
where not exists (select 1 from private.tenant_accounts a where a.restaurant_id = r.id)
on conflict (restaurant_id) do nothing;

-- Lo que se puede ver de una cuenta comercial (sin quién la cambió ni otros datos internos).
create or replace function private.commercial_json(a private.tenant_accounts) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('restaurantId', a.restaurant_id, 'status', a.status, 'plan', a.plan_code,
    'planName', (select p.name from private.commercial_plans p where p.code = a.plan_code),
    'trialStartedAt', a.trial_started_at, 'trialEndsAt', a.trial_ends_at,
    -- Calculado con la hora de la base de datos: la app no usa el reloj del navegador.
    'trialSecondsLeft', case when a.status = 'prueba' then greatest(0, floor(extract(epoch from a.trial_ends_at - now())))::bigint end,
    'serverNow', now())
$$;

-- Estado comercial de UN restaurante. Lo ven su owner y su manager, y la plataforma. Para cualquier
-- otro (sala, cocina, otros restaurantes, sin sesión) el mismo rechazo, exista o no el restaurante.
create or replace function public.restaurant_commercial_status(p_restaurant_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  a private.tenant_accounts;
begin
  if (select auth.uid()) is null
     or not (private.is_platform_admin() or private.has_role(p_restaurant_id, array['owner', 'manager']::public.staff_role[])) then
    raise exception 'No tienes acceso al estado comercial de este restaurante' using errcode = '42501';
  end if;
  select * into a from private.tenant_accounts where restaurant_id = p_restaurant_id;
  if not found then
    raise exception 'Restaurante no encontrado' using errcode = '22023';
  end if;
  return private.commercial_json(a);
end $$;

-- Plataforma: cuentas comerciales de todos los restaurantes (opcionalmente de un estado).
create or replace function public.platform_list_commercial_accounts(p_status text default null, p_limit int default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or not private.is_platform_admin() then
    raise exception 'Solo la plataforma puede consultar las cuentas comerciales' using errcode = '42501';
  end if;
  if p_status is not null and p_status not in ('sin_asignar', 'borrador', 'prueba', 'activa', 'vencida') then
    raise exception 'Estado comercial no válido' using errcode = '22023';
  end if;
  return coalesce((
    select jsonb_agg(private.commercial_json(a) || jsonb_build_object('restaurantName', r.name, 'slug', r.slug,
      'origin', a.origin, 'updatedAt', a.updated_at) order by r.name, r.id)
    from (select * from private.tenant_accounts x where p_status is null or x.status = p_status
          order by x.restaurant_id limit greatest(1, least(coalesce(p_limit, 200), 1000))) a
    join public.restaurants r on r.id = a.restaurant_id
  ), '[]'::jsonb);
end $$;
-- <<< fase8

-- >>> fase8
-- Funciones internas de la cuenta comercial: nadie de la API puede ejecutarlas.
revoke all on function private.guard_tenant_accounts(), private.create_tenant_account(), private.audit_tenant_accounts(),
  private.commercial_json(private.tenant_accounts) from public, anon, authenticated, service_role;
revoke all on function public.restaurant_commercial_status(uuid), public.platform_list_commercial_accounts(text, int)
  from public, anon, authenticated, service_role;
-- Cada función comprueba dentro quién llama (owner/manager del restaurante, o plataforma).
grant execute on function public.restaurant_commercial_status(uuid), public.platform_list_commercial_accounts(text, int)
  to authenticated;
-- <<< fase8

-- >>> fase8
-- Cuentas comerciales y planes: nadie los lee ni escribe por la API (solo funciones y triggers).
revoke all on private.tenant_accounts, private.commercial_plans from public, anon, authenticated, service_role;
alter table private.tenant_accounts enable row level security;
alter table private.commercial_plans enable row level security;
-- <<< fase8

commit;
