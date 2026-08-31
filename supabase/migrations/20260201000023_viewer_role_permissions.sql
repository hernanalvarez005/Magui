-- =============================================================================
-- Maguirejuve · 39 · Rol "viewer" (modo observador / solo lectura) — paso 2/2
-- =============================================================================
-- Objetivo: una persona pueda entrar con SU PROPIO usuario a ver cómo se está
-- gestionando (dashboard, reportes, ventas, stock, clientes, en TODAS las
-- sedes que se le asignen) sin poder escribir nada — ni por UI ni por
-- backend. Nunca se reutiliza un usuario real (nada de "loguearse como
-- vendedora"): esto es un rol nuevo, propio, auditado como cualquier otro.
--
-- AUDITORÍA (antes de tocar código): casi todo lo que hoy ES de solo lectura
-- ya está bien — product_prices/promotions/price_conditions/kit_components/
-- doctors/stock_locations/etc. son SELECT para "is_active_profile()" (activo,
-- cualquier rol) y ESCRITURA exclusiva de is_admin() — un viewer ya queda
-- afuera de esas automáticamente. product_stock_status/kit_availability son
-- vistas security_invoker sobre inventory_balances (RLS por sede, no por
-- rol) — con profile_locations asignado a todas las sedes, un viewer ya ve
-- todo el stock sin tocar nada ahí. Los reportes financieros (dashboard_report/
-- product_revenue_report/doctor_sales_detail) ya gatean por
-- "role = 'admin' OR can_view_financial_reports" — activar ese flag en el
-- perfil del viewer alcanza, sin tocar esas funciones.
--
-- Gaps reales encontrados (lo que este archivo corrige):
--   1) create_sale / cancel_sale / adjust_stock solo validaban "usuario
--      activo" (+ acceso a sede) — NUNCA el rol. Un perfil "viewer" activo
--      podía hoy mismo crear ventas, anularlas o ajustar stock. Se agrega el
--      chequeo de rol explícito que faltaba.
--   2) customers_insert/customers_update (RLS) permitían escribir a
--      "cualquier usuario activo" — mismo gap, ahora exige rol admin/seller.
--   3) sales_select/sale_items_select solo dejaban ver TODAS las ventas de
--      la sede a un admin (una vendedora solo ve las propias) — un viewer
--      necesita ver todas para poder evaluar la gestión real, así que se
--      agrega al lado de is_admin().
--   4) Consecuencia directa del punto 3: si un viewer ve ventas de OTRAS
--      vendedoras, también necesita poder leer el nombre de esas vendedoras
--      (/ventas, /ventas/[id] y /stock/movimientos hacen join contra
--      profiles para mostrar "vendido por"/"registrado por") —
--      profiles_select_own_or_admin hoy solo deja ver la fila propia o, si
--      sos admin, cualquiera. Se agrega is_viewer() al lado de is_admin().

-- ---------------------------------------------------------------------------
-- Helpers de rol (mismo patrón que is_admin()/is_active_profile()).
-- ---------------------------------------------------------------------------
create or replace function public.is_viewer()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.active = true and p.role = 'viewer'
  );
$$;

comment on function public.is_viewer() is
  'Rol de solo lectura (modo observador): ve dashboard/reportes/ventas/stock/clientes '
  'en todas las sedes que tenga asignadas, nunca puede escribir nada.';

create or replace function public.is_active_seller_or_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.active = true and p.role in ('admin', 'seller')
  );
$$;

comment on function public.is_active_seller_or_admin() is
  'Reemplaza a is_active_profile() como gate de ESCRITURA en policies que antes '
  'dejaban pasar a "cualquier usuario activo" — ahora excluye explícitamente al '
  'rol viewer (que sí sigue leyendo vía is_active_profile()).';

-- ---------------------------------------------------------------------------
-- RLS: profiles — un viewer necesita leer el nombre de OTRAS personas
-- (vendedoras) para que las pantallas que hacen join contra profiles
-- ("vendido por", "registrado por") no le muestren vacío. Nunca puede
-- escribir profiles (no toca profiles_update_own_limited/profiles_update_admin).
-- ---------------------------------------------------------------------------
drop policy profiles_select_own_or_admin on public.profiles;
create policy profiles_select_own_or_admin on public.profiles
  for select using (id = auth.uid() or public.is_admin() or public.is_viewer());

