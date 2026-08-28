-- =============================================================================
-- Maguirejuve · 09 · Funciones de negocio (RPC) — motor de precios y transacciones
-- =============================================================================
-- Todas las funciones que escriben datos de negocio son SECURITY DEFINER con
-- search_path fijo, y validan permisos "a mano" adentro (no dependen de que el
-- caller tenga privilegios de tabla — eso es justamente lo que evita que el
-- frontend le pase un total/descuento/movimiento de stock ya calculado).

-- ---------------------------------------------------------------------------
-- fn_next_sale_number: contador atómico por sede/día.
-- ---------------------------------------------------------------------------
create or replace function public.fn_next_sale_number(p_location_id uuid, p_sold_at timestamptz)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day date;
  v_seq int;
  v_short_code text;
begin
  v_day := (p_sold_at at time zone 'America/Argentina/Buenos_Aires')::date;

  insert into public.sale_number_counters (location_id, day, last_seq)
  values (p_location_id, v_day, 1)
  on conflict (location_id, day)
  do update set last_seq = public.sale_number_counters.last_seq + 1
  returning last_seq into v_seq;

  select short_code into v_short_code from public.stock_locations where id = p_location_id;

  return format('MJ-%s-%s-%s', v_short_code, to_char(v_day, 'YYYYMMDD'), lpad(v_seq::text, 4, '0'));
end;
$$;

