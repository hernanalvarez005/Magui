-- =============================================================================
-- Maguirejuve · 28 · Motor de promociones: aplicación (bloque 7)
-- =============================================================================
-- fn_apply_promotions recibe las líneas YA resueltas por price_conditions
-- (sale_unit_price = precio según medio de pago/cantidad) y las ajusta según
-- las promociones activas y vigentes. Nunca se evalúa antes: la promoción
-- descuenta sobre el precio ya resuelto, no sobre el precio de lista.
--
-- Cada producto del carrito aparece como máximo una vez en p_lines (ya lo
-- garantiza fn_pricing_quote — "Hay un producto duplicado en el carrito").
-- Eso simplifica todo lo que sigue: no hace falta rastrear qué línea es cada
-- producto, alcanza con agrupar por product_id.
create or replace function public.fn_apply_promotions(
  p_lines jsonb,
  p_sold_at timestamptz
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with cart as (
    select
      (elem ->> 'product_id')::uuid as product_id,
      elem ->> 'sku' as sku,
      elem ->> 'name' as name,
      (elem ->> 'quantity')::numeric as quantity,
      (elem ->> 'list_unit_price')::numeric as list_unit_price,
      (elem ->> 'sale_unit_price')::numeric as sale_unit_price,
      (elem ->> 'line_list_total')::numeric as line_list_total,
      (elem ->> 'line_discount')::numeric as line_discount,
      (elem ->> 'line_total')::numeric as line_total,
      (elem ->> 'commissionable')::boolean as commissionable,
      nullif(elem ->> 'applied_price_condition_id', '')::uuid as applied_price_condition_id
    from jsonb_array_elements(p_lines) elem
  ),
  active_promos as (
    select *
    from public.promotions
    where active = true
      and valid_from <= p_sold_at
      and (valid_until is null or valid_until > p_sold_at)
  ),
  promo_products_agg as (
    select promotion_id, array_agg(product_id) as product_ids
    from public.promotion_products
    group by promotion_id
  ),
  matches as (
    select
      ap.id, ap.type, ap.discount_percent, ap.group_size, ap.priority, ap.stackable,
      ppa.product_ids,
      (select coalesce(sum(c.quantity), 0) from cart c where c.product_id = any (ppa.product_ids))
        as total_eligible_qty,
      case
        when ap.type = 'THREE_FOR_TWO' then
          (select coalesce(sum(c.quantity), 0) from cart c where c.product_id = any (ppa.product_ids)) >= ap.group_size
          and (select coalesce(bool_and(c.quantity = floor(c.quantity)), false)
               from cart c where c.product_id = any (ppa.product_ids))
        when ap.type = 'DUO_PERCENT' then
          coalesce(array_length(ppa.product_ids, 1), 0) = 2
          and (select count(*) from cart c where c.product_id = any (ppa.product_ids)) = 2
        when ap.type = 'KIT_PERCENT' then
          exists (select 1 from cart c where c.product_id = any (ppa.product_ids))
        else false
      end as is_match
    from active_promos ap
    join promo_products_agg ppa on ppa.promotion_id = ap.id
  ),
  -- Si alguna promoción no-stackable matchea, gana solo ella (la de mayor
  -- prioridad = menor número). Si ninguna no-stackable matchea, se aplican
  -- todas las stackable que matcheen — nunca compiten por el mismo producto
  -- porque un producto pertenece a lo sumo a una promoción activa.
  exclusive_winner as (
    select id from matches where is_match and stackable = false order by priority asc limit 1
  ),
  winners as (
    select m.*
    from matches m
    where m.is_match
      and (
        (exists (select 1 from exclusive_winner) and m.id = (select id from exclusive_winner))
        or (not exists (select 1 from exclusive_winner) and m.stackable = true)
      )
  ),
  -- THREE_FOR_TWO: se expande cada unidad elegible, se ordena por precio
  -- ascendente dentro de la promoción y se marcan como gratis las
  -- floor(total_elegible / group_size) unidades más baratas.
  t2_units as (
    select w.id as promotion_id, c.product_id, c.sale_unit_price, gs as unit_idx
    from winners w
    join cart c on c.product_id = any (w.product_ids)
    cross join lateral generate_series(1, c.quantity::int) as gs
    where w.type = 'THREE_FOR_TWO'
  ),
  t2_ranked as (
    select
      *,
      row_number() over (partition by promotion_id order by sale_unit_price asc, product_id asc, unit_idx asc) as rn
    from t2_units
  ),
  t2_free_totals as (
    select id as promotion_id, floor(total_eligible_qty / group_size)::int as free_total
    from winners
    where type = 'THREE_FOR_TWO'
  ),
  t2_free_by_product as (
    select r.promotion_id, r.product_id, count(*) filter (where r.rn <= ft.free_total) as free_units
    from t2_ranked r
    join t2_free_totals ft on ft.promotion_id = r.promotion_id
    group by r.promotion_id, r.product_id
  ),
  -- DUO_PERCENT: se forman min(qty_a, qty_b) "duos"; cada duo da descuento a
  -- una unidad de cada producto. El resto (si alguno compró más del otro)
  -- queda a precio normal.
  duo_resolved as (
    select
      w.id as promotion_id,
      w.discount_percent,
      w.product_ids[1] as product_a,
      w.product_ids[2] as product_b,
      least(
        (select quantity from cart where product_id = w.product_ids[1]),
        (select quantity from cart where product_id = w.product_ids[2])
      ) as duo_count
    from winners w
    where w.type = 'DUO_PERCENT'
  ),
  -- KIT_PERCENT: descuento parejo sobre toda la cantidad del kit.
  kit_resolved as (
    select w.id as promotion_id, w.discount_percent, w.product_ids[1] as product_id
    from winners w
    where w.type = 'KIT_PERCENT'
  ),
  sub_lines as (
    -- 3x2: remanente pago (cubre tanto "parcial" como "0 unidades gratis
    -- para este producto" — puede pasar que la promoción matchee pero la
    -- unidad más barata haya sido de OTRO producto de la misma promo).
    select
      c.product_id, c.sku, c.name, (c.quantity - t2.free_units) as quantity,
      c.list_unit_price, c.sale_unit_price,
      round(c.list_unit_price * (c.quantity - t2.free_units), 2) as line_list_total,
      round((c.list_unit_price - c.sale_unit_price) * (c.quantity - t2.free_units), 2) as line_discount,
      round(c.sale_unit_price * (c.quantity - t2.free_units), 2) as line_total,
      c.commissionable, c.applied_price_condition_id,
      null::uuid as applied_promotion_id, 0::numeric as promotion_discount
    from cart c
    join t2_free_by_product t2 on t2.product_id = c.product_id
    where (c.quantity - t2.free_units) > 0

    union all

    -- 3x2: unidades gratis.
    select
      c.product_id, c.sku, c.name, t2.free_units as quantity,
      c.list_unit_price, 0::numeric as sale_unit_price,
      round(c.list_unit_price * t2.free_units, 2) as line_list_total,
      round(c.list_unit_price * t2.free_units, 2) as line_discount,
      0::numeric as line_total,
      c.commissionable, c.applied_price_condition_id,
      t2.promotion_id as applied_promotion_id,
      round(c.sale_unit_price * t2.free_units, 2) as promotion_discount
    from cart c
    join t2_free_by_product t2 on t2.product_id = c.product_id
    where t2.free_units > 0

    union all

    -- duo: remanente a precio normal (si compró más del producto abundante).
    select
      c.product_id, c.sku, c.name, (c.quantity - d.duo_count) as quantity,
      c.list_unit_price, c.sale_unit_price,
      round(c.list_unit_price * (c.quantity - d.duo_count), 2) as line_list_total,
      round((c.list_unit_price - c.sale_unit_price) * (c.quantity - d.duo_count), 2) as line_discount,
      round(c.sale_unit_price * (c.quantity - d.duo_count), 2) as line_total,
      c.commissionable, c.applied_price_condition_id,
      null::uuid as applied_promotion_id, 0::numeric as promotion_discount
    from cart c
    join duo_resolved d on c.product_id in (d.product_a, d.product_b)
    where (c.quantity - d.duo_count) > 0

    union all

    -- duo: unidades con descuento.
    select
      c.product_id, c.sku, c.name, d.duo_count as quantity,
      c.list_unit_price, round(c.sale_unit_price * (1 - d.discount_percent), 2) as sale_unit_price,
      round(c.list_unit_price * d.duo_count, 2) as line_list_total,
      round((c.list_unit_price - round(c.sale_unit_price * (1 - d.discount_percent), 2)) * d.duo_count, 2)
        as line_discount,
      round(round(c.sale_unit_price * (1 - d.discount_percent), 2) * d.duo_count, 2) as line_total,
      c.commissionable, c.applied_price_condition_id,
      d.promotion_id as applied_promotion_id,
      round(c.sale_unit_price * d.discount_percent * d.duo_count, 2) as promotion_discount
    from cart c
    join duo_resolved d on c.product_id in (d.product_a, d.product_b)
    where d.duo_count > 0

    union all

    -- kit%: toda la cantidad del kit, a precio reducido.
    select
      c.product_id, c.sku, c.name, c.quantity,
      c.list_unit_price, round(c.sale_unit_price * (1 - k.discount_percent), 2) as sale_unit_price,
      c.line_list_total,
      round((c.list_unit_price - round(c.sale_unit_price * (1 - k.discount_percent), 2)) * c.quantity, 2)
        as line_discount,
      round(round(c.sale_unit_price * (1 - k.discount_percent), 2) * c.quantity, 2) as line_total,
      c.commissionable, c.applied_price_condition_id,
      k.promotion_id as applied_promotion_id,
      round(c.sale_unit_price * k.discount_percent * c.quantity, 2) as promotion_discount
    from cart c
    join kit_resolved k on k.product_id = c.product_id

    union all

    -- sin promoción: pasa igual que venía de price_conditions.
    select
      c.product_id, c.sku, c.name, c.quantity, c.list_unit_price, c.sale_unit_price,
      c.line_list_total, c.line_discount, c.line_total, c.commissionable, c.applied_price_condition_id,
      null::uuid as applied_promotion_id, 0::numeric as promotion_discount
    from cart c
    where not exists (select 1 from t2_free_by_product t2 where t2.product_id = c.product_id)
      and not exists (select 1 from duo_resolved d where c.product_id in (d.product_a, d.product_b))
      and not exists (select 1 from kit_resolved k where k.product_id = c.product_id)
  )
  select jsonb_build_object(
    'lines', coalesce(jsonb_agg(jsonb_build_object(
      'product_id', product_id, 'sku', sku, 'name', name, 'quantity', quantity,
      'list_unit_price', list_unit_price, 'sale_unit_price', sale_unit_price,
      'line_list_total', line_list_total, 'line_discount', line_discount, 'line_total', line_total,
      'commissionable', commissionable, 'applied_price_condition_id', applied_price_condition_id,
      'applied_promotion_id', applied_promotion_id, 'promotion_discount', promotion_discount
    )), '[]'::jsonb),
    'promotion_discount_total', coalesce(sum(promotion_discount), 0)
  )
  from sub_lines;
$$;

revoke execute on function public.fn_apply_promotions(jsonb, timestamptz) from public;

-- ---------------------------------------------------------------------------
-- fn_pricing_quote: se agrega el paso de promociones al final del camino
-- normal (nunca en venta sin costo — ya está a $0, no hay nada que
-- descontar). Misma firma exacta que ya existe: CREATE OR REPLACE alcanza.
-- ---------------------------------------------------------------------------
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
  v_promo_result jsonb;
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
  -- Venta sin costo: sin condición de precio, sin comisión, sin promociones —
  -- precio de lista únicamente como referencia. Nunca se interpreta como
  -- "precio $0 manual".
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

  -- Promociones: se evalúan sobre las líneas ya resueltas por price_conditions.
  v_promo_result := public.fn_apply_promotions(v_lines, p_sold_at);
  v_lines := v_promo_result -> 'lines';

  select coalesce(sum((elem ->> 'line_total')::numeric), 0)
  into v_total
  from jsonb_array_elements(v_lines) elem;

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
-- fn_create_sale_core: se agregan applied_promotion_id/promotion_discount al
-- insert de sale_items (las líneas ya vienen con esos campos resueltos desde
-- fn_pricing_quote/fn_apply_promotions). Misma firma exacta: CREATE OR
-- REPLACE alcanza, no hace falta dropear nada.
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
      line_list_total, line_discount, line_total, applied_price_condition_id, commissionable,
      applied_promotion_id, promotion_discount
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
      (v_line ->> 'commissionable')::boolean,
      nullif(v_line ->> 'applied_promotion_id', '')::uuid,
      coalesce((v_line ->> 'promotion_discount')::numeric, 0)
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
