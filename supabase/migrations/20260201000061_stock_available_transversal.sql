-- =============================================================================
-- Maguirejuve · 61 · BLOQUE F — Stock disponible transversal
-- =============================================================================
-- Auditoría previa (ver informe entregado al usuario) confirmó que el
-- camino general de creación de ventas (fn_create_sale_core, rama no-PICKUP
-- — presenciales y SHIPPING) YA es reservation-aware desde BLOQUE B (055):
-- llama fn_check_available_stock antes de fn_apply_stock_movement. Ese
-- camino NO se toca acá. Lo que sí encontró la auditoría:
--
--   1) create_sale_exchange: el descuento del producto NUEVO llamaba
--      fn_apply_stock_movement directo, SIN fn_check_available_stock previo
--      — gap real de integridad (un cambio podía entregar una unidad
--      comprometida para un pickup Web pendiente). Se corrige acá.
--   2) transfer_stock: sin protección — un admin podía transferir stock
--      físicamente presente pero reservado, dejando "disponible" negativo
--      en origen. Se agrega un guard duro (fn_check_available_stock en la
--      sede de origen, SIEMPRE, sin importar allow_transfer_overdraft —
--      ese setting es sobre permitir físico negativo por flexibilidad
--      operativa, un eje distinto de "no romper una promesa ya hecha a un
--      cliente Web").
--   3) Todo el resto era un gap de VISUALIZACIÓN (el backend general ya
--      protegía la operación real, pero las pantallas mostraban físico
--      crudo, lo que podía llevar a un rechazo evitable al confirmar):
--      product_stock_status gana columnas ADITIVAS (reserved/available/
--      available_status — quantity/status NUNCA se tocan, siguen siendo el
--      físico crudo para /stock, el CSV de inventario y set-stock-dialog,
--      que deliberadamente quedan fuera de este bloque). kit_availability.
--      buildable_qty pasa a ser reservation-aware EN EL LUGAR (fn_
--      kit_buildable_qty) — a diferencia de un producto simple, "armable"
--      ya era un valor derivado sin significado "solo físico" que preservar.
--
-- Nueva Venta Web sigue usando web_admin_stock_availability (058) —
-- ninguna de las 2 vistas de acá reemplaza esa RPC, que existe por el
-- motivo estructural distinto de admin-sin-profile_locations.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) product_stock_status: agrega reserved/available/available_status.
--    quantity/status quedan exactamente iguales — /stock, el CSV de
--    inventario y set-stock-dialog los siguen usando sin ningún cambio.
-- ---------------------------------------------------------------------------
create or replace view public.product_stock_status
with (security_invoker = true) as
select
  p.id as product_id,
  p.sku,
  p.name,
  p.category,
  sl.id as location_id,
  sl.code as location_code,
  coalesce(ib.quantity, 0) as quantity,
  coalesce(ib.min_stock_override, p.default_min_stock) as min_stock,
  case
    when coalesce(ib.quantity, 0) <= 0 then 'sin_stock'
    when coalesce(ib.quantity, 0) <= coalesce(ib.min_stock_override, p.default_min_stock) then 'bajo'
    else 'ok'
  end as status,
  p.active as product_active,
  coalesce(res.reserved_qty, 0) as reserved,
  coalesce(ib.quantity, 0) - coalesce(res.reserved_qty, 0) as available,
  case
    when coalesce(ib.quantity, 0) - coalesce(res.reserved_qty, 0) <= 0 then 'sin_stock'
    when coalesce(ib.quantity, 0) - coalesce(res.reserved_qty, 0) <= coalesce(ib.min_stock_override, p.default_min_stock) then 'bajo'
    else 'ok'
  end as available_status
from public.products p
cross join public.stock_locations sl
left join public.inventory_balances ib on ib.product_id = p.id and ib.location_id = sl.id
left join lateral (
  select sum(ssr.quantity) as reserved_qty
  from public.sale_stock_reservations ssr
  where ssr.location_id = sl.id and ssr.product_id = p.id and ssr.status = 'ACTIVE'
) res on true
where p.track_stock = true;

comment on view public.product_stock_status is
  'Estado de stock por sede y producto trackeable. quantity/status = físico crudo, SIN CAMBIOS '
  '(así siguen /stock, el CSV de inventario y set-stock-dialog — verdad física real, deliberado). '
  'reserved/available/available_status son columnas ADITIVAS (BLOQUE F, 20260201000061): '
  'available = quantity - reservas ACTIVE de sale_stock_reservations. Nueva Venta (ambas ramas), '
  'Cambios/Devoluciones y Home usan available/available_status. Los kits usan kit_availability.';

