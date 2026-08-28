-- =============================================================================
-- Maguirejuve · 21 · Motor de precios: soporte de venta sin costo (bloque 2)
-- =============================================================================
-- Se agrega p_is_free_sale como parámetro final (compatible hacia atrás: todo
-- llamador existente que no lo pase sigue funcionando igual, default false).
-- Cuando es true, el motor NO evalúa condiciones de precio: cada línea se
-- entrega a $0, pero se conserva el precio de lista como referencia informativa
-- ("cuánto valía lo que se regaló") y las líneas quedan forzadas a NO
-- comisionables (nunca $0 arbitrario, nunca comisión sobre una entrega gratis).

-- CREATE OR REPLACE solo reemplaza una función si la lista de tipos de
-- parámetros es IDÉNTICA. Agregar un parámetro nuevo crea un overload aparte
-- y deja vivo el original — con el riesgo de que PostgREST no sepa resolver
-- cuál invocar. Se dropean las firmas anteriores explícitamente antes de
-- recrearlas con el parámetro nuevo.
drop function if exists public.fn_pricing_quote(jsonb, uuid, timestamptz);
drop function if exists public.quote_sale(jsonb, uuid, timestamptz);
drop function if exists public.fn_create_sale_core(
  uuid, jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz
);
drop function if exists public.create_sale(
  jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz
);

create or replace function public.fn_pricing_quote(
  p_items jsonb,
  p_payment_method_id uuid,
  p_sold_at timestamptz default now(),
  p_is_free_sale boolean default false
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

  -- -------------------------------------------------------------------------
  -- Venta sin costo: sin condición de precio, sin comisión, precio de lista
  -- únicamente como referencia. Nunca se interpreta como "precio $0 manual".
  -- -------------------------------------------------------------------------
  if p_is_free_sale then
    for v_line in
      select ti.product_id, p.sku, p.name, ti.quantity, list_price.amount as list_unit_price
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
    loop
      v_line.list_unit_price := coalesce(v_line.list_unit_price, 0);
      v_subtotal := v_subtotal + (v_line.list_unit_price * v_line.quantity);

      v_lines := v_lines || jsonb_build_object(
        'product_id', v_line.product_id,
        'sku', v_line.sku,
        'name', v_line.name,
        'quantity', v_line.quantity,
        'list_unit_price', v_line.list_unit_price,
        'sale_unit_price', 0,
        'line_list_total', round(v_line.list_unit_price * v_line.quantity, 2),
        'line_discount', round(v_line.list_unit_price * v_line.quantity, 2),
        'line_total', 0,
        'commissionable', false,
        'applied_price_condition_id', null
      );
    end loop;

    return jsonb_build_object(
      'ok', true,
      'error_message', null,
      'applied_price_condition_id', null,
      'applied_price_condition_code', null,
      'applied_price_condition_name', null,
      'explanation', 'Venta sin costo',
      'subtotal', round(v_subtotal, 2),
      'discount_total', round(v_subtotal, 2),
      'total', 0,
      'lines', v_lines
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

revoke execute on function public.fn_pricing_quote(jsonb, uuid, timestamptz, boolean) from public;

-- ---------------------------------------------------------------------------
create or replace function public.quote_sale(
  p_items jsonb,
  p_payment_method_id uuid,
  p_sold_at timestamptz default now(),
  p_is_free_sale boolean default false
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
  return public.fn_pricing_quote(p_items, p_payment_method_id, p_sold_at, p_is_free_sale);
end;
$$;

grant execute on function public.quote_sale(jsonb, uuid, timestamptz, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- fn_create_sale_core: agrega venta sin costo (motivo obligatorio, comisión 0).
-- ---------------------------------------------------------------------------
create or replace function public.fn_create_sale_core(
  p_seller_id uuid,
  p_items jsonb,
  p_location_id uuid,
  p_sales_channel_id uuid,
  p_payment_method_id uuid,
  p_customer_id uuid,
  p_doctor_id uuid,
  p_notes text,
  p_external_source text,
  p_external_order_id text,
  p_sold_at timestamptz,
  p_is_free_sale boolean default false,
  p_free_sale_reason public.free_sale_reason default null,
  p_free_sale_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
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

  if p_is_free_sale and p_free_sale_reason is null then
    raise exception 'Una entrega sin costo necesita un motivo (regalo, muestra, canje, cortesía u otro).';
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

  v_quote := public.fn_pricing_quote(p_items, p_payment_method_id, p_sold_at, p_is_free_sale);
  if not (v_quote ->> 'ok')::boolean then
    raise exception '%', v_quote ->> 'error_message';
  end if;

  -- Comisión SIEMPRE 0 en una entrega sin costo, sin importar la doctora
  -- seleccionada (fn_pricing_quote ya marcó todas las líneas no comisionables,
  -- esto es una segunda barrera explícita).
  if not p_is_free_sale and p_doctor_id is not null then
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
    external_source, external_order_id, notes,
    is_free_sale, free_sale_reason, free_sale_notes
  ) values (
    v_sale_number, p_sold_at, p_location_id, p_sales_channel_id, p_seller_id,
    p_customer_id, p_doctor_id, p_payment_method_id, (v_quote ->> 'applied_price_condition_id')::uuid,
    (v_quote ->> 'subtotal')::numeric, (v_quote ->> 'discount_total')::numeric,
    (v_quote ->> 'total')::numeric, v_commission_total, 'confirmed',
    p_external_source, p_external_order_id, p_notes,
    p_is_free_sale, p_free_sale_reason, p_free_sale_notes
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
      nullif(v_line ->> 'applied_price_condition_id', '')::uuid,
      (v_line ->> 'commissionable')::boolean
    );
  end loop;

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
      p_created_by => p_seller_id,
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
    'is_free_sale', p_is_free_sale,
    'lines', v_quote -> 'lines'
  );
end;
$$;

revoke execute on function public.fn_create_sale_core(
  uuid, jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text
) from public;

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
  p_free_sale_notes text default null
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

  if not public.has_location_access(p_location_id) then
    raise exception 'Tu usuario no tiene acceso a esta sucursal.';
  end if;

  return public.fn_create_sale_core(
    auth.uid(), p_items, p_location_id, p_sales_channel_id, p_payment_method_id,
    p_customer_id, p_doctor_id, p_notes, p_external_source, p_external_order_id, p_sold_at,
    p_is_free_sale, p_free_sale_reason, p_free_sale_notes
  );
end;
$$;

grant execute on function public.create_sale(
  jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text
) to authenticated;
