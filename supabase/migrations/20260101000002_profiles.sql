-- =============================================================================
-- Maguirejuve · 02 · Perfiles, roles y acceso por sucursal
-- =============================================================================

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  role public.app_role not null default 'seller',
  active boolean not null default true,
  can_view_financial_reports boolean not null default false,
  can_adjust_stock boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is
  'Extiende auth.users. Un admin NO ve automáticamente todas las sucursales: eso lo define profile_locations.';

create trigger trg_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- Se crea automáticamente un profile "seller" inactivo al registrarse un auth.users.
-- Queda inactivo hasta que un admin lo active y le asigne rol/sucursales.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, role, active)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email, 'Sin nombre'),
    'seller',
    false
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger trg_on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- ---------------------------------------------------------------------------
-- stock_locations (se referencia desde profile_locations, se define acá para
-- resolver la dependencia de orden; el resto de "catálogo" de ubicaciones/canales
-- vive conceptualmente en esta migración de "identidad y acceso").
-- ---------------------------------------------------------------------------
create table public.stock_locations (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  short_code text not null unique,
  name text not null,
  type public.stock_location_type not null default 'branch',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.stock_locations is
  'Ubicación física del stock (sede/depósito). No confundir con sales_channels (canal de venta).';
comment on column public.stock_locations.short_code is
  'Usado para armar sale_number, ej. "37" o "25".';

create trigger trg_stock_locations_updated_at
  before update on public.stock_locations
  for each row execute function public.set_updated_at();

create table public.profile_locations (
  profile_id uuid not null references public.profiles (id) on delete cascade,
  location_id uuid not null references public.stock_locations (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (profile_id, location_id)
);

comment on table public.profile_locations is
  'A qué sedes tiene acceso cada usuario (admin incluido). Sin fila = sin acceso a esa sede.';

-- ---------------------------------------------------------------------------
-- Helpers de permisos, usados por policies RLS y por las RPC.
-- SECURITY DEFINER + search_path fijo para evitar hijacking, pero solo leen.
-- ---------------------------------------------------------------------------
create or replace function public.current_profile_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid();
$$;

create or replace function public.is_active_profile()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.active = true
  );
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.active = true and p.role = 'admin'
  );
$$;

create or replace function public.has_location_access(p_location_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profile_locations pl
    join public.profiles p on p.id = pl.profile_id
    where pl.profile_id = auth.uid()
      and pl.location_id = p_location_id
      and p.active = true
  );
$$;

comment on function public.has_location_access(uuid) is
  'Un admin también necesita estar en profile_locations: el acceso por sede es explícito para todos los roles.';