-- ---------------------------------------------------------------------------
-- 2) fn_kit_buildable_qty: pasa a usar disponible real por componente
--    (físico del componente - reservas ACTIVE del componente), no el físico
--    crudo. Único consumidor: kit_availability (20260101000013) — ningún
--    otro lugar del sistema llama esta función, así que modificarla en el
--    lugar no tiene efectos colaterales que documentar aparte.
-- ---------------------------------------------------------------------------
create or replace function public.fn_kit_buildable_qty(p_kit_product_id uuid, p_location_id uuid)
returns numeric
language sql
stable
as $$
  select coalesce(
    min(
      floor(
        (
          coalesce(ib.quantity, 0)
          - coalesce(
              (
                select sum(ssr.quantity)
                from public.sale_stock_reservations ssr
                where ssr.location_id = p_location_id
                  and ssr.product_id = kc.component_product_id
                  and ssr.status = 'ACTIVE'
              ),
              0
            )
        ) / kc.quantity
      )
    ),
    0
  )
  from public.kit_components kc
  left join public.inventory_balances ib
    on ib.product_id = kc.component_product_id and ib.location_id = p_location_id
  where kc.kit_product_id = p_kit_product_id;
$$;

comment on function public.fn_kit_buildable_qty(uuid, uuid) is
  'Cuántas unidades del kit se pueden armar HOY con lo realmente disponible (físico - reservas '
  'ACTIVE) de cada componente en esa sede — BLOQUE F (20260201000061). A diferencia de un producto '
  'simple, "armable" ya era un valor derivado sin un "solo físico" que preservar para auditoría, '
  'así que se corrige en el lugar (único consumidor: kit_availability). Devuelve 0 si el kit no '
  'tiene componentes cargados.';

