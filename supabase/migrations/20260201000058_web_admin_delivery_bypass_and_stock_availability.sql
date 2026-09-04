-- =============================================================================
-- Maguirejuve · 58 · Circuito Ventas Web — bypass de admin en entrega +
-- disponibilidad comercial (físico - reservado) para Nueva Venta Web
-- =============================================================================
-- Cierre de los dos puntos pendientes que el usuario dejó explícitamente
-- abiertos al aprobar 20260201000057 (permisos de creación + timing de
-- billing_status):
--
-- 1) deliver_web_pickup: ahora admite el MISMO bypass acotado que ya tiene
--    create_sale (057) y mark_web_order_paid (055) — un admin sin la sede de
--    retiro en profile_locations puede marcar como entregado un pickup Web
--    válido de Sede 25 o Sede 37. Acotado EXCLUSIVAMENTE a:
--      - rol admin;
--      - v_sale.fulfillment_type = 'PICKUP' (estructuralmente exclusivo del
--        canal Web — sales_fulfillment_consistency de 20260201000054 nunca
--        deja fulfillment_type no nulo en una venta no-Web);
--      - pickup_location_id con code IN ('SED-25', 'SED-37') (chequeo
--        explícito igual al de 057, aunque ya esté garantizado por el CHECK
--        de la tabla — mismo estilo defensivo que el resto del archivo 057).
--    Un vendedor sigue necesitando has_location_access real: vendedora de
--    Sede 25 puede entregar pickups de Sede 25, nunca de Sede 37. Ninguna
--    otra validación de deliver_web_pickup cambia (pago PAID, no repetir
--    entrega, etc. — todo lo demás queda idéntico a 20260201000055).
--
-- 2) web_admin_stock_availability(p_location_id): nueva RPC de lectura,
--    security definer, admin-only, para alimentar el selector de stock de
--    Nueva Venta Web SIN ampliar RLS general de inventory_balances /
--    product_stock_status / kit_availability (esas vistas y sus políticas
--    de RLS quedan exactamente como están — vendedores y ventas
--    presenciales las siguen usando sin cambios).
--
--    Devuelve, para Sede 25 / Sede 37 / Depósito (las únicas 3 sedes que
--    Web puede usar), disponible = físico - reservas ACTIVE — la MISMA
--    fórmula que ya usa fn_check_available_stock, acá solo LEÍDA (sin lock,
--    sin insertar nada) — y, para kits, la cantidad armable usando ese
--    disponible por componente en vez del físico crudo (misma lógica de
--    fn_kit_buildable_qty, adaptada). Esto además adelanta el pendiente de
--    "Nueva Venta debería mostrar disponible, no físico" — para el flujo
--    Web específicamente, sin tocar el resto de las pantallas.
--
--    Una sola query (dos ramas UNION ALL sobre la misma CTE `reserved`) —
--    nunca un loop por producto, nunca N llamados a la RPC por fila. El
--    admin bajo prueba (sin ninguna sede en profile_locations) puede
--    invocarla igual que cualquier otro admin porque la autorización es
--    interna (is_admin()), nunca depende de RLS de inventory_balances.
--
-- Ambos cambios son additivos — no se modifica 054/055/056/057.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) deliver_web_pickup: agrega el bypass de admin acotado.
-- ---------------------------------------------------------------------------
create or replace function public.deliver_web_pickup(p_sale_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_sale public.sales;
  v_reservation record;
  v_reserved_count int := 0;
  v_expected_count int;
  v_admin_pickup_bypass boolean;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede marcar entregas.';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale is null then
    raise exception 'El pedido no existe.';
  end if;

  if v_sale.fulfillment_type <> 'PICKUP' then
    raise exception 'Este pedido no es un retiro en sede.';
  end if;

  -- Bypass acotado (idéntico en espíritu al de create_sale en 057): un
  -- admin puede entregar cualquier pickup Web válido de Sede 25/37 aunque
  -- no tenga esa sede en profile_locations. Nunca aplica a otros roles, ni
  -- a ningún otro tipo de operación (ventas presenciales/Stock/Movimientos
  -- no llaman esta función). Un vendedor SIEMPRE necesita acceso real.
  v_admin_pickup_bypass :=
    v_profile.role = 'admin'
    and exists (
      select 1 from public.stock_locations sl
      where sl.id = v_sale.pickup_location_id and sl.code in ('SED-25', 'SED-37')
    );

  if not (public.has_location_access(v_sale.pickup_location_id) or v_admin_pickup_bypass) then
    raise exception 'Tu usuario no tiene acceso a la sede de retiro de este pedido.';
  end if;

  if v_sale.status <> 'confirmed' then
    raise exception 'Este pedido no está confirmado (anulado) — no se puede entregar.';
  end if;

  if v_sale.fulfillment_status = 'DELIVERED' then
    raise exception 'Este pedido ya fue entregado (%, por %).', v_sale.delivered_at, v_sale.delivered_by;
  end if;

  if v_sale.fulfillment_status <> 'PENDING_PICKUP' then
    raise exception 'Este pedido no está pendiente de retiro.';
  end if;

  if v_sale.payment_status <> 'PAID' then
    raise exception using
      errcode = 'P1003',
      message = 'Este pedido está pendiente de cobro — hay que cobrarlo antes de entregarlo (mark_web_order_paid).';
  end if;

  select count(*) into v_expected_count from public.sale_items where sale_id = p_sale_id;

  for v_reservation in
    select * from public.sale_stock_reservations
    where sale_id = p_sale_id and status = 'ACTIVE'
    order by product_id
    for update
  loop
    perform public.fn_apply_stock_movement(
      p_location_id => v_reservation.location_id,
      p_product_id => v_reservation.product_id,
      p_movement_type => 'SALE',
      p_quantity_delta => -v_reservation.quantity,
      p_sale_id => p_sale_id,
      p_reference => v_sale.sale_number,
      p_created_by => auth.uid(),
      p_allow_negative => false,
      p_source_sale_item_id => v_reservation.sale_item_id
    );

    update public.sale_stock_reservations
    set status = 'CONSUMED', consumed_at = now()
    where id = v_reservation.id;

    v_reserved_count := v_reserved_count + 1;
  end loop;

  -- Post-chequeo (sección 44 del pedido): tiene que haber consumido al
  -- menos una reserva por cada sale_item con producto trackeable/kit — si
  -- un pedido quedó sin ninguna reserva ACTIVE (dato corrupto/huérfano),
  -- mejor abortar con excepción explícita que "entregar" sin mover nada.
  if v_reserved_count = 0 then
    raise exception 'Este pedido no tiene ninguna reserva de stock activa — no se puede entregar. Contactá a un administrador.';
  end if;

  update public.sales
  set fulfillment_status = 'DELIVERED', delivered_at = now(), delivered_by = auth.uid()
  where id = p_sale_id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'WEB_ORDER_DELIVERED', 'sales', p_sale_id,
    jsonb_build_object(
      'sale_id', p_sale_id, 'location_id', v_sale.pickup_location_id,
      'fulfillment_type', v_sale.fulfillment_type, 'payment_status', v_sale.payment_status,
      'delivered_by', auth.uid(), 'admin_bypass', v_admin_pickup_bypass
    )
  );

  return jsonb_build_object(
    'sale_id', p_sale_id, 'fulfillment_status', 'DELIVERED',
    'delivered_at', now(), 'reservations_consumed', v_reserved_count
  );
