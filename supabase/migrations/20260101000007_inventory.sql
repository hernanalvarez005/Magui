-- =============================================================================
-- Maguirejuve · 07 · Inventario: saldos, ledger de movimientos, transferencias
-- =============================================================================

create table public.inventory_balances (
  location_id uuid not null references public.stock_locations (id),
  product_id uuid not null references public.products (id),
  quantity numeric(14, 2) not null default 0,
  min_stock_override numeric(14, 2),
  updated_at timestamptz not null default now(),
  primary key (location_id, product_id)
);

comment on table public.inventory_balances is
  'Saldo actual por sede/producto. Es un CACHÉ derivado de stock_movements: nunca se '
  'edita directamente, siempre a través de fn_apply_stock_movement().';

create table public.stock_transfers (
  id uuid primary key default gen_random_uuid(),
  transfer_number text not null unique,
  from_location_id uuid not null references public.stock_locations (id),
  to_location_id uuid not null references public.stock_locations (id),
  status public.stock_transfer_status not null default 'confirmed',
  notes text,
  created_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  constraint stock_transfers_different_locations check (from_location_id <> to_location_id)
);

create table public.stock_transfer_items (
  id uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references public.stock_transfers (id) on delete cascade,
  product_id uuid not null references public.products (id),
  quantity numeric(14, 2) not null check (quantity > 0)
);

create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  occurred_at timestamptz not null default now(),
  location_id uuid not null references public.stock_locations (id),
  product_id uuid not null references public.products (id),
  movement_type public.stock_movement_type not null,
  quantity_delta numeric(14, 2) not null check (quantity_delta <> 0),
  sale_id uuid references public.sales (id),
  transfer_id uuid references public.stock_transfers (id),
  reference text,
  reason public.stock_adjustment_reason,
  notes text,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  constraint stock_movements_sign_matches_type check (
    case movement_type
      when 'INITIAL' then true
      when 'PURCHASE' then quantity_delta > 0
      when 'SALE' then quantity_delta < 0
      when 'SALE_CANCEL' then quantity_delta > 0
      when 'ADJUSTMENT_PLUS' then quantity_delta > 0
      when 'ADJUSTMENT_MINUS' then quantity_delta < 0
      when 'TRANSFER_OUT' then quantity_delta < 0
      when 'TRANSFER_IN' then quantity_delta > 0
      when 'RETURN' then quantity_delta > 0
      else true
    end
  ),
  constraint stock_movements_sale_requires_sale_id
    check (movement_type not in ('SALE', 'SALE_CANCEL') or sale_id is not null),
  constraint stock_movements_transfer_requires_transfer_id
    check (movement_type not in ('TRANSFER_OUT', 'TRANSFER_IN') or transfer_id is not null),
  constraint stock_movements_created_by_required
    check (
      -- SALE/SALE_CANCEL: puede originarse en una importación server-side (service_role)
      -- sin auth.uid(). INITIAL/PURCHASE: pueden venir de una migración de datos históricos.
      movement_type in ('SALE', 'SALE_CANCEL', 'INITIAL', 'PURCHASE') or created_by is not null
    )
);

comment on table public.stock_movements is
  'Ledger auditable e inmutable (no UPDATE/DELETE vía policies). quantity_delta lleva signo.';
comment on column public.stock_movements.quantity_delta is
  'Positivo = ingreso (INITIAL/PURCHASE/SALE_CANCEL/ADJUSTMENT_PLUS/TRANSFER_IN/RETURN). '
  'Negativo = egreso (SALE/ADJUSTMENT_MINUS/TRANSFER_OUT).';

-- ---------------------------------------------------------------------------
-- Aplica un movimiento y actualiza inventory_balances de forma atómica.
-- Es la ÚNICA vía permitida para tocar inventory_balances.
-- No valida permisos (lo hacen las RPC que la llaman) pero sí valida stock negativo.
-- ---------------------------------------------------------------------------
create or replace function public.fn_apply_stock_movement(
  p_location_id uuid,
  p_product_id uuid,
  p_movement_type public.stock_movement_type,
  p_quantity_delta numeric,
  p_sale_id uuid default null,
  p_transfer_id uuid default null,
  p_reference text default null,
  p_reason public.stock_adjustment_reason default null,
  p_notes text default null,
  p_created_by uuid default null,
  p_allow_negative boolean default false
)
returns public.stock_movements
language plpgsql
as $$
declare
  v_current numeric(14, 2);
  v_resulting numeric(14, 2);
  v_movement public.stock_movements;
  v_product_name text;
begin
  -- Bloquea (o crea) la fila de saldo para esta sede/producto.
  insert into public.inventory_balances (location_id, product_id, quantity)
  values (p_location_id, p_product_id, 0)
  on conflict (location_id, product_id) do nothing;

  select quantity into v_current
  from public.inventory_balances
  where location_id = p_location_id and product_id = p_product_id
  for update;

  v_resulting := v_current + p_quantity_delta;

  if v_resulting < 0 and not p_allow_negative then
    select name into v_product_name from public.products where id = p_product_id;
    raise exception using
      errcode = 'P1001',
      message = format(
        'No hay stock suficiente de %s. Disponible: %s. Requerido: %s.',
        coalesce(v_product_name, 'producto'), v_current, abs(p_quantity_delta)
      );
  end if;

  update public.inventory_balances
  set quantity = v_resulting, updated_at = now()
  where location_id = p_location_id and product_id = p_product_id;

  insert into public.stock_movements (
    location_id, product_id, movement_type, quantity_delta,
    sale_id, transfer_id, reference, reason, notes, created_by
  ) values (
    p_location_id, p_product_id, p_movement_type, p_quantity_delta,
    p_sale_id, p_transfer_id, p_reference, p_reason, p_notes, p_created_by
  )
  returning * into v_movement;

  return v_movement;
end;
$$;

-- ---------------------------------------------------------------------------
-- Disponibilidad de kits: mínimo entre componentes de floor(saldo / cantidad requerida).
-- ---------------------------------------------------------------------------
create or replace function public.fn_kit_buildable_qty(p_kit_product_id uuid, p_location_id uuid)
returns numeric
language sql
stable
as $$
  select coalesce(min(floor(coalesce(ib.quantity, 0) / kc.quantity)), 0)
  from public.kit_components kc
  left join public.inventory_balances ib
    on ib.product_id = kc.component_product_id and ib.location_id = p_location_id
  where kc.kit_product_id = p_kit_product_id;
$$;

comment on function public.fn_kit_buildable_qty(uuid, uuid) is
  'Cuántas unidades del kit se pueden armar hoy en esa sede, según el componente limitante. '
  'Devuelve 0 si el kit no tiene componentes cargados (ej. KIT-EACP, inactivo).';
