-- =============================================================================
-- Maguirejuve · 48 · BUGFIX PRIORITARIO — Cambios/Devoluciones: producto
-- devuelto no reintegra stock en ventas anteriores a la trazabilidad por
-- línea (source_sale_item_id)
-- =============================================================================
-- CAUSA RAÍZ (confirmada con reproducción local, ver informe entregado al
-- usuario): tanto create_sale_exchange como create_sale_return reintegran
-- stock buscando en stock_movements las filas SALE con
-- source_sale_item_id = <línea raíz devuelta>. Esa columna se agregó recién
-- en 20260201000033_sale_exchanges_schema.sql — cualquier venta CONFIRMADA
-- ANTES de que esa migración llegara a producción tiene su movimiento SALE
-- original con source_sale_item_id = NULL (columna agregada sin backfill,
-- porque no había forma de reconstruir retroactivamente "qué línea generó
-- qué movimiento" para ventas ya cerradas). El filtro exacto no matchea
-- NINGUNA fila para esas ventas -> el loop de reversión no itera ni una vez
-- -> no se genera NINGÚN movimiento RETURN -> ERROR SILENCIOSO: la función
-- sigue, descuenta el producto nuevo con total normalidad, y termina en
-- éxito sin haber reintegrado nada. No hay excepción que lo delate.
--
-- FIX: antes de esta migración, product_id en cada stock_movement YA es
-- exacto para ventas legado (el fan-out de kit_components a nivel físico
-- existe desde mucho antes que source_sale_item_id — ver
-- 20260201000050_dashboard_products_breakdown.sql, mismo hallazgo). Lo
-- único que le faltaba a una venta legado era poder aislar "esta línea
-- específica" dentro de un carrito con el MISMO producto repetido en dos
-- líneas — algo que, antes de la migración 34 (que empezó a agrupar por
-- (sale_item_id, product_id) en vez de solo product_id), ni siquiera existía
-- a nivel de ledger: dos líneas del mismo producto en una venta legado YA
-- estaban fusionadas en una única fila de stock_movements desde el momento
-- en que se vendieron. Por eso, para una venta legado, reintegrar contra
-- TODO el ledger SALE de esa venta raíz (sale_id, no source_sale_item_id)
-- es exactamente tan preciso como pudo haber sido en su momento — nunca se
-- reconstruye nada con kit_components vigente, se usa el propio ledger
-- histórico completo de esa venta.
--
-- Se prueba primero la vía exacta (source_sale_item_id) — el camino normal
-- para toda venta posterior a la migración 33/34 sigue exactamente igual,
-- sin ningún cambio de comportamiento. Solo cuando esa vía no encuentra
-- NINGUNA fila entra el fallback por sale_id, y ese fallback filtra
-- explícitamente source_sale_item_id is null (nunca mezcla una fila
-- trazada de otra línea de la misma venta con el fallback legado).

-- ---------------------------------------------------------------------------
-- 1) create_sale_exchange — misma firma exacta que
--    20260201000049_promotion_snapshot_functions.sql (la vigente).
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

  -- -------------------------------------------------------------------------
  -- Reintegro de stock — BUGFIX: primero se intenta por source_sale_item_id
  -- (vía exacta, sin cambios de comportamiento para toda venta posterior a
  -- la migración 33/34). Si esa vía no encuentra NINGUNA fila (venta legado,
  -- anterior a que existiera esa columna), cae al ledger completo de la
  -- venta raíz — nunca kit_components vigente, siempre el propio histórico.
  -- -------------------------------------------------------------------------
  select exists(
    select 1 from public.stock_movements
    where movement_type = 'SALE' and source_sale_item_id = v_physical_source_id
  ) into v_has_traced_movements;

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
    if v_reversal_qty > 0 then
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
    end if;
  end loop;

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
  'Cambio de producto: genera una venta de reemplazo completa, nunca edita la original (pasa a '
  'replaced). Reintegro de stock del producto devuelto: primero por source_sale_item_id (vía '
  'exacta); si una venta legado (anterior a 20260201000033) no tiene esa columna poblada, cae al '
  'ledger completo de su venta raíz (nunca kit_components vigente) — bugfix: antes de esto, una '
  'venta legado no reintegraba NADA en silencio. Líneas copy/remainder trasladan su snapshot de '
  'promoción tal cual; la línea new nunca tiene promoción.';

