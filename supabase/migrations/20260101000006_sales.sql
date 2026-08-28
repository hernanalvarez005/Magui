-- =============================================================================
-- Maguirejuve · 06 · Ventas y detalle de venta
-- =============================================================================

create table public.sales (
  id uuid primary key default gen_random_uuid(),
  sale_number text not null unique,
  sold_at timestamptz not null default now(),
  location_id uuid not null references public.stock_locations (id),
  sales_channel_id uuid not null references public.sales_channels (id),
  seller_id uuid not null references public.profiles (id),
  customer_id uuid references public.customers (id),
  doctor_id uuid references public.doctors (id),
  payment_method_id uuid not null references public.payment_methods (id),
  applied_price_condition_id uuid references public.price_conditions (id),
  subtotal numeric(14, 2) not null check (subtotal >= 0),
  discount_total numeric(14, 2) not null default 0 check (discount_total >= 0),
  total numeric(14, 2) not null check (total >= 0),
  commission_total numeric(14, 2) not null default 0 check (commission_total >= 0),
  status public.sale_status not null default 'confirmed',
  external_source text,
  external_order_id text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id),
  cancellation_reason text,
  constraint sales_total_consistency check (total = subtotal - discount_total),
  constraint sales_cancellation_consistency check (
    (status = 'cancelled' and cancelled_at is not null and cancelled_by is not null and cancellation_reason is not null)
    or (status <> 'cancelled' and cancelled_at is null and cancelled_by is null and cancellation_reason is null)
  )
);

comment on table public.sales is
  'Cabecera de venta. Nunca se borra (hard delete) una venta confirmada: se cancela y se '
  'conserva junto a sus movimientos inversos de stock. sale_number ej: MJ-37-20260827-0001.';

create trigger trg_sales_updated_at
  before update on public.sales
  for each row execute function public.set_updated_at();

-- Idempotencia de pedidos importados desde el canal Web / futuras integraciones.
create unique index sales_external_order_unique_idx
  on public.sales (external_source, external_order_id)
  where external_source is not null and external_order_id is not null;

create table public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales (id) on delete cascade,
  product_id uuid not null references public.products (id),
  quantity numeric(14, 2) not null check (quantity > 0),
  list_unit_price numeric(14, 2) not null check (list_unit_price > 0),
  sale_unit_price numeric(14, 2) not null check (sale_unit_price > 0),
  line_list_total numeric(14, 2) not null check (line_list_total >= 0),
  line_discount numeric(14, 2) not null default 0 check (line_discount >= 0),
  line_total numeric(14, 2) not null check (line_total >= 0),
  applied_price_condition_id uuid references public.price_conditions (id),
  commissionable boolean not null default false,
  created_at timestamptz not null default now(),
  constraint sale_items_totals_consistency
    check (line_list_total = list_unit_price * quantity)
);

comment on table public.sale_items is
  'Snapshot histórico e inmutable del precio al momento de la venta. NUNCA se recalcula '
  'cuando cambia product_prices.';

-- Contador atómico para sale_number (evita colisiones bajo concurrencia).
create table public.sale_number_counters (
  location_id uuid not null references public.stock_locations (id),
  day date not null,
  last_seq int not null default 0,
  primary key (location_id, day)
);

comment on table public.sale_number_counters is
  'Soporte interno de fn_next_sale_number(). No se expone a la API pública.';