-- ---------------------------------------------------------------------------
-- RLS: customers — insert/update eran "cualquier usuario activo" (gap real,
-- ver comentario arriba). La lectura (customers_select) no cambia: un viewer
-- ya podía y debe poder seguir viendo la ficha de clientes.
-- ---------------------------------------------------------------------------
drop policy customers_insert on public.customers;
create policy customers_insert on public.customers
  for insert with check (public.is_active_seller_or_admin());

drop policy customers_update on public.customers;
create policy customers_update on public.customers
  for update using (public.is_active_seller_or_admin())
  with check (public.is_active_seller_or_admin());

-- ---------------------------------------------------------------------------
-- RLS: sales/sale_items — un viewer necesita ver TODAS las ventas de sus
-- sedes (no solo las propias, que es lo que ve hoy una vendedora), igual que
-- un admin. Escritura sigue siendo exclusiva de las RPC (sin policy de
-- insert/update/delete acá, no cambia).
-- ---------------------------------------------------------------------------
drop policy sales_select on public.sales;
create policy sales_select on public.sales
  for select using (
    public.is_active_profile()
    and public.has_location_access(location_id)
    and (public.is_admin() or public.is_viewer() or seller_id = auth.uid())
  );

drop policy sale_items_select on public.sale_items;
create policy sale_items_select on public.sale_items
  for select using (
    exists (
      select 1 from public.sales s
      where s.id = sale_items.sale_id
        and public.has_location_access(s.location_id)
        and (public.is_admin() or public.is_viewer() or s.seller_id = auth.uid())
    )
  );

