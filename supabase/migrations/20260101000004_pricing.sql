-- =============================================================================
-- Maguirejuve · 04 · Motor de precios: condiciones y lista de precios historizada
-- =============================================================================

create table public.price_conditions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  rule_type public.price_rule_type not null,
  payment_method_id uuid references public.payment_methods (id) on delete restrict,
  min_units numeric(14, 2),
  discount_percent numeric(5, 4), -- informativo/comercial, NO se usa para calcular el precio real
  priority int not null,
  combinable boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint price_conditions_payment_requires_method
    check (rule_type <> 'PAYMENT_METHOD' or payment_method_id is not null),
  constraint price_conditions_quantity_requires_min_units
    check (rule_type <> 'QUANTITY' or min_units is not null),
  constraint price_conditions_min_units_positive check (min_units is null or min_units > 0),
  constraint price_conditions_discount_range
    check (discount_percent is null or (discount_percent >= 0 and discount_percent <= 1))
);

comment on table public.price_conditions is
  'Reglas de negocio (no acumulables) que determinan qué lista de precios aplica. '
  'La precedencia se define por "priority" (menor = mayor precedencia) y es editable sin deploy. '
  'discount_percent es solo referencia comercial: el precio real y vendible vive en product_prices.';

create trigger trg_price_conditions_updated_at
  before update on public.price_conditions
  for each row execute function public.set_updated_at();

create unique index price_conditions_one_base
  on public.price_conditions (rule_type)
  where rule_type = 'BASE';

comment on index public.price_conditions_one_base is
  'Solo puede existir una condición BASE (LIST): es el fallback que siempre matchea.';

-- ---------------------------------------------------------------------------
-- Historial de precios. Un precio nunca se pisa: se cierra vigencia y se crea uno nuevo.
-- ---------------------------------------------------------------------------
create table public.product_prices (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products (id) on delete cascade,
  price_condition_id uuid not null references public.price_conditions (id) on delete restrict,
  amount numeric(14, 2) not null check (amount > 0),
  valid_from timestamptz not null default now(),
  valid_until timestamptz,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  constraint product_prices_valid_range check (valid_until is null or valid_until > valid_from)
);

comment on table public.product_prices is
  'Snapshot histórico de precios. NUNCA actualizar amount de una fila existente: '
  'cerrar valid_until y crear una fila nueva (ver rpc set_product_price).';

-- Evita solapamiento de vigencias activas para el mismo producto+condición.
-- (protección adicional; la RPC de administración ya cierra la vigencia anterior)
create index product_prices_lookup_idx
  on public.product_prices (product_id, price_condition_id, valid_from desc);

create index product_prices_active_window_idx
  on public.product_prices (product_id, price_condition_id)
  where active = true;