-- ---------------------------------------------------------------------------
-- fn_pricing_quote: ÚNICA fuente de verdad del motor de precios.
-- Input: items = [{"product_id": uuid, "quantity": number}, ...]
-- No escribe nada. La usan quote_sale() (preview) y create_sale() (confirmación).
-- ---------------------------------------------------------------------------
create or replace function public.fn_pricing_quote(
  p_items jsonb,
  p_payment_method_id uuid,
  p_sold_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total_qty numeric := 0;
  v_condition record;
  v_line record;
  v_lines jsonb := '[]'::jsonb;
  v_subtotal numeric := 0;
  v_discount numeric := 0;
  v_total numeric := 0;
  v_item_count int;
  v_distinct_count int;
  v_missing_product text;
  v_invalid_qty boolean;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('ok', false, 'error_message', 'El carrito está vacío.');
  end if;

  select count(*), count(distinct (elem ->> 'product_id'))
  into v_item_count, v_distinct_count
  from jsonb_array_elements(p_items) elem;

  if v_item_count <> v_distinct_count then
    return jsonb_build_object('ok', false, 'error_message', 'Hay un producto duplicado en el carrito.');
  end if;

  select bool_or((elem ->> 'quantity')::numeric is null or (elem ->> 'quantity')::numeric <= 0)
  into v_invalid_qty
  from jsonb_array_elements(p_items) elem;

  if v_invalid_qty then
    return jsonb_build_object('ok', false, 'error_message', 'Hay una cantidad inválida en el carrito.');
  end if;

  select string_agg(elem ->> 'product_id', ', ')
  into v_missing_product
  from jsonb_array_elements(p_items) elem
  left join public.products p on p.id = (elem ->> 'product_id')::uuid and p.active = true
  where p.id is null;

  if v_missing_product is not null then
    return jsonb_build_object(
      'ok', false,
      'error_message', 'Uno de los productos del carrito no existe o está inactivo.'
    );
  end if;

  select coalesce(sum((elem ->> 'quantity')::numeric), 0)
  into v_total_qty
  from jsonb_array_elements(p_items) elem
  join public.products p on p.id = (elem ->> 'product_id')::uuid
  where p.promo_eligible = true;

  select pc.* into v_condition
  from public.price_conditions pc
  where pc.active
    and (
      pc.rule_type = 'BASE'
      or (pc.rule_type = 'PAYMENT_METHOD' and pc.payment_method_id = p_payment_method_id)
      or (pc.rule_type = 'QUANTITY' and v_total_qty >= pc.min_units)
    )
  order by pc.priority asc
  limit 1;

  if v_condition is null then
    return jsonb_build_object('ok', false, 'error_message', 'No hay ninguna condición de precio activa configurada.');
  end if;

  for v_line in
    select
      ti.product_id,
      p.sku,
      p.name,
      p.commissionable,
      ti.quantity,
      list_price.amount as list_unit_price,
      sale_price.amount as sale_unit_price
    from (
      select (elem ->> 'product_id')::uuid as product_id, (elem ->> 'quantity')::numeric as quantity
      from jsonb_array_elements(p_items) elem
    ) ti
    join public.products p on p.id = ti.product_id
    left join lateral (
      select pp.amount
      from public.product_prices pp
      join public.price_conditions lc on lc.id = pp.price_condition_id and lc.rule_type = 'BASE'
      where pp.product_id = ti.product_id
        and pp.active = true
        and pp.amount > 0
        and pp.valid_from <= p_sold_at
        and (pp.valid_until is null or pp.valid_until > p_sold_at)
      order by pp.valid_from desc
      limit 1
    ) list_price on true
    left join lateral (
      select pp.amount
      from public.product_prices pp
      where pp.product_id = ti.product_id
        and pp.price_condition_id = v_condition.id
        and pp.active = true
        and pp.amount > 0
        and pp.valid_from <= p_sold_at
        and (pp.valid_until is null or pp.valid_until > p_sold_at)
      order by pp.valid_from desc
      limit 1
    ) sale_price on true
  loop
    if v_line.sale_unit_price is null then
      return jsonb_build_object(
        'ok', false,
        'error_message', format('Este producto no tiene precio configurado para %s: %s.', v_condition.name, v_line.name)
      );
    end if;

    -- Si el producto no tiene precio de LISTA cargado (ej. ACC-NEC, catálogo incompleto),
    -- no bloquea la venta bajo una condición que sí tiene precio válido: simplemente no
    -- hay "ahorro" que mostrar en esa línea (list = sale, descuento = 0).
    v_line.list_unit_price := coalesce(v_line.list_unit_price, v_line.sale_unit_price);

    v_subtotal := v_subtotal + (v_line.list_unit_price * v_line.quantity);
    v_total := v_total + (v_line.sale_unit_price * v_line.quantity);

    v_lines := v_lines || jsonb_build_object(
      'product_id', v_line.product_id,
      'sku', v_line.sku,
      'name', v_line.name,
      'quantity', v_line.quantity,
      'list_unit_price', v_line.list_unit_price,
      'sale_unit_price', v_line.sale_unit_price,
      'line_list_total', round(v_line.list_unit_price * v_line.quantity, 2),
      'line_discount', round((v_line.list_unit_price - v_line.sale_unit_price) * v_line.quantity, 2),
      'line_total', round(v_line.sale_unit_price * v_line.quantity, 2),
      'commissionable', v_line.commissionable,
      'applied_price_condition_id', v_condition.id
    );
  end loop;

  v_discount := v_subtotal - v_total;

  return jsonb_build_object(
    'ok', true,
    'error_message', null,
    'applied_price_condition_id', v_condition.id,
    'applied_price_condition_code', v_condition.code,
    'applied_price_condition_name', v_condition.name,
    'explanation', case
      when v_condition.rule_type = 'BASE' then 'Precio lista'
      when v_condition.discount_percent is not null and v_condition.discount_percent > 0
        then format('%s — %s%% OFF', v_condition.name, round(v_condition.discount_percent * 100))
      else v_condition.name
    end,
    'subtotal', round(v_subtotal, 2),
    'discount_total', round(v_discount, 2),
    'total', round(v_total, 2),
    'lines', v_lines
  );
end;
$$;

comment on function public.fn_pricing_quote(jsonb, uuid, timestamptz) is
  'Motor de precios. Determina UNA condición (no acumulable) por precedencia (priority asc) '
  'y exige precio vigente y positivo para cada línea bajo esa condición exacta, o rechaza.';

-- RPC pública de solo lectura: preview en tiempo real para el frontend.
create or replace function public.quote_sale(
  p_items jsonb,
  p_payment_method_id uuid,
  p_sold_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_active_profile() then
    raise exception 'Tu usuario no está activo.';
  end if;
  return public.fn_pricing_quote(p_items, p_payment_method_id, p_sold_at);
end;
$$;

grant execute on function public.quote_sale(jsonb, uuid, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- create_sale: transacción atómica completa (precio + stock + venta).
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
  p_sold_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_settings public.app_settings;
  v_quote jsonb;
  v_sale_id uuid;
  v_sale_number text;
  v_commission_percent numeric := 0;
  v_commission_total numeric := 0;
  v_line jsonb;
  v_required record;
  v_allow_negative boolean;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if not public.has_location_access(p_location_id) then
    raise exception 'Tu usuario no tiene acceso a esta sucursal.';
  end if;

  if not exists (select 1 from public.stock_locations where id = p_location_id and active) then
    raise exception 'La sucursal seleccionada no existe o está inactiva.';
  end if;

  if not exists (select 1 from public.sales_channels where id = p_sales_channel_id and active) then
    raise exception 'El canal de venta seleccionado no existe o está inactivo.';
  end if;

  if not exists (select 1 from public.payment_methods where id = p_payment_method_id and active) then
    raise exception 'El medio de pago seleccionado no existe o está inactivo.';
  end if;

  if p_customer_id is not null and not exists (
    select 1 from public.customers where id = p_customer_id and active
  ) then
    raise exception 'El cliente seleccionado no existe.';
  end if;

  if p_doctor_id is not null and not exists (
    select 1 from public.doctors where id = p_doctor_id and active
  ) then
    raise exception 'La doctora seleccionada no existe o está inactiva.';
  end if;

  if p_external_source is not null and p_external_order_id is not null
     and exists (
       select 1 from public.sales
       where external_source = p_external_source and external_order_id = p_external_order_id
     ) then
    raise exception 'Este pedido externo ya fue importado (%: %).', p_external_source, p_external_order_id;
  end if;

  select * into v_settings from public.app_settings where id = 1;
  v_allow_negative := coalesce(v_settings.allow_negative_stock, false);

  -- Recalcula el precio server-side. Nunca confía en totales enviados por el cliente.
  v_quote := public.fn_pricing_quote(p_items, p_payment_method_id, p_sold_at);
  if not (v_quote ->> 'ok')::boolean then
    raise exception '%', v_quote ->> 'error_message';
  end if;

  if p_doctor_id is not null then
    select commission_percent into v_commission_percent from public.doctors where id = p_doctor_id;
  end if;

  select coalesce(sum((line ->> 'line_total')::numeric), 0)
  into v_commission_total
  from jsonb_array_elements(v_quote -> 'lines') line
  where (line ->> 'commissionable')::boolean = true;

  v_commission_total := round(v_commission_total * v_commission_percent, 2);

  v_sale_number := public.fn_next_sale_number(p_location_id, p_sold_at);

  insert into public.sales (
    sale_number, sold_at, location_id, sales_channel_id, seller_id,
    customer_id, doctor_id, payment_method_id, applied_price_condition_id,
    subtotal, discount_total, total, commission_total, status,
    external_source, external_order_id, notes
  ) values (
    v_sale_number, p_sold_at, p_location_id, p_sales_channel_id, auth.uid(),
    p_customer_id, p_doctor_id, p_payment_method_id, (v_quote ->> 'applied_price_condition_id')::uuid,
    (v_quote ->> 'subtotal')::numeric, (v_quote ->> 'discount_total')::numeric,
    (v_quote ->> 'total')::numeric, v_commission_total, 'confirmed',
    p_external_source, p_external_order_id, p_notes
  )
  returning id into v_sale_id;

  for v_line in select * from jsonb_array_elements(v_quote -> 'lines')
  loop
    insert into public.sale_items (
      sale_id, product_id, quantity, list_unit_price, sale_unit_price,
      line_list_total, line_discount, line_total, applied_price_condition_id, commissionable
    ) values (
      v_sale_id,
      (v_line ->> 'product_id')::uuid,
      (v_line ->> 'quantity')::numeric,
      (v_line ->> 'list_unit_price')::numeric,
      (v_line ->> 'sale_unit_price')::numeric,
      (v_line ->> 'line_list_total')::numeric,
      (v_line ->> 'line_discount')::numeric,
      (v_line ->> 'line_total')::numeric,
      (v_line ->> 'applied_price_condition_id')::uuid,
      (v_line ->> 'commissionable')::boolean
    );
  end loop;

  -- Expande kits a componentes y descuenta stock (bloqueo determinístico por product_id).
  for v_required in
    with items as (
      select (elem ->> 'product_id')::uuid as product_id, (elem ->> 'quantity')::numeric as quantity
      from jsonb_array_elements(p_items) elem
    ),
    expanded as (
      select i.product_id, i.quantity as required_qty
      from items i
      join public.products p on p.id = i.product_id and p.track_stock = true
      union all
      select kc.component_product_id, i.quantity * kc.quantity as required_qty
      from items i
      join public.products p on p.id = i.product_id and p.track_stock = false
      join public.kit_components kc on kc.kit_product_id = i.product_id
    )
    select product_id, sum(required_qty) as required_qty
    from expanded
    group by product_id
    order by product_id
  loop
    perform public.fn_apply_stock_movement(
      p_location_id => p_location_id,
      p_product_id => v_required.product_id,
      p_movement_type => 'SALE',
      p_quantity_delta => -v_required.required_qty,
      p_sale_id => v_sale_id,
      p_reference => v_sale_number,
      p_created_by => auth.uid(),
      p_allow_negative => v_allow_negative
    );
  end loop;

  return jsonb_build_object(
    'sale_id', v_sale_id,
    'sale_number', v_sale_number,
    'total', (v_quote ->> 'total')::numeric,
    'subtotal', (v_quote ->> 'subtotal')::numeric,
    'discount_total', (v_quote ->> 'discount_total')::numeric,
    'commission_total', v_commission_total,
    'applied_price_condition_name', v_quote ->> 'applied_price_condition_name',
    'explanation', v_quote ->> 'explanation',
    'lines', v_quote -> 'lines'
  );
end;
$$;

comment on function public.create_sale is
  'RPC transaccional: valida, recalcula precio, verifica y descuenta stock (expandiendo kits), '
  'calcula comisión sólo sobre líneas commissionable, y persiste venta + detalle + movimientos. '
  'Si cualquier paso falla, toda la operación se revierte (no queda una venta a medias).';

grant execute on function public.create_sale(
  jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz
) to authenticated;

-- ---------------------------------------------------------------------------
-- cancel_sale: revierte stock, jamás borra la venta.
-- ---------------------------------------------------------------------------
create or replace function public.cancel_sale(p_sale_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sale public.sales;
  v_required record;
begin
  if not public.is_admin() then
    raise exception 'Tu usuario no tiene permiso para cancelar ventas.';
  end if;

  if p_reason is null or trim(p_reason) = '' then
    raise exception 'El motivo de cancelación es obligatorio.';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale is null then
    raise exception 'La venta no existe.';
  end if;

  if v_sale.status = 'cancelled' then
    raise exception 'La venta ya fue cancelada.';
  end if;

  if not public.has_location_access(v_sale.location_id) then
    raise exception 'Tu usuario no tiene acceso a la sucursal de esta venta.';
  end if;

  for v_required in
    with sale_lines as (
      select product_id, quantity from public.sale_items where sale_id = p_sale_id
    ),
    expanded as (
      select sl.product_id, sl.quantity as required_qty
      from sale_lines sl
      join public.products p on p.id = sl.product_id and p.track_stock = true
      union all
      select kc.component_product_id, sl.quantity * kc.quantity as required_qty
      from sale_lines sl
      join public.products p on p.id = sl.product_id and p.track_stock = false
      join public.kit_components kc on kc.kit_product_id = sl.product_id
    )
    select product_id, sum(required_qty) as required_qty
    from expanded
    group by product_id
    order by product_id
  loop
    perform public.fn_apply_stock_movement(
      p_location_id => v_sale.location_id,
      p_product_id => v_required.product_id,
      p_movement_type => 'SALE_CANCEL',
      p_quantity_delta => v_required.required_qty,
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

comment on function public.cancel_sale is
  'Nunca hace hard delete. Marca la venta como cancelada y repone exactamente el stock '
  'descontado (expandiendo kits igual que create_sale). Imposible cancelar dos veces.';

grant execute on function public.cancel_sale(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- transfer_stock: atómico entre dos sedes.
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

grant execute on function public.transfer_stock(uuid, uuid, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------------
-- adjust_stock: ajuste manual auditado (recepción, rotura, vencimiento, etc.)
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

grant execute on function public.adjust_stock(
  uuid, uuid, numeric, public.stock_adjustment_reason, text
) to authenticated;

-- ---------------------------------------------------------------------------
-- set_product_price: cierra vigencia anterior y crea una nueva fila (histórico inmutable).
-- ---------------------------------------------------------------------------
create or replace function public.set_product_price(
  p_product_id uuid,
  p_price_condition_id uuid,
  p_amount numeric,
  p_valid_from timestamptz default now()
)
returns public.product_prices
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new public.product_prices;
begin
  if not public.is_admin() then
    raise exception 'Tu usuario no tiene permiso para modificar precios.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'El precio debe ser mayor a cero.';
  end if;

  update public.product_prices
  set valid_until = p_valid_from, active = false
  where product_id = p_product_id
    and price_condition_id = p_price_condition_id
    and active = true
    and valid_from < p_valid_from;

  insert into public.product_prices (product_id, price_condition_id, amount, valid_from, created_by)
  values (p_product_id, p_price_condition_id, p_amount, p_valid_from, auth.uid())
  returning * into v_new;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'set_product_price', 'products', p_product_id,
    jsonb_build_object('price_condition_id', p_price_condition_id, 'amount', p_amount)
  );

  return v_new;
end;
$$;

grant execute on function public.set_product_price(uuid, uuid, numeric, timestamptz) to authenticated;