end;
$$;

comment on function public.deliver_web_pickup(uuid) is
  'Transacción atómica: lock del pedido + sus reservas, valida sede/estado/cobro, consume cada '
  'reserva ACTIVE generando su SALE real (fn_apply_stock_movement, trazado por source_sale_item_id), '
  'marca DELIVERED + delivered_at/by, audita WEB_ORDER_DELIVERED. Cualquier excepción revierte todo '
  '(nada de stock descontado a medias). Exige payment_status=PAID — nunca entrega sin cobro resuelto. '
  'Un admin puede entregar cualquier pickup Web válido de Sede 25/37 sin necesitar esa sede en '
  'profile_locations (bypass acotado, 20260201000058) — un vendedor siempre necesita acceso real.';

-- ---------------------------------------------------------------------------
-- 2) web_admin_stock_availability: disponibilidad comercial (físico -
--    reservado) de Sede 25 / Sede 37 / Depósito, para Nueva Venta Web.
-- ---------------------------------------------------------------------------
create or replace function public.web_admin_stock_availability(p_location_id uuid default null)
returns table (
  location_id uuid,
  location_code text,
  product_id uuid,
  is_kit boolean,
  available numeric,
  status text
)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede consultar disponibilidad para Ventas Web.';
  end if;

  return query
  with web_locations as (
    select sl.id, sl.code
    from public.stock_locations sl
    where sl.code in ('SED-25', 'SED-37', 'DEP')
      and (p_location_id is null or sl.id = p_location_id)
  ),
  reserved as (
    select ssr.location_id, ssr.product_id, sum(ssr.quantity) as reserved_qty
    from public.sale_stock_reservations ssr
    where ssr.status = 'ACTIVE'
    group by ssr.location_id, ssr.product_id
  ),
  simple_products as (
    select
      wl.id as location_id,
      wl.code as location_code,
      p.id as product_id,
      false as is_kit,
      coalesce(ib.quantity, 0) - coalesce(r.reserved_qty, 0) as available,
      coalesce(ib.min_stock_override, p.default_min_stock) as min_stock
    from public.products p
    cross join web_locations wl
    left join public.inventory_balances ib on ib.product_id = p.id and ib.location_id = wl.id
    left join reserved r on r.product_id = p.id and r.location_id = wl.id
    where p.track_stock = true and p.active = true
  ),
  kits as (
    select
      wl.id as location_id,
      wl.code as location_code,
      k.id as product_id,
      true as is_kit,
      coalesce(
        min(floor((coalesce(ib.quantity, 0) - coalesce(r.reserved_qty, 0)) / kc.quantity)),
        0
      ) as available
    from public.products k
    cross join web_locations wl
    join public.kit_components kc on kc.kit_product_id = k.id
    left join public.inventory_balances ib
      on ib.product_id = kc.component_product_id and ib.location_id = wl.id
    left join reserved r
      on r.product_id = kc.component_product_id and r.location_id = wl.id
    where k.active = true
    group by wl.id, wl.code, k.id
  )
  select
    sp.location_id, sp.location_code, sp.product_id, sp.is_kit, sp.available,
    case
      when sp.available <= 0 then 'sin_stock'
      when sp.available <= sp.min_stock then 'bajo'
      else 'ok'
    end as status
  from simple_products sp

  union all

  select
    kt.location_id, kt.location_code, kt.product_id, kt.is_kit, kt.available,
    null::text as status
  from kits kt;
end;
$$;

comment on function public.web_admin_stock_availability(uuid) is
  'Solo admin (is_admin(), chequeo interno — nunca depende de RLS). Disponible = físico - reservas '
  'ACTIVE (misma fórmula que fn_check_available_stock), para Sede 25/Sede 37/Depósito únicamente — '
  'las 3 sedes que Ventas Web puede usar. Kits: armable usando ese disponible por componente (misma '
  'lógica de fn_kit_buildable_qty). Una sola query (CTE reserved compartida), sin loops por producto. '
  'No modifica RLS de inventory_balances/product_stock_status/kit_availability — esas vistas y '
  'vendedores/ventas presenciales siguen exactamente igual. Pensada para alimentar Nueva Venta Web '
  'cuando el admin que la usa no tiene la sede en profile_locations (20260201000057 ya le permite '
  'crear la venta; esta RPC evita que la vea con stock vacío por RLS).';
