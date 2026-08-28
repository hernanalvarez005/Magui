-- =============================================================================
-- Maguirejuve · 08 · Auditoría y configuración general del negocio
-- =============================================================================

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles (id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

comment on table public.audit_logs is
  'Bitácora de acciones sensibles: precios, promociones, ajustes/transferencias de stock, '
  'cancelación de ventas, cambios de permisos, alta/baja de productos.';

create table public.app_settings (
  id smallint primary key default 1,
  business_name text not null default 'Maguirejuve',
  currency text not null default 'ARS',
  timezone text not null default 'America/Argentina/Buenos_Aires',
  allow_negative_stock boolean not null default false,
  allow_transfer_overdraft boolean not null default false,
  default_doctor_commission numeric(5, 4) not null default 0.20,
  low_stock_enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id),
  constraint app_settings_single_row check (id = 1)
);

comment on table public.app_settings is
  'Fila única de configuración global. No usar esta tabla para conceptos que merecen entidad propia.';

create trigger trg_app_settings_updated_at
  before update on public.app_settings
  for each row execute function public.set_updated_at();

insert into public.app_settings (id) values (1) on conflict (id) do nothing;
