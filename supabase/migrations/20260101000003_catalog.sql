-- =============================================================================
-- Maguirejuve · 03 · Catálogo: canales, medios de pago, productos, kits
-- =============================================================================

create table public.sales_channels (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  active boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_sales_channels_updated_at
  before update on public.sales_channels
  for each row execute function public.set_updated_at();

create table public.payment_methods (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  active boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_payment_methods_updated_at
  before update on public.payment_methods
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
create table public.products (
  id uuid primary key default gen_random_uuid(),
  sku text not null unique,
  name text not null,
  product_type public.product_type not null default 'product',
  category text,
  unit text not null default 'unidad',
  track_stock boolean not null default true,
  commissionable boolean not null default true,
  promo_eligible boolean not null default true,
  default_min_stock numeric(14, 2) not null default 0 check (default_min_stock >= 0),
  active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint products_kit_never_tracks_stock
    check (not (product_type = 'kit' and track_stock = true))
);

comment on table public.products is
  'Productos, accesorios y kits. Los kits (y combos como ACC-PADS2) tienen track_stock = false: '
  'su stock se deriva de kit_components, nunca de un contador propio.';

create trigger trg_products_updated_at
  before update on public.products
  for each row execute function public.set_updated_at();

create table public.kit_components (
  id uuid primary key default gen_random_uuid(),
  kit_product_id uuid not null references public.products (id) on delete cascade,
  component_product_id uuid not null references public.products (id) on delete restrict,
  quantity numeric(14, 2) not null check (quantity > 0),
  created_at timestamptz not null default now(),
  constraint kit_components_no_self_reference check (kit_product_id <> component_product_id),
  constraint kit_components_unique unique (kit_product_id, component_product_id)
);

comment on table public.kit_components is
  'Composición de kits/combos. Vender N kits descuenta N × cantidad de cada componente.';

-- Un producto marcado como "kit" (o cualquier producto con track_stock = false que sea
-- vendible) debe tener al menos un componente para poder activarse. Se valida en la
-- aplicación / seed en vez de un constraint de fila para permitir cargar el kit y sus
-- componentes en la misma transacción sin problemas de orden.