-- ---------------------------------------------------------------------------
-- 2) create_sale_return — mismo bugfix, misma firma exacta que
--    20260201000040_sale_returns_functions.sql (la vigente).
-- ---------------------------------------------------------------------------
create or replace function public.create_sale_return(
  p_original_sale_id uuid,
  p_items jsonb,
  p_refund_method public.sale_refund_method,
  p_payment_account_id uuid default null,
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
  v_item jsonb;
  v_sale_item_id uuid;
  v_quantity numeric;
  v_returned_item public.sale_items;
  v_already_returned numeric;
  v_available numeric;
  v_physical_source_id uuid;
  v_root_quantity numeric;
  v_root_sale_id uuid;
  v_has_traced_movements boolean;
  v_movement record;
  v_reversal_qty numeric;
  v_line_refund numeric;
  v_return_lines jsonb := '[]'::jsonb;
  v_line jsonb;
  v_refund_amount numeric := 0;
  v_return_id uuid;
  v_new_return_item_id uuid;
  v_net_remaining numeric;
  v_billing_status public.sale_billing_status;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede registrar devoluciones.';
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Tenés que indicar al menos un producto a devolver.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(sale_item_id uuid, quantity numeric)
    group by x.sale_item_id
    having count(*) > 1
  ) then
    raise exception 'No se puede indicar el mismo producto más de una vez en la misma devolución — sumá la cantidad en una sola línea.';
  end if;

  if p_refund_method = 'TRANSFER' then
    if p_payment_account_id is null or not exists (
      select 1 from public.payment_accounts where id = p_payment_account_id and active
    ) then
      raise exception 'Una devolución por transferencia necesita indicar la cuenta desde la que sale el dinero.';
    end if;
  elsif p_payment_account_id is not null then
    raise exception 'Una devolución en efectivo no lleva cuenta asociada.';
  end if;

  select * into v_sale from public.sales where id = p_original_sale_id for update;

  if v_sale is null then
    raise exception 'La venta original no existe.';
  end if;

  if v_sale.status <> 'confirmed' then
    raise exception 'Esta venta no está confirmada (anulada, reemplazada por un cambio, o ya devuelta en su totalidad) — no admite una devolución.';
  end if;

  if not public.has_location_access(v_sale.location_id) then
    raise exception 'Tu usuario no tiene acceso a la sucursal de esta venta.';
  end if;

  if v_sale.is_free_sale then
    raise exception 'No se puede devolver dinero de una entrega sin costo — no hubo pago que reintegrar.';
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_sale_item_id := (v_item ->> 'sale_item_id')::uuid;
    v_quantity := (v_item ->> 'quantity')::numeric;

    if v_quantity is null or v_quantity <= 0 then
      raise exception 'La cantidad a devolver tiene que ser mayor a 0.';
    end if;

    select * into v_returned_item from public.sale_items where id = v_sale_item_id for update;

    if v_returned_item is null or v_returned_item.sale_id <> p_original_sale_id then
      raise exception 'El producto a devolver no pertenece a esta venta.';
    end if;

    select coalesce(sum(quantity), 0) into v_already_returned
    from public.sale_return_items
    where sale_item_id = v_sale_item_id;

    v_available := v_returned_item.quantity - v_already_returned;

    if v_quantity > v_available then
      raise exception
        'No podés devolver % unidades: esta línea solo tiene % disponibles para devolver (ya se descontó cualquier devolución anterior).',
        v_quantity, v_available;
    end if;

    v_line_refund := round(v_returned_item.sale_unit_price * v_quantity, 2);
    v_refund_amount := v_refund_amount + v_line_refund;

    v_return_lines := v_return_lines || jsonb_build_object(
      'sale_item_id', v_sale_item_id,
      'product_id', v_returned_item.product_id,
      'quantity', v_quantity,
      'unit_price_refunded', v_returned_item.sale_unit_price,
      'line_refund_total', v_line_refund,
      'physical_source_sale_item_id', coalesce(v_returned_item.physical_source_sale_item_id, v_returned_item.id)
    );
  end loop;

  -- -------------------------------------------------------------------------
  -- Reintegro de stock — mismo BUGFIX que create_sale_exchange: vía exacta
  -- por source_sale_item_id primero (sin cambios de comportamiento posterior
  -- a la migración 33/34); si una venta legado no tiene esa columna poblada,
  -- cae al ledger completo de la venta raíz, nunca kit_components vigente.
  -- -------------------------------------------------------------------------
  for v_line in select * from jsonb_array_elements(v_return_lines)
  loop
    v_physical_source_id := (v_line ->> 'physical_source_sale_item_id')::uuid;
    select quantity, sale_id into v_root_quantity, v_root_sale_id
    from public.sale_items where id = v_physical_source_id;

    select exists(
      select 1 from public.stock_movements
      where movement_type = 'SALE' and source_sale_item_id = v_physical_source_id
    ) into v_has_traced_movements;

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
      v_reversal_qty := round(
        (v_line ->> 'quantity')::numeric * abs(v_movement.quantity_delta) / v_root_quantity, 2
      );
      if v_reversal_qty > 0 then
        perform public.fn_apply_stock_movement(
          p_location_id => v_movement.location_id,
          p_product_id => v_movement.product_id,
          p_movement_type => 'RETURN',
          p_quantity_delta => v_reversal_qty,
          p_sale_id => p_original_sale_id,
          p_reference => v_sale.sale_number,
          p_notes => 'Devolución de producto',
          p_created_by => auth.uid(),
          p_allow_negative => true,
          p_source_sale_item_id => v_physical_source_id
        );
      end if;
    end loop;
  end loop;

  insert into public.sale_returns (
    original_sale_id, refund_amount, refund_method, payment_account_id, notes, created_by
  ) values (
    p_original_sale_id, v_refund_amount, p_refund_method, p_payment_account_id, p_notes, auth.uid()
  )
  returning id into v_return_id;

  for v_line in select * from jsonb_array_elements(v_return_lines)
  loop
    insert into public.sale_return_items (
      return_id, sale_item_id, product_id, quantity, unit_price_refunded, line_refund_total
    ) values (
      v_return_id,
      (v_line ->> 'sale_item_id')::uuid,
      (v_line ->> 'product_id')::uuid,
      (v_line ->> 'quantity')::numeric,
      (v_line ->> 'unit_price_refunded')::numeric,
      (v_line ->> 'line_refund_total')::numeric
    )
    returning id into v_new_return_item_id;
  end loop;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'SALE_RETURN_CREATED', 'sales', p_original_sale_id,
    jsonb_build_object(
      'return_id', v_return_id,
      'original_sale_id', p_original_sale_id,
      'customer_id', v_sale.customer_id,
      'location_id', v_sale.location_id,
      'refund_amount', v_refund_amount,
      'refund_method', p_refund_method,
      'payment_account_id', p_payment_account_id,
      'items', v_return_lines
    )
  );

  select coalesce(sum(net_line_total), 0) into v_net_remaining
  from public.sale_item_net
  where sale_id = p_original_sale_id;

  v_billing_status := v_sale.billing_status;

  if v_net_remaining = 0 then
    update public.sales
    set status = 'returned',
        billing_status = case when v_sale.billing_status = 'PENDING' then 'NOT_REQUIRED' else v_sale.billing_status end
    where id = p_original_sale_id
    returning billing_status into v_billing_status;
  end if;

  return jsonb_build_object(
    'return_id', v_return_id,
    'original_sale_id', p_original_sale_id,
    'refund_amount', v_refund_amount,
    'refund_method', p_refund_method,
    'is_full_return', v_net_remaining = 0,
    'sale_status', case when v_net_remaining = 0 then 'returned' else v_sale.status end,
    'billing_status', v_billing_status
  );
end;
$$;

comment on function public.create_sale_return(uuid, jsonb, public.sale_refund_method, uuid, text) is
  'Nunca hace hard delete. Admin o vendedor con acceso a la sede de la venta. Reintegro de stock: '
  'primero por source_sale_item_id (vía exacta); si una venta legado (anterior a '
  '20260201000033) no tiene esa columna poblada en su movimiento SALE, cae al ledger completo de '
  'su venta raíz (nunca kit_components vigente) — mismo bugfix que create_sale_exchange. '
  'Idempotente: una venta ya cancelada no puede volver a cancelarse.';
