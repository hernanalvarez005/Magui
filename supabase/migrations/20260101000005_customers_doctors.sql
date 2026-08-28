-- =============================================================================
-- Maguirejuve · 05 · Clientes y doctoras (comisión)
-- =============================================================================

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  dni text,
  full_name text not null,
  whatsapp text,
  email citext,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  origin_location_id uuid references public.stock_locations (id),
  active boolean not null default true,
  notes text
);

comment on table public.customers is
  'Cliente opcional en una venta presencial. DNI/teléfono/nombre son buscables.';

-- Previene duplicados razonables por DNI (sin bloquear clientes sin DNI).
create unique index customers_dni_unique_idx
  on public.customers (dni)
  where dni is not null and dni <> '';

create index customers_full_name_trgm_idx on public.customers using gin (full_name gin_trgm_ops);
create index customers_whatsapp_idx on public.customers (whatsapp) where whatsapp is not null;

create table public.doctors (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  full_name text not null,
  commission_percent numeric(5, 4) not null default 0.20
    check (commission_percent >= 0 and commission_percent <= 1),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.doctors is
  'Comisión aplicada SOLO sobre líneas de venta commissionable (ver fn_pricing_quote).';

create trigger trg_doctors_updated_at
  before update on public.doctors
  for each row execute function public.set_updated_at();