-- ---------------------------------------------------------------------------
-- 3) create_sale_exchange: agrega fn_check_available_stock antes de
--    descontar el producto NUEVO — mismo patrón que fn_create_sale_core
--    (055). Todo lo demás es exactamente 20260201000055, sin cambios.
-- ---------------------------------------------------------------------------
create or replace function public.create_sale_exchange(
  p_original_sale_id uuid,
  p_returned_sale_item_id uuid,
  p_returned_quantity numeric,
  p_new_product_id uuid,
  p_new_quantity numeric,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_sale public.sales;
  v_returned_item public.sale_items;
  v_new_product public.products;
  v_physical_source_id uuid;
  v_root_quantity numeric;
  v_root_sale_id uuid;
  v_has_traced_movements boolean;
  v_movement record;
  v_reversal_qty numeric;
  v_reversal_count integer;
  v_price jsonb;
  v_recognized_value numeric;
  v_new_line_total numeric;
  v_difference numeric;
  v_difference_direction public.sale_exchange_direction;
  v_payment_method_code text;
  v_requires_billing boolean;
  v_replacement_billing_status public.sale_billing_status;
  v_difference_settlement_status public.sale_settlement_status;
  v_settings public.app_settings;
  v_allow_negative boolean;
  v_remaining_qty numeric;
  v_lines jsonb := '[]'::jsonb;
  v_line jsonb;
  v_item record;
  v_subtotal numeric := 0;
  v_discount_total numeric := 0;
  v_surcharge_total numeric := 0;
  v_total numeric := 0;
  v_commission_percent numeric := 0;
  v_commission_total numeric := 0;
  v_replacement_sale_id uuid;
  v_replacement_sale_number text;
  v_new_line_item_id uuid;
  v_new_sale_item_id uuid;
  v_exchange_id uuid;
  v_required record;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede hacer cambios de producto.';
  end if;

  if p_returned_quantity is null or p_returned_quantity <= 0 then
    raise exception 'La cantidad devuelta tiene que ser mayor a 0.';
  end if;

  if p_new_quantity is null or p_new_quantity <= 0 then
    raise exception 'La cantidad del producto nuevo tiene que ser mayor a 0.';
  end if;

  select * into v_sale from public.sales where id = p_original_sale_id for update;

  if v_sale is null then
    raise exception 'La venta original no existe.';
  end if;

  if v_sale.status <> 'confirmed' then
    raise exception 'Esta venta no está confirmada (anulada o ya reemplazada por otro cambio) — no se puede volver a usar como origen de un cambio.';
  end if;

  if v_sale.fulfillment_status = 'PENDING_PICKUP' then
    raise exception 'Esta venta es un pedido Web todavía pendiente de retiro — no se puede hacer un cambio hasta que se entregue.';
  end if;

  if not public.has_location_access(v_sale.location_id) then
    raise exception 'Tu usuario no tiene acceso a la sucursal de esta venta.';
  end if;

  if v_sale.is_free_sale then
    raise exception 'No se puede hacer un cambio sobre una entrega sin costo.';
  end if;

  if v_sale.customer_id is null then
    raise exception 'La venta original no tiene un cliente identificado — no se puede hacer un cambio.';
  end if;

  select * into v_returned_item
  from public.sale_items
  where id = p_returned_sale_item_id
  for update;

  if v_returned_item is null or v_returned_item.sale_id <> p_original_sale_id then
    raise exception 'El producto a devolver no pertenece a esta venta.';
  end if;

  if p_returned_quantity > v_returned_item.quantity then
    raise exception
      'No podés devolver % unidades: esta línea solo tiene % disponibles (ya se descontó cualquier cambio anterior).',
      p_returned_quantity, v_returned_item.quantity;
  end if;

  select * into v_new_product from public.products where id = p_new_product_id and active = true;
  if v_new_product is null then
    raise exception 'El producto nuevo no existe o está inactivo.';
  end if;

  v_physical_source_id := coalesce(v_returned_item.physical_source_sale_item_id, v_returned_item.id);
  select quantity, sale_id into v_root_quantity, v_root_sale_id
  from public.sale_items where id = v_physical_source_id;

  v_price := public.fn_exchange_new_item_price(p_new_product_id, p_new_quantity, v_sale.payment_method_id, now());
  if not (v_price ->> 'ok')::boolean then
    raise exception '%', v_price ->> 'error_message';
  end if;

  v_recognized_value := round(v_returned_item.sale_unit_price * p_returned_quantity, 2);
  v_new_line_total := (v_price ->> 'line_total')::numeric;
  v_difference := round(v_new_line_total - v_recognized_value, 2);
  v_difference_direction := case
    when v_difference > 0 then 'CUSTOMER_PAYS'
    when v_difference < 0 then 'BUSINESS_REFUNDS'
    else 'NONE'
  end;

  select code into v_payment_method_code from public.payment_methods where id = v_sale.payment_method_id;
  v_requires_billing := v_payment_method_code in ('TRANSFER', 'CARD_1', 'CARD_3');

  if not v_requires_billing then
    v_replacement_billing_status := 'NOT_REQUIRED';
    v_difference_settlement_status := 'NOT_REQUIRED';
  elsif v_sale.billing_status = 'INVOICED' then
    v_replacement_billing_status := 'INVOICED';
    v_difference_settlement_status := case when v_difference <> 0 then 'PENDING' else 'NOT_REQUIRED' end;
  else
    v_replacement_billing_status := 'PENDING';
    v_difference_settlement_status := 'NOT_REQUIRED';
  end if;

  select * into v_settings from public.app_settings where id = 1;
  v_allow_negative := coalesce(v_settings.allow_negative_stock, false);

  for v_item in
    select * from public.sale_items where sale_id = p_original_sale_id and id <> p_returned_sale_item_id
  loop
    v_lines := v_lines || jsonb_build_object(
      'role', 'copy',
      'product_id', v_item.product_id,
      'quantity', v_item.quantity,
      'list_unit_price', v_item.list_unit_price,
      'sale_unit_price', v_item.sale_unit_price,
      'line_list_total', v_item.line_list_total,
      'line_discount', round(greatest((v_item.list_unit_price - v_item.sale_unit_price) * v_item.quantity, 0), 2),
      'line_surcharge', round(greatest((v_item.sale_unit_price - v_item.list_unit_price) * v_item.quantity, 0), 2),
      'line_total', v_item.line_total,
      'applied_price_condition_id', v_item.applied_price_condition_id,
      'commissionable', v_item.commissionable,
      'applied_promotion_id', v_item.applied_promotion_id,
      'promotion_discount', v_item.promotion_discount,
      'promotion_name_snapshot', v_item.promotion_name_snapshot,
      'promotion_type_snapshot', v_item.promotion_type_snapshot,
      'promotion_discount_percent_snapshot', v_item.promotion_discount_percent_snapshot,
      'promotion_started_at_snapshot', v_item.promotion_started_at_snapshot,
      'promotion_ended_at_snapshot', v_item.promotion_ended_at_snapshot,
      'physical_source_sale_item_id', coalesce(v_item.physical_source_sale_item_id, v_item.id)
    );
  end loop;

  v_remaining_qty := v_returned_item.quantity - p_returned_quantity;
  if v_remaining_qty > 0 then
    v_lines := v_lines || jsonb_build_object(
      'role', 'remainder',
      'product_id', v_returned_item.product_id,
      'quantity', v_remaining_qty,
      'list_unit_price', v_returned_item.list_unit_price,
      'sale_unit_price', v_returned_item.sale_unit_price,
      'line_list_total', round(v_returned_item.list_unit_price * v_remaining_qty, 2),
      'line_discount', round(greatest((v_returned_item.list_unit_price - v_returned_item.sale_unit_price) * v_remaining_qty, 0), 2),
      'line_surcharge', round(greatest((v_returned_item.sale_unit_price - v_returned_item.list_unit_price) * v_remaining_qty, 0), 2),
      'line_total', round(v_returned_item.sale_unit_price * v_remaining_qty, 2),
      'applied_price_condition_id', v_returned_item.applied_price_condition_id,
      'commissionable', v_returned_item.commissionable,
      'applied_promotion_id', v_returned_item.applied_promotion_id,
      'promotion_discount', 0,
      'promotion_name_snapshot', v_returned_item.promotion_name_snapshot,
      'promotion_type_snapshot', v_returned_item.promotion_type_snapshot,
      'promotion_discount_percent_snapshot', v_returned_item.promotion_discount_percent_snapshot,
      'promotion_started_at_snapshot', v_returned_item.promotion_started_at_snapshot,
      'promotion_ended_at_snapshot', v_returned_item.promotion_ended_at_snapshot,
      'physical_source_sale_item_id', v_physical_source_id
    );
  end if;

  v_lines := v_lines || jsonb_build_object(
    'role', 'new',
    'product_id', p_new_product_id,
    'quantity', p_new_quantity,
    'list_unit_price', (v_price ->> 'list_unit_price')::numeric,
    'sale_unit_price', (v_price ->> 'sale_unit_price')::numeric,
    'line_list_total', (v_price ->> 'line_list_total')::numeric,
    'line_discount', (v_price ->> 'line_discount')::numeric,
    'line_surcharge', (v_price ->> 'line_surcharge')::numeric,
    'line_total', v_new_line_total,
    'applied_price_condition_id', (v_price ->> 'applied_price_condition_id')::uuid,
    'commissionable', v_new_product.commissionable,
    'applied_promotion_id', null,
    'promotion_discount', 0,
    'promotion_name_snapshot', null,
    'promotion_type_snapshot', null,
    'promotion_discount_percent_snapshot', null,
    'promotion_started_at_snapshot', null,
    'promotion_ended_at_snapshot', null,
    'physical_source_sale_item_id', null
  );

  select
    coalesce(sum((elem ->> 'line_list_total')::numeric), 0),
    coalesce(sum((elem ->> 'line_discount')::numeric), 0),
    coalesce(sum((elem ->> 'line_surcharge')::numeric), 0),
    coalesce(sum((elem ->> 'line_total')::numeric), 0)
  into v_subtotal, v_discount_total, v_surcharge_total, v_total
  from jsonb_array_elements(v_lines) elem;

  if v_sale.doctor_id is not null then
    select commission_percent into v_commission_percent from public.doctors where id = v_sale.doctor_id;
  end if;

  select coalesce(sum((elem ->> 'line_total')::numeric), 0)
  into v_commission_total
  from jsonb_array_elements(v_lines) elem
  where (elem ->> 'commissionable')::boolean = true;

  v_commission_total := round(v_commission_total * v_commission_percent, 2);

  v_replacement_sale_number := public.fn_next_sale_number(v_sale.location_id, now());

  insert into public.sales (
    sale_number, sold_at, location_id, sales_channel_id, seller_id,
    customer_id, doctor_id, payment_method_id, applied_price_condition_id,
    subtotal, discount_total, surcharge_total, total, commission_total, status,
    notes, payment_account_id, billing_status, invoiced_at, invoiced_by, replaces_sale_id
  ) values (
    v_replacement_sale_number, now(), v_sale.location_id, v_sale.sales_channel_id, auth.uid(),
    v_sale.customer_id, v_sale.doctor_id, v_sale.payment_method_id, null,
    v_subtotal, v_discount_total, v_surcharge_total, v_total, v_commission_total, 'confirmed',
    p_notes, v_sale.payment_account_id, v_replacement_billing_status,
    case when v_replacement_billing_status = 'INVOICED' then now() end,
    case when v_replacement_billing_status = 'INVOICED' then auth.uid() end,
    p_original_sale_id
  )
  returning id into v_replacement_sale_id;

  for v_line in select * from jsonb_array_elements(v_lines)
  loop
    insert into public.sale_items (
      sale_id, product_id, quantity, list_unit_price, sale_unit_price,
      line_list_total, line_discount, line_surcharge, line_total, applied_price_condition_id, commissionable,
      applied_promotion_id, promotion_discount, physical_source_sale_item_id,
      promotion_name_snapshot, promotion_type_snapshot, promotion_discount_percent_snapshot,
      promotion_started_at_snapshot, promotion_ended_at_snapshot
    ) values (
      v_replacement_sale_id,
      (v_line ->> 'product_id')::uuid,
      (v_line ->> 'quantity')::numeric,
      (v_line ->> 'list_unit_price')::numeric,
      (v_line ->> 'sale_unit_price')::numeric,
      (v_line ->> 'line_list_total')::numeric,
      (v_line ->> 'line_discount')::numeric,
      (v_line ->> 'line_surcharge')::numeric,
      (v_line ->> 'line_total')::numeric,
      nullif(v_line ->> 'applied_price_condition_id', '')::uuid,
      (v_line ->> 'commissionable')::boolean,
      nullif(v_line ->> 'applied_promotion_id', '')::uuid,
      coalesce((v_line ->> 'promotion_discount')::numeric, 0),
      nullif(v_line ->> 'physical_source_sale_item_id', '')::uuid,
      v_line ->> 'promotion_name_snapshot',
      nullif(v_line ->> 'promotion_type_snapshot', '')::public.promotion_type,
      nullif(v_line ->> 'promotion_discount_percent_snapshot', '')::numeric,
      nullif(v_line ->> 'promotion_started_at_snapshot', '')::timestamptz,
      nullif(v_line ->> 'promotion_ended_at_snapshot', '')::timestamptz
    )
    returning id into v_new_sale_item_id;

    if v_line ->> 'role' = 'new' then
      v_new_line_item_id := v_new_sale_item_id;
    end if;
  end loop;

  select exists(
    select 1 from public.stock_movements
    where movement_type = 'SALE' and source_sale_item_id = v_physical_source_id
  ) into v_has_traced_movements;

  v_reversal_count := 0;
  for v_movement in
    select location_id, product_id, quantity_delta
    from public.stock_movements
    where movement_type = 'SALE'
      and (
        (v_has_traced_movements and source_sale_item_id = v_physical_source_id)
        or (not v_has_traced_movements and sale_id = v_root_sale_id and source_sale_item_id is null)
      )
    order by product_id
  loop
    v_reversal_qty := round(p_returned_quantity * abs(v_movement.quantity_delta) / v_root_quantity, 2);
    if v_reversal_qty is null or v_reversal_qty <= 0 then
      raise exception
        'No se pudo calcular una cantidad válida de reintegro de stock para el producto % (cantidad devuelta %, movimiento original % en cantidad raíz %) — resultado: %. Se aborta el cambio completo: no se descuenta el producto nuevo ni se reintegra nada.',
        v_movement.product_id, p_returned_quantity, v_movement.quantity_delta, v_root_quantity, v_reversal_qty;
    end if;
    perform public.fn_apply_stock_movement(
      p_location_id => v_movement.location_id,
      p_product_id => v_movement.product_id,
      p_movement_type => 'RETURN',
      p_quantity_delta => v_reversal_qty,
      p_sale_id => p_original_sale_id,
      p_reference => v_sale.sale_number,
      p_notes => format('Cambio %s', v_replacement_sale_number),
      p_created_by => auth.uid(),
      p_allow_negative => true,
      p_source_sale_item_id => v_physical_source_id
    );
    v_reversal_count := v_reversal_count + 1;
  end loop;

  if v_reversal_count = 0 then
    raise exception
      'No se encontró ningún movimiento de stock original para reintegrar (línea raíz %, venta raíz %) — la línea devuelta no tiene historial de stock rastreable. Se aborta el cambio completo en vez de continuar sin reintegrar nada.',
      v_physical_source_id, v_root_sale_id;
  end if;

  for v_required in
    with items as (
      select v_new_line_item_id as sale_item_id, p_new_product_id as product_id, p_new_quantity as quantity
    ),
    expanded as (
      select i.sale_item_id, i.product_id, i.quantity as required_qty
      from items i
      join public.products p on p.id = i.product_id and p.track_stock = true
      union all
      select i.sale_item_id, kc.component_product_id, i.quantity * kc.quantity as required_qty
      from items i
      join public.products p on p.id = i.product_id and p.track_stock = false
      join public.kit_components kc on kc.kit_product_id = i.product_id
    )
    select sale_item_id, product_id, sum(required_qty) as required_qty
    from expanded
    group by sale_item_id, product_id
  loop
    -- BLOQUE F (61): antes de descontar, valida disponible = físico -
    -- reservas ACTIVE (mismo fn_check_available_stock que ya usa
    -- fn_create_sale_core desde 055) — un cambio no puede entregar una
    -- unidad comprometida para un pickup Web pendiente.
    perform public.fn_check_available_stock(
      v_sale.location_id, v_required.product_id, v_required.required_qty, v_allow_negative
    );
    perform public.fn_apply_stock_movement(
      p_location_id => v_sale.location_id,
      p_product_id => v_required.product_id,
      p_movement_type => 'SALE',
      p_quantity_delta => -v_required.required_qty,
      p_sale_id => v_replacement_sale_id,
      p_reference => v_replacement_sale_number,
      p_created_by => auth.uid(),
      p_allow_negative => v_allow_negative,
      p_source_sale_item_id => v_required.sale_item_id
    );
  end loop;

  update public.sales set status = 'replaced' where id = p_original_sale_id;

  insert into public.sale_exchanges (
    original_sale_id, replacement_sale_id, difference_amount, difference_direction,
    difference_settlement_status, notes, created_by
  ) values (
    p_original_sale_id, v_replacement_sale_id, v_difference, v_difference_direction,
    v_difference_settlement_status, p_notes, auth.uid()
  )
  returning id into v_exchange_id;

  insert into public.sale_exchange_items (
    exchange_id, direction, source_sale_item_id, product_id, quantity, unit_price, line_total
  ) values
    (v_exchange_id, 'RETURNED', p_returned_sale_item_id, v_returned_item.product_id,
      p_returned_quantity, v_returned_item.sale_unit_price, v_recognized_value),
    (v_exchange_id, 'ADDED', null, p_new_product_id,
      p_new_quantity, (v_price ->> 'sale_unit_price')::numeric, v_new_line_total);

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'SALE_EXCHANGE_CREATED', 'sales', v_replacement_sale_id,
    jsonb_build_object(
      'original_sale_id', p_original_sale_id,
      'replacement_sale_id', v_replacement_sale_id,
      'customer_id', v_sale.customer_id,
      'returned_product_id', v_returned_item.product_id,
      'returned_quantity', p_returned_quantity,
      'new_product_id', p_new_product_id,
      'new_quantity', p_new_quantity,
      'difference_amount', v_difference,
      'difference_direction', v_difference_direction,
      'payment_method_id', v_sale.payment_method_id,
      'location_id', v_sale.location_id
    )
  );

  return jsonb_build_object(
    'exchange_id', v_exchange_id,
    'original_sale_id', p_original_sale_id,
    'sale_id', v_replacement_sale_id,
    'sale_number', v_replacement_sale_number,
    'total', v_total,
    'surcharge_total', v_surcharge_total,
    'recognized_value', v_recognized_value,
    'new_item_total', v_new_line_total,
    'difference_amount', v_difference,
    'difference_direction', v_difference_direction,
    'billing_status', v_replacement_billing_status,
    'difference_settlement_status', v_difference_settlement_status
  );