-- ---------------------------------------------------------------------------
-- create_sale: mismo cuerpo que la versión vigente (20260201000015), con el
-- chequeo de rol que faltaba agregado justo después de validar "activo".
-- ---------------------------------------------------------------------------
create or replace function public.create_sale(
  p_items jsonb,
  p_location_id uuid,
  p_sales_channel_id uuid,
  p_payment_method_id uuid,
  p_customer_id uuid default null,
  p_doctor_id uuid default null,
  p_notes text default null,
  p_external_source text default null,
  p_external_order_id text default null,
  p_sold_at timestamptz default now(),
  p_is_free_sale boolean default false,
  p_free_sale_reason public.free_sale_reason default null,
  p_free_sale_notes text default null,
  p_skip_stock_movement boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede cargar ventas.';
  end if;

  if not public.has_location_access(p_location_id) then
    raise exception 'Tu usuario no tiene acceso a esta sucursal.';
  end if;

  return public.fn_create_sale_core(
    auth.uid(), p_items, p_location_id, p_sales_channel_id, p_payment_method_id,
    p_customer_id, p_doctor_id, p_notes, p_external_source, p_external_order_id, p_sold_at,
    p_is_free_sale, p_free_sale_reason, p_free_sale_notes, p_skip_stock_movement
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- cancel_sale: mismo cuerpo que la versión vigente (Bloque D,
-- 20260201000021), con el chequeo de rol agregado. Sigue siendo
-- admin-o-vendedor (nunca viewer) con acceso a la sede de la venta.
-- ---------------------------------------------------------------------------
create or replace function public.cancel_sale(p_sale_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_sale public.sales;
  v_movement record;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede anular ventas.';
  end if;

  if p_reason is null or trim(p_reason) = '' then
    raise exception 'El motivo de cancelación es obligatorio.';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale is null then
    raise exception 'La venta no existe.';
  end if;

  if v_sale.status = 'cancelled' then
    raise exception 'La venta ya se encuentra anulada.';
  end if;

  if not public.has_location_access(v_sale.location_id) then
    raise exception 'Tu usuario no tiene acceso a la sucursal de esta venta.';
  end if;

  for v_movement in
    select location_id, product_id, quantity_delta
    from public.stock_movements
    where sale_id = p_sale_id and movement_type = 'SALE'
    order by product_id
  loop
    perform public.fn_apply_stock_movement(
      p_location_id => v_movement.location_id,
      p_product_id => v_movement.product_id,
      p_movement_type => 'SALE_CANCEL',
      p_quantity_delta => -v_movement.quantity_delta,
      p_sale_id => v_sale.id,
      p_reference => v_sale.sale_number,
      p_notes => p_reason,
      p_created_by => auth.uid(),
      p_allow_negative => true
    );
  end loop;

  update public.sales
  set status = 'cancelled',
      cancelled_at = now(),
      cancelled_by = auth.uid(),
      cancellation_reason = p_reason
  where id = p_sale_id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (auth.uid(), 'cancel_sale', 'sales', p_sale_id, jsonb_build_object('reason', p_reason));

  return jsonb_build_object('sale_id', p_sale_id, 'status', 'cancelled');
end;
$$;

-- ---------------------------------------------------------------------------
-- adjust_stock: mismo cuerpo vigente (20260101000009), con el chequeo de rol
-- agregado ANTES del de can_adjust_stock — defensa en profundidad: un viewer
-- nunca puede ajustar stock aunque alguien le marque ese flag por error.
-- ---------------------------------------------------------------------------
create or replace function public.adjust_stock(
  p_location_id uuid,
  p_product_id uuid,
  p_quantity_delta numeric,
  p_reason public.stock_adjustment_reason,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_settings public.app_settings;
  v_movement_type public.stock_movement_type;
  v_before numeric;
  v_movement public.stock_movements;
begin
  select * into v_profile from public.profiles where id = auth.uid();

  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar.';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede ajustar stock.';
  end if;

  if not (public.is_admin() or v_profile.can_adjust_stock) then
    raise exception 'Tu usuario no tiene permiso para ajustar stock.';
  end if;

  if not public.has_location_access(p_location_id) then
    raise exception 'Tu usuario no tiene acceso a esta sucursal.';
  end if;

  if p_quantity_delta is null or p_quantity_delta = 0 then
    raise exception 'La cantidad del ajuste no puede ser cero.';
  end if;

  if not exists (select 1 from public.products where id = p_product_id and track_stock = true) then
    raise exception 'Este producto no maneja stock propio.';
  end if;

  select * into v_settings from public.app_settings where id = 1;
  v_movement_type := case when p_quantity_delta > 0 then 'ADJUSTMENT_PLUS' else 'ADJUSTMENT_MINUS' end;

  select coalesce(quantity, 0) into v_before
  from public.inventory_balances
  where location_id = p_location_id and product_id = p_product_id;

  v_movement := public.fn_apply_stock_movement(
    p_location_id => p_location_id,
    p_product_id => p_product_id,
    p_movement_type => v_movement_type,
    p_quantity_delta => p_quantity_delta,
    p_reason => p_reason,
    p_notes => p_notes,
    p_created_by => auth.uid(),
    p_allow_negative => coalesce(v_settings.allow_negative_stock, false)
  );

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'adjust_stock', 'inventory_balances', p_product_id,
    jsonb_build_object(
      'location_id', p_location_id, 'delta', p_quantity_delta, 'reason', p_reason,
      'stock_before', coalesce(v_before, 0), 'stock_after', coalesce(v_before, 0) + p_quantity_delta
    )
  );

  return jsonb_build_object(
    'movement_id', v_movement.id,
    'stock_before', coalesce(v_before, 0),
    'stock_after', coalesce(v_before, 0) + p_quantity_delta
  );
end;
$$;

comment on function public.create_sale is
  'RPC transaccional: valida, recalcula precio, verifica y descuenta stock (expandiendo kits), '
  'calcula comisión sólo sobre líneas commissionable, y persiste venta + detalle + movimientos. '
  'Nunca la puede llamar un perfil viewer (solo lectura).';
comment on function public.cancel_sale is
  'Nunca hace hard delete. Admin o vendedor con acceso a la sede de la venta (nunca viewer). '
  'Revierte exactamente los movimientos SALE originales del ledger.';
comment on function public.adjust_stock is
  'Admin, o vendedor con can_adjust_stock — nunca un perfil viewer, aunque ese flag esté activo.';
