-- =============================================================================
-- Maguirejuve · 01 · Extensiones y tipos enumerados base
-- =============================================================================
-- Convención: todo el esquema vive en `public`. Importes SIEMPRE numeric(14,2).
-- Zona horaria de negocio: America/Argentina/Buenos_Aires (se guarda en app_settings,
-- las columnas timestamptz se almacenan en UTC como es estándar en Postgres).

create extension if not exists "pgcrypto";   -- gen_random_uuid()
create extension if not exists "citext";     -- emails / búsquedas case-insensitive
create extension if not exists "pg_trgm";    -- búsqueda difusa de clientes/productos

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

create type public.app_role as enum ('admin', 'seller');

create type public.stock_location_type as enum ('branch', 'warehouse');

create type public.product_type as enum ('product', 'accessory', 'kit');

create type public.price_rule_type as enum ('BASE', 'PAYMENT_METHOD', 'QUANTITY');

create type public.sale_status as enum ('draft', 'confirmed', 'cancelled');

create type public.stock_movement_type as enum (
  'INITIAL',
  'PURCHASE',
  'SALE',
  'SALE_CANCEL',
  'ADJUSTMENT_PLUS',
  'ADJUSTMENT_MINUS',
  'TRANSFER_OUT',
  'TRANSFER_IN',
  'RETURN'
);

create type public.stock_transfer_status as enum ('confirmed', 'cancelled');

create type public.stock_adjustment_reason as enum (
  'RECEPTION',
  'BREAKAGE',
  'EXPIRATION',
  'COUNT_DIFFERENCE',
  'RETURN',
  'OTHER'
);

-- ---------------------------------------------------------------------------
-- Helper: updated_at trigger reutilizable
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Trigger genérico: mantiene updated_at actualizado en cada UPDATE.';