end;
$$;

comment on function public.create_sale_exchange(uuid, uuid, numeric, uuid, numeric, text) is
  'Cambio de producto. BLOQUE F (61): antes de descontar el producto nuevo, valida disponible '
  '(fn_check_available_stock — físico - reservas ACTIVE), igual que ya hace fn_create_sale_core '
  'desde 055 — un cambio no puede entregar una unidad comprometida para un pickup Web pendiente. '
  'BUGFIX 55 (guard PENDING_PICKUP) y todo lo demás siguen exactamente igual.';

-- ---------------------------------------------------------------------------
-- 4) transfer_stock: agrega un guard duro — no se puede transferir más que
--    el disponible de la sede de origen. SIEMPRE se aplica, sin importar
--    allow_transfer_overdraft (ese setting es sobre permitir físico
--    negativo por flexibilidad operativa; esto es sobre no romper una
--    reserva ya comprometida con un cliente Web — ejes distintos).
--    set_stock/adjust_stock NO se tocan en este bloque — siguen siendo
--    operaciones administrativas sobre el físico real, deliberadamente.
--    Riesgo documentado: un admin puede seguir corrigiendo el físico con
--    set_stock/adjust_stock a un valor por debajo de lo reservado (ninguna
--    de las 2 valida contra reservas) — es una inconsistencia posible,
--    pero deliberada: son herramientas de corrección administrativa
--    (stock físico real, ej. rotura/vencimiento/recepción), no ventas, y
--    limitarlas ahí podría bloquear una corrección legítima. Si en el
--    futuro se decide blindarlas también, es un bloque aparte.
-- ---------------------------------------------------------------------------
create or replace function public.transfer_stock(
  p_from_location_id uuid,
  p_to_location_id uuid,
  p_items jsonb, -- [{"product_id": uuid, "quantity": number}]
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings public.app_settings;
  v_transfer_id uuid;
  v_transfer_number text;
  v_seq int;
  v_item record;
begin
  if not public.is_admin() then
    raise exception 'Tu usuario no tiene permiso para transferir stock.';
  end if;

  if p_from_location_id = p_to_location_id then
    raise exception 'La sede de origen y destino no pueden ser la misma.';
  end if;

  if not (public.has_location_access(p_from_location_id) and public.has_location_access(p_to_location_id)) then
    raise exception 'Tu usuario no tiene acceso a alguna de las sedes involucradas.';
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'La transferencia no tiene productos.';
  end if;

  select * into v_settings from public.app_settings where id = 1;

  perform pg_advisory_xact_lock(hashtext('stock_transfer_number'));
  select count(*) + 1 into v_seq
  from public.stock_transfers
  where created_at::date = (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_transfer_number := format('TRF-%s-%s', to_char(now(), 'YYYYMMDD'), lpad(v_seq::text, 4, '0'));

  insert into public.stock_transfers (transfer_number, from_location_id, to_location_id, notes, created_by)
  values (v_transfer_number, p_from_location_id, p_to_location_id, p_notes, auth.uid())
  returning id into v_transfer_id;

  for v_item in
    select (elem ->> 'product_id')::uuid as product_id, (elem ->> 'quantity')::numeric as quantity
    from jsonb_array_elements(p_items) elem
    order by (elem ->> 'product_id')::uuid
  loop
    if v_item.quantity is null or v_item.quantity <= 0 then
      raise exception 'Cantidad inválida en la transferencia.';
    end if;

    if not exists (select 1 from public.products where id = v_item.product_id and track_stock = true) then
      raise exception 'Solo se pueden transferir productos con stock propio (no kits).';
    end if;

    -- BLOQUE F (61): no se puede dejar la sede de origen con disponible
    -- negativo — nunca se pasa allow_negative acá, a propósito (ver
    -- comentario del bloque de arriba).
    perform public.fn_check_available_stock(p_from_location_id, v_item.product_id, v_item.quantity, false);

    insert into public.stock_transfer_items (transfer_id, product_id, quantity)
    values (v_transfer_id, v_item.product_id, v_item.quantity);

    perform public.fn_apply_stock_movement(
      p_location_id => p_from_location_id,
      p_product_id => v_item.product_id,
      p_movement_type => 'TRANSFER_OUT',
      p_quantity_delta => -v_item.quantity,
      p_transfer_id => v_transfer_id,
      p_reference => v_transfer_number,
      p_created_by => auth.uid(),
      p_allow_negative => coalesce(v_settings.allow_transfer_overdraft, false)
    );

    perform public.fn_apply_stock_movement(
      p_location_id => p_to_location_id,
      p_product_id => v_item.product_id,
      p_movement_type => 'TRANSFER_IN',
      p_quantity_delta => v_item.quantity,
      p_transfer_id => v_transfer_id,
      p_reference => v_transfer_number,
      p_created_by => auth.uid(),
      p_allow_negative => true
    );
  end loop;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (auth.uid(), 'transfer_stock', 'stock_transfers', v_transfer_id,
          jsonb_build_object('from', p_from_location_id, 'to', p_to_location_id, 'items', p_items));

  return jsonb_build_object('transfer_id', v_transfer_id, 'transfer_number', v_transfer_number);
end;
$$;

comment on function public.transfer_stock(uuid, uuid, jsonb, text) is
  'Transferencia de stock entre sedes (admin). BLOQUE F (61): antes de descontar en origen, valida '
  'disponible (fn_check_available_stock, SIEMPRE sin allow_negative — nunca se puede dejar la sede '
  'de origen con disponible negativo, sin importar allow_transfer_overdraft, que solo permite '
  'físico negativo por flexibilidad operativa, un eje distinto). set_stock/adjust_stock siguen sin '
  'validar contra reservas — operaciones administrativas deliberadas sobre el físico real.';

grant execute on function public.transfer_stock(uuid, uuid, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5) dashboard_report.critical_stock_count: pasa a contar sobre disponible
--    (available_status), no físico crudo — un producto con reservas ACTIVE
--    que agotan el disponible es una alerta operativa real aunque el
--    físico todavía diga "ok". Misma firma exacta que 20260201000056 —
--    CREATE OR REPLACE sin DROP, el resto del cuerpo es idéntico.
-- ---------------------------------------------------------------------------
create or replace function public.dashboard_report(
  p_from date,
  p_to date,
  p_location_id uuid default null,
  p_sales_channel_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_from timestamptz;
  v_to timestamptz;
begin
  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or not v_profile.active then
    raise exception 'Tu usuario no tiene permiso para ver este reporte.';
  end if;
  if not (v_profile.role = 'admin' or v_profile.can_view_financial_reports) then
    raise exception 'Tu usuario no tiene permiso para ver reportes financieros.';
  end if;

  v_from := (p_from::text || ' 00:00:00-03')::timestamptz;
  v_to := (p_to::text || ' 23:59:59-03')::timestamptz;

  return jsonb_build_object(
    'kpis', (
      select jsonb_build_object(
        'sales_count', count(*),
        'revenue', coalesce(sum(sn.net_total), 0),
        'avg_ticket', coalesce(round(avg(sn.net_total), 2), 0),
        'units_sold', coalesce(sum(sn.net_units), 0),
        'web_sales_count', coalesce(sum(case when sc.code = 'WEB' then 1 else 0 end), 0),
        'commission_total', coalesce(sum(
          case when sn.gross_commissionable > 0
            then round(s.commission_total * sn.net_commissionable / sn.gross_commissionable, 2)
            else 0 end
        ), 0)
      )
      from public.sales s
      join public.sales_channels sc on sc.id = s.sales_channel_id
      join lateral (
        select
          coalesce(sum(net_line_total), 0) as net_total,
          coalesce(sum(net_quantity), 0) as net_units,
          coalesce(sum(case when commissionable then gross_line_total else 0 end), 0) as gross_commissionable,
          coalesce(sum(case when commissionable then net_line_total else 0 end), 0) as net_commissionable
        from public.sale_item_net sin where sin.sale_id = s.id
      ) sn on true
      where s.status = 'confirmed' and s.sold_at between v_from and v_to
        and (s.payment_status is null or s.payment_status = 'PAID')
        and public.has_location_access(s.location_id)
        and (p_location_id is null or s.location_id = p_location_id)
        and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
    ),
    'revenue_by_day', (
      select coalesce(jsonb_agg(jsonb_build_object('day', day, 'revenue', revenue) order by day), '[]'::jsonb)
      from (
        select (s.sold_at at time zone 'America/Argentina/Buenos_Aires')::date as day, sum(sn.net_total) as revenue
        from public.sales s
        join lateral (
          select coalesce(sum(net_line_total), 0) as net_total
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by 1
      ) t
    ),
    'sales_by_location', (
      select coalesce(jsonb_agg(jsonb_build_object('location', sl.name, 'revenue', t.revenue, 'count', t.cnt)), '[]'::jsonb)
      from (
        select s.location_id, sum(sn.net_total) as revenue, count(*) as cnt
        from public.sales s
        join lateral (
          select coalesce(sum(net_line_total), 0) as net_total
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by s.location_id
      ) t
      join public.stock_locations sl on sl.id = t.location_id
    ),
    'sales_by_channel', (
      select coalesce(jsonb_agg(jsonb_build_object('channel', sc.name, 'revenue', t.revenue, 'count', t.cnt)), '[]'::jsonb)
      from (
        select s.sales_channel_id, sum(sn.net_total) as revenue, count(*) as cnt
        from public.sales s
        join lateral (
          select coalesce(sum(net_line_total), 0) as net_total
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by s.sales_channel_id
      ) t
      join public.sales_channels sc on sc.id = t.sales_channel_id
    ),
    'revenue_by_payment_method', (
      select coalesce(jsonb_agg(jsonb_build_object('payment_method', pm.name, 'revenue', t.revenue)), '[]'::jsonb)
      from (
        select s.payment_method_id, sum(sn.net_total) as revenue
        from public.sales s
        join lateral (
          select coalesce(sum(net_line_total), 0) as net_total
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by s.payment_method_id
      ) t
      join public.payment_methods pm on pm.id = t.payment_method_id
    ),
    'top_products_by_units', (
      select coalesce(jsonb_agg(jsonb_build_object('product', p.name, 'units', t.units) order by t.units desc), '[]'::jsonb)
      from (
        select sin.product_id, sum(sin.net_quantity) as units
        from public.sale_item_net sin
        join public.sales s on s.id = sin.sale_id
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by sin.product_id
        having sum(sin.net_quantity) > 0
        order by units desc
        limit 8
      ) t
      join public.products p on p.id = t.product_id
    ),
    'top_products_by_revenue', (
      select coalesce(jsonb_agg(jsonb_build_object('product', p.name, 'revenue', t.revenue) order by t.revenue desc), '[]'::jsonb)
      from (
        select sin.product_id, sum(sin.net_line_total) as revenue
        from public.sale_item_net sin
        join public.sales s on s.id = sin.sale_id
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by sin.product_id
        having sum(sin.net_line_total) > 0
        order by revenue desc
        limit 8
      ) t
      join public.products p on p.id = t.product_id
    ),
    'commission_by_doctor', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'doctor_id', d.id, 'doctor', d.full_name, 'sales_count', t.cnt,
        'commissionable_revenue', t.commissionable_revenue, 'commission', t.commission
      ) order by t.commission desc), '[]'::jsonb)
      from (
        select s.doctor_id, count(*) as cnt,
          sum(sn.net_commissionable) as commissionable_revenue,
          sum(case when sn.gross_commissionable > 0
            then round(s.commission_total * sn.net_commissionable / sn.gross_commissionable, 2)
            else 0 end) as commission
        from public.sales s
        join lateral (
          select
            coalesce(sum(case when commissionable then gross_line_total else 0 end), 0) as gross_commissionable,
            coalesce(sum(case when commissionable then net_line_total else 0 end), 0) as net_commissionable
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and s.doctor_id is not null
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by s.doctor_id
      ) t
      join public.doctors d on d.id = t.doctor_id
    ),
    'critical_stock_count', (
      select count(*) from public.product_stock_status pss
      where pss.available_status in ('bajo', 'sin_stock')
        and pss.product_active = true
        and public.has_location_access(pss.location_id)
        and (p_location_id is null or pss.location_id = p_location_id)
    )
  );
end;
$$;

comment on function public.dashboard_report(date, date, uuid, uuid) is
  'Único punto de agregación para /dashboard. Requiere admin o can_view_financial_reports. '
  'Toda la agregación ocurre en SQL: el cliente nunca pagina/filtra ventas crudas. '
  'critical_stock_count excluye productos inactivos — no son una alerta operativa real. BLOQUE F '
  '(61): cuenta sobre available_status (disponible = físico - reservas ACTIVE), no el físico '
  'crudo — antes podía mostrar "ok" con reservas que agotaban el disponible real. '
  'Revenue/unidades/top productos/comisión son SIEMPRE netos de devoluciones (sale_item_net) — '
  'status=confirmed solo no alcanza porque una devolución parcial no cambia el status. BUGFIX 56: '
  'además excluyen un pedido Web con payment_status=PENDING (no cobrado todavía) — fulfillment '
  '(pendiente/entregado) no cambia esta condición económica, son ejes distintos.';

