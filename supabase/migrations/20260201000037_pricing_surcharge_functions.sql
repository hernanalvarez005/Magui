-- =============================================================================
-- Maguirejuve · Recargo comercial — funciones (paso 2/2)
-- =============================================================================
-- Ninguna de estas funciones cambia de firma (no hace falta ningún DROP
-- FUNCTION previo) — solo cambia el cálculo interno de line_discount/
-- line_surcharge, y de dónde sale discount_total/surcharge_total (SUMADO
-- desde las líneas, nunca derivado de subtotal-total).

-- ---------------------------------------------------------------------------
-- 1) fn_pricing_quote
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
  v_manual_lines jsonb := '[]'::jsonb;
  v_auto_lines jsonb := '[]'::jsonb;
  v_subtotal numeric := 0;
  v_discount numeric := 0;
  v_surcharge numeric := 0;
  v_total numeric := 0;
  v_item_count int;
  v_distinct_count int;
  v_missing_product text;
  v_invalid_qty boolean;
  v_has_manual boolean;
  v_invalid_manual boolean;
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

  -- Precio manual: exclusivo de admin, nunca confiando en que el frontend
  -- lo oculte (mismo criterio que backdatear una venta o saltear stock).
  select bool_or(nullif(elem ->> 'manual_price', '') is not null)
  into v_has_manual
  from jsonb_array_elements(p_items) elem;

  if v_has_manual and not public.is_admin() then
    raise exception 'Solo un administrador puede editar el precio manualmente.';
  end if;

  if v_has_manual and p_is_free_sale then
    return jsonb_build_object(
      'ok', false,
      'error_message', 'Una entrega sin costo no admite precio manual — son modos distintos.'
    );
  end if;

  select bool_or(nullif(elem ->> 'manual_price', '') is not null and (elem ->> 'manual_price')::numeric <= 0)
  into v_invalid_manual
  from jsonb_array_elements(p_items) elem;

  if v_invalid_manual then
    return jsonb_build_object('ok', false, 'error_message', 'El precio manual tiene que ser mayor a $0.');
  end if;

  -- -------------------------------------------------------------------------
  -- Venta sin costo: sin condición de precio, sin comisión, sin promociones,
  -- sin precio manual (ya se descartó esa combinación arriba) — precio de
  -- lista únicamente como referencia. Nunca se interpreta como "precio $0 manual".
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
        'line_surcharge', 0,
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
      'surcharge_total', 0,
      'total', 0,
      'lines', v_lines
    );
  end if;

  -- El umbral de cantidad para la condición por cantidad (2/3+ productos)
  -- solo cuenta líneas SIN precio manual — un override puntual no debe
  -- empujar al resto del carrito a otro tramo de descuento.
  select coalesce(sum((elem ->> 'quantity')::numeric), 0)
  into v_total_qty
  from jsonb_array_elements(p_items) elem
  join public.products p on p.id = (elem ->> 'product_id')::uuid
  where p.promo_eligible = true
    and nullif(elem ->> 'manual_price', '') is null;

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

  -- v_condition puede quedar sin resolver legítimamente solo si TODO el
  -- carrito tiene precio manual (no hace falta ninguna condición en ese
  -- caso) — el chequeo real de "hace falta y no hay" pasa adentro del loop,
  -- por línea, no acá arriba.

  for v_line in
    select
      ti.product_id,
      p.sku,
      p.name,
      p.commissionable,
      ti.quantity,
      ti.manual_price,
      list_price.amount as list_unit_price,
      sale_price.amount as sale_unit_price
    from (
      select
        (elem ->> 'product_id')::uuid as product_id,
        (elem ->> 'quantity')::numeric as quantity,
        nullif(elem ->> 'manual_price', '')::numeric as manual_price
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
    if v_line.manual_price is not null then
      -- Precio editado a mano: ignora price_conditions por completo. El
      -- precio de lista queda solo como referencia para mostrar el
      -- "descuento"/"recargo" en el resumen — si el producto ni siquiera
      -- tiene lista cargada, se usa el propio precio manual (sin referencia
      -- = ni descuento ni recargo que mostrar, no es un error). Un admin
      -- puede legítimamente editar a mano un precio por ENCIMA de lista
      -- (mismo criterio que cualquier condición de pago).
      v_line.list_unit_price := coalesce(v_line.list_unit_price, v_line.manual_price);
      v_subtotal := v_subtotal + (v_line.list_unit_price * v_line.quantity);

      v_manual_lines := v_manual_lines || jsonb_build_object(
        'product_id', v_line.product_id,
        'sku', v_line.sku,
        'name', v_line.name,
        'quantity', v_line.quantity,
        'list_unit_price', v_line.list_unit_price,
        'sale_unit_price', v_line.manual_price,
        'line_list_total', round(v_line.list_unit_price * v_line.quantity, 2),
        'line_discount', round(greatest((v_line.list_unit_price - v_line.manual_price) * v_line.quantity, 0), 2),
        'line_surcharge', round(greatest((v_line.manual_price - v_line.list_unit_price) * v_line.quantity, 0), 2),
        'line_total', round(v_line.manual_price * v_line.quantity, 2),
        'commissionable', v_line.commissionable,
        'applied_price_condition_id', null,
        'applied_promotion_id', null,
        'promotion_discount', 0,
        'manual_price', true
      );
    else
      if v_condition is null then
        return jsonb_build_object('ok', false, 'error_message', 'No hay ninguna condición de precio activa configurada.');
      end if;

      if v_line.sale_unit_price is null then
        return jsonb_build_object(
          'ok', false,
          'error_message', format('Este producto no tiene precio configurado para %s: %s.', v_condition.name, v_line.name)
        );
      end if;

      v_line.list_unit_price := coalesce(v_line.list_unit_price, v_line.sale_unit_price);
      v_subtotal := v_subtotal + (v_line.list_unit_price * v_line.quantity);

      -- Una condición de pago más cara que Lista (ej. cuotas) es un recargo
      -- comercial VÁLIDO, no un error — line_discount y line_surcharge son
      -- complementarios, nunca los dos > 0 en la misma línea.
      v_auto_lines := v_auto_lines || jsonb_build_object(
        'product_id', v_line.product_id,
        'sku', v_line.sku,
        'name', v_line.name,
        'quantity', v_line.quantity,
        'list_unit_price', v_line.list_unit_price,
        'sale_unit_price', v_line.sale_unit_price,
        'line_list_total', round(v_line.list_unit_price * v_line.quantity, 2),
        'line_discount', round(greatest((v_line.list_unit_price - v_line.sale_unit_price) * v_line.quantity, 0), 2),
        'line_surcharge', round(greatest((v_line.sale_unit_price - v_line.list_unit_price) * v_line.quantity, 0), 2),
        'line_total', round(v_line.sale_unit_price * v_line.quantity, 2),
        'commissionable', v_line.commissionable,
        'applied_price_condition_id', v_condition.id
      );
    end if;
  end loop;

  -- Promociones: se evalúan solo sobre las líneas SIN precio manual — un
  -- override puntual no participa como candidata de 3x2/duo%/kit%, ni
  -- cuenta para el umbral de cantidad de otro producto.
  v_promo_result := public.fn_apply_promotions(v_auto_lines, p_sold_at);
  v_lines := v_manual_lines || (v_promo_result -> 'lines');

  -- discount_total/surcharge_total SIEMPRE sumados desde las líneas ya
  -- clampeadas — nunca derivados como subtotal-total (esa resta no puede
  -- representar un recargo: rompería en cuanto total > subtotal).
  select
    coalesce(sum((elem ->> 'line_total')::numeric), 0),
    coalesce(sum((elem ->> 'line_discount')::numeric), 0),
    coalesce(sum((elem ->> 'line_surcharge')::numeric), 0)
  into v_total, v_discount, v_surcharge
  from jsonb_array_elements(v_lines) elem;

  -- v_condition resuelve a una condición real (típicamente Lista) aunque el
  -- carrito sea 100% manual — la búsqueda no depende de que haya líneas
  -- auto. Si NINGUNA línea la usó de verdad, mostrarla en la respuesta sería
  -- engañoso (un reporte que agrupe por applied_price_condition_id le
  -- atribuiría la venta a una condición que nunca se aplicó).
  if jsonb_array_length(v_auto_lines) = 0 then
    return jsonb_build_object(
      'ok', true,
      'error_message', null,
      'applied_price_condition_id', null,
      'applied_price_condition_code', null,
      'applied_price_condition_name', null,
      'explanation', 'Precio manual',
      'subtotal', round(v_subtotal, 2),
      'discount_total', round(v_discount, 2),
      'surcharge_total', round(v_surcharge, 2),
      'total', round(v_total, 2),
      'lines', v_lines
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'error_message', null,
    'applied_price_condition_id', v_condition.id,
    'applied_price_condition_code', v_condition.code,
    'applied_price_condition_name', v_condition.name,
    'explanation', case
      when v_has_manual then format('%s + precio manual', v_condition.name)
      when v_condition.rule_type = 'BASE' then 'Precio lista'
      when v_condition.discount_percent is not null and v_condition.discount_percent > 0
        then format('%s — %s%% OFF', v_condition.name, round(v_condition.discount_percent * 100))
      else v_condition.name
    end,
    'subtotal', round(v_subtotal, 2),
    'discount_total', round(v_discount, 2),
    'surcharge_total', round(v_surcharge, 2),
    'total', round(v_total, 2),
    'lines', v_lines
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 2) fn_apply_promotions
-- ---------------------------------------------------------------------------
create or replace function public.fn_apply_promotions(
  p_lines jsonb,
  p_sold_at timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_missing_product text;
  v_result jsonb;
begin
  with cart as (
    select (elem ->> 'product_id')::uuid as product_id, (elem ->> 'quantity')::numeric as quantity
    from jsonb_array_elements(p_lines) elem
  ),
  active_promos as (
    select * from public.promotions
    where active = true and valid_from <= p_sold_at and (valid_until is null or valid_until > p_sold_at)
  ),
  promo_products_agg as (
    select promotion_id, array_agg(product_id) as product_ids
    from public.promotion_products
    group by promotion_id
  ),
  matches as (
    select ap.id, ap.type, ap.price_condition_id, ap.priority, ap.stackable, ppa.product_ids,
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
  exclusive_winner as (
    select id from matches where is_match and stackable = false order by priority asc limit 1
  ),
  winners as (
    select m.* from matches m
    where m.is_match
      and (
        (exists (select 1 from exclusive_winner) and m.id = (select id from exclusive_winner))
        or (not exists (select 1 from exclusive_winner) and m.stackable = true)
      )
  )
  select p.name into v_missing_product
  from winners w
  join cart c on c.product_id = any (w.product_ids)
  join public.products p on p.id = c.product_id
  where not exists (
    select 1 from public.product_prices pp
    where pp.product_id = c.product_id
      and pp.price_condition_id = w.price_condition_id
      and pp.active = true
      and pp.amount > 0
      and pp.valid_from <= p_sold_at
      and (pp.valid_until is null or pp.valid_until > p_sold_at)
  )
  limit 1;

  if v_missing_product is not null then
    raise exception
      'La promoción no tiene precio configurado para su condición base en este producto: %.',
      v_missing_product;
  end if;

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
      (elem ->> 'line_surcharge')::numeric as line_surcharge,
      (elem ->> 'line_total')::numeric as line_total,
      (elem ->> 'commissionable')::boolean as commissionable,
      nullif(elem ->> 'applied_price_condition_id', '')::uuid as applied_price_condition_id
    from jsonb_array_elements(p_lines) elem
  ),
  active_promos as (
    select * from public.promotions
    where active = true and valid_from <= p_sold_at and (valid_until is null or valid_until > p_sold_at)
  ),
  promo_products_agg as (
    select promotion_id, array_agg(product_id) as product_ids
    from public.promotion_products
    group by promotion_id
  ),
  matches as (
    select
      ap.id, ap.type, ap.price_condition_id, ap.discount_percent, ap.group_size, ap.priority, ap.stackable,
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
  exclusive_winner as (
    select id from matches where is_match and stackable = false order by priority asc limit 1
  ),
  winners as (
    select m.* from matches m
    where m.is_match
      and (
        (exists (select 1 from exclusive_winner) and m.id = (select id from exclusive_winner))
        or (not exists (select 1 from exclusive_winner) and m.stackable = true)
      )
  ),
  promo_base_prices as (
    select
      w.id as promotion_id,
      c.product_id,
      (
        select pp.amount
        from public.product_prices pp
        where pp.product_id = c.product_id
          and pp.price_condition_id = w.price_condition_id
          and pp.active = true
          and pp.amount > 0
          and pp.valid_from <= p_sold_at
          and (pp.valid_until is null or pp.valid_until > p_sold_at)
        order by pp.valid_from desc
        limit 1
      ) as promo_unit_price
    from winners w
    join cart c on c.product_id = any (w.product_ids)
  ),
  t2_units as (
    select w.id as promotion_id, c.product_id, pbp.promo_unit_price, gs as unit_idx
    from winners w
    join cart c on c.product_id = any (w.product_ids)
    join promo_base_prices pbp on pbp.promotion_id = w.id and pbp.product_id = c.product_id
    cross join lateral generate_series(1, c.quantity::int) as gs
    where w.type = 'THREE_FOR_TWO'
  ),
  t2_ranked as (
    select
      *,
      row_number() over (partition by promotion_id order by promo_unit_price asc, product_id asc, unit_idx asc) as rn
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
  duo_resolved as (
    select
      w.id as promotion_id,
      w.price_condition_id,
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
  kit_resolved as (
    select w.id as promotion_id, w.price_condition_id, w.discount_percent, unnest(w.product_ids) as product_id
    from winners w
    where w.type = 'KIT_PERCENT'
  ),
  sub_lines as (
    -- 3x2 — unidades pagas del remanente (fuera de las gratis): la condición
    -- base de la promo puede ser más cara que Lista, así que descuento/recargo
    -- van clampeados y son complementarios, igual que en cualquier otra línea.
    select
      c.product_id, c.sku, c.name, (c.quantity - t2.free_units) as quantity,
      c.list_unit_price, pbp.promo_unit_price as sale_unit_price,
      round(c.list_unit_price * (c.quantity - t2.free_units), 2) as line_list_total,
      round(greatest((c.list_unit_price - pbp.promo_unit_price) * (c.quantity - t2.free_units), 0), 2) as line_discount,
      round(greatest((pbp.promo_unit_price - c.list_unit_price) * (c.quantity - t2.free_units), 0), 2) as line_surcharge,
      round(pbp.promo_unit_price * (c.quantity - t2.free_units), 2) as line_total,
      c.commissionable, w.price_condition_id as applied_price_condition_id,
      null::uuid as applied_promotion_id, 0::numeric as promotion_discount
    from cart c
    join t2_free_by_product t2 on t2.product_id = c.product_id
    join winners w on w.id = t2.promotion_id
    join promo_base_prices pbp on pbp.promotion_id = t2.promotion_id and pbp.product_id = c.product_id
    where (c.quantity - t2.free_units) > 0

    union all

    -- 3x2 — unidades gratis: SIEMPRE 100% de descuento hasta $0, nunca recargo
    -- (no depende de si la condición base era más cara que Lista o no).
    select
      c.product_id, c.sku, c.name, t2.free_units as quantity,
      c.list_unit_price, 0::numeric as sale_unit_price,
      round(c.list_unit_price * t2.free_units, 2) as line_list_total,
      round(c.list_unit_price * t2.free_units, 2) as line_discount,
      0::numeric as line_surcharge,
      0::numeric as line_total,
      c.commissionable, w.price_condition_id as applied_price_condition_id,
      t2.promotion_id as applied_promotion_id,
      round(pbp.promo_unit_price * t2.free_units, 2) as promotion_discount
    from cart c
    join t2_free_by_product t2 on t2.product_id = c.product_id
    join winners w on w.id = t2.promotion_id
    join promo_base_prices pbp on pbp.promotion_id = t2.promotion_id and pbp.product_id = c.product_id
    where t2.free_units > 0

    union all

    -- duo% — remanente fuera de la pareja, al precio base de la promo.
    select
      c.product_id, c.sku, c.name, (c.quantity - d.duo_count) as quantity,
      c.list_unit_price, pbp.promo_unit_price as sale_unit_price,
      round(c.list_unit_price * (c.quantity - d.duo_count), 2) as line_list_total,
      round(greatest((c.list_unit_price - pbp.promo_unit_price) * (c.quantity - d.duo_count), 0), 2) as line_discount,
      round(greatest((pbp.promo_unit_price - c.list_unit_price) * (c.quantity - d.duo_count), 0), 2) as line_surcharge,
      round(pbp.promo_unit_price * (c.quantity - d.duo_count), 2) as line_total,
      c.commissionable, d.price_condition_id as applied_price_condition_id,
      null::uuid as applied_promotion_id, 0::numeric as promotion_discount
    from cart c
    join duo_resolved d on c.product_id in (d.product_a, d.product_b)
    join promo_base_prices pbp on pbp.promotion_id = d.promotion_id and pbp.product_id = c.product_id
    where (c.quantity - d.duo_count) > 0

    union all

    -- duo% — pareja con el % de descuento aplicado. Si la condición base ya
    -- era más cara que Lista, el % puede no alcanzar a bajarla de Lista —
    -- ahí queda como recargo (clampeado), nunca como descuento negativo.
    select
      c.product_id, c.sku, c.name, d.duo_count as quantity,
      c.list_unit_price, round(pbp.promo_unit_price * (1 - d.discount_percent), 2) as sale_unit_price,
      round(c.list_unit_price * d.duo_count, 2) as line_list_total,
      round(greatest((c.list_unit_price - round(pbp.promo_unit_price * (1 - d.discount_percent), 2)) * d.duo_count, 0), 2)
        as line_discount,
      round(greatest((round(pbp.promo_unit_price * (1 - d.discount_percent), 2) - c.list_unit_price) * d.duo_count, 0), 2)
        as line_surcharge,
      round(round(pbp.promo_unit_price * (1 - d.discount_percent), 2) * d.duo_count, 2) as line_total,
      c.commissionable, d.price_condition_id as applied_price_condition_id,
      d.promotion_id as applied_promotion_id,
      round(pbp.promo_unit_price * d.discount_percent * d.duo_count, 2) as promotion_discount
    from cart c
    join duo_resolved d on c.product_id in (d.product_a, d.product_b)
    join promo_base_prices pbp on pbp.promotion_id = d.promotion_id and pbp.product_id = c.product_id
    where d.duo_count > 0

    union all

    -- kit%: toda la cantidad, a precio reducido sobre la condición base de la
    -- promo — mismo clamp: si la base ya era más cara que Lista y el % no
    -- alcanza a compensarlo, queda como recargo, nunca como descuento negativo.
    select
      c.product_id, c.sku, c.name, c.quantity,
      c.list_unit_price, round(pbp.promo_unit_price * (1 - k.discount_percent), 2) as sale_unit_price,
      c.line_list_total,
      round(greatest((c.list_unit_price - round(pbp.promo_unit_price * (1 - k.discount_percent), 2)) * c.quantity, 0), 2)
        as line_discount,
      round(greatest((round(pbp.promo_unit_price * (1 - k.discount_percent), 2) - c.list_unit_price) * c.quantity, 0), 2)
        as line_surcharge,
      round(round(pbp.promo_unit_price * (1 - k.discount_percent), 2) * c.quantity, 2) as line_total,
      c.commissionable, k.price_condition_id as applied_price_condition_id,
      k.promotion_id as applied_promotion_id,
      round(pbp.promo_unit_price * k.discount_percent * c.quantity, 2) as promotion_discount
    from cart c
    join kit_resolved k on k.product_id = c.product_id
    join promo_base_prices pbp on pbp.promotion_id = k.promotion_id and pbp.product_id = c.product_id

    union all

    -- Sin promoción: ya viene calculado y clampeado desde fn_pricing_quote,
    -- se pasa tal cual (line_surcharge incluido).
    select
      c.product_id, c.sku, c.name, c.quantity, c.list_unit_price, c.sale_unit_price,
      c.line_list_total, c.line_discount, c.line_surcharge, c.line_total, c.commissionable, c.applied_price_condition_id,
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
      'line_list_total', line_list_total, 'line_discount', line_discount, 'line_surcharge', line_surcharge,
      'line_total', line_total,
      'commissionable', commissionable, 'applied_price_condition_id', applied_price_condition_id,
      'applied_promotion_id', applied_promotion_id, 'promotion_discount', promotion_discount,
      'manual_price', false
    )), '[]'::jsonb),
    'promotion_discount_total', coalesce(sum(promotion_discount), 0)
  )
  into v_result
  from sub_lines;

  return v_result;
end;
$$;

comment on function public.fn_apply_promotions(jsonb, timestamptz) is
  'No acumulable con price_conditions: cada producto alcanzado por una promoción ganadora usa '
  'EXCLUSIVAMENTE el precio bajo promotions.price_condition_id (nunca el resuelto por medio de '
  'pago/cantidad). Rechaza la venta si falta ese precio en vez de mezclar reglas comerciales. '
  'line_discount/line_surcharge son complementarios y siempre >= 0 (GREATEST clampeado) — una '
  'condición base de promo más cara que Lista, o un % que no alcanza a bajarla de Lista, queda '
  'como recargo, nunca como descuento negativo.';

-- ---------------------------------------------------------------------------
-- 3) fn_create_sale_core — misma firma, agrega surcharge_total/line_surcharge
--    al INSERT (viene de v_quote, ya calculado por fn_pricing_quote).
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
  p_free_sale_notes text default null,
  p_skip_stock_movement boolean default false,
  p_payment_account_id uuid default null
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
  v_payment_method_code text;
  v_requires_billing boolean;
  v_billing_status public.sale_billing_status;
  v_payment_account_id uuid;
begin
  if not exists (select 1 from public.stock_locations where id = p_location_id and active) then
    raise exception 'La sucursal seleccionada no existe o está inactiva.';
  end if;

  if not exists (select 1 from public.sales_channels where id = p_sales_channel_id and active) then
    raise exception 'El canal de venta seleccionado no existe o está inactivo.';
  end if;

  select code into v_payment_method_code from public.payment_methods where id = p_payment_method_id and active;
  if v_payment_method_code is null then
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

  if p_sold_at < now() - interval '1 hour' and not public.is_admin() then
    raise exception 'Solo un administrador puede cargar una venta con fecha anterior.';
  end if;

  if p_skip_stock_movement and not public.is_admin() then
    raise exception 'Solo un administrador puede cargar una venta sin descontar stock.';
  end if;

  if p_skip_stock_movement and p_is_free_sale then
    raise exception 'Una entrega sin costo siempre descuenta stock — no se puede combinar con carga histórica.';
  end if;

  v_requires_billing := not p_is_free_sale and v_payment_method_code in ('TRANSFER', 'CARD_1', 'CARD_3');

  if v_requires_billing then
    if p_payment_account_id is null or not exists (
      select 1 from public.payment_accounts where id = p_payment_account_id and active
    ) then
      raise exception 'Esta forma de pago requiere indicar la cuenta donde ingresó el dinero.';
    end if;

    if p_customer_id is null or not exists (
      select 1 from public.customers
      where id = p_customer_id and dni is not null and trim(dni) <> ''
    ) then
      raise exception
        'Esta operación se puede facturar, así que necesita un cliente identificado con nombre y DNI.';
    end if;

    v_payment_account_id := p_payment_account_id;
    v_billing_status := 'PENDING';
  else
    v_payment_account_id := null;
    v_billing_status := 'NOT_REQUIRED';
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
    subtotal, discount_total, surcharge_total, total, commission_total, status,
    external_source, external_order_id, notes,
    is_free_sale, free_sale_reason, free_sale_notes, stock_skipped,
    payment_account_id, billing_status
  ) values (
    v_sale_number, p_sold_at, p_location_id, p_sales_channel_id, p_seller_id,
    p_customer_id, p_doctor_id, p_payment_method_id, (v_quote ->> 'applied_price_condition_id')::uuid,
    (v_quote ->> 'subtotal')::numeric, (v_quote ->> 'discount_total')::numeric,
    coalesce((v_quote ->> 'surcharge_total')::numeric, 0),
    (v_quote ->> 'total')::numeric, v_commission_total, 'confirmed',
    p_external_source, p_external_order_id, p_notes,
    p_is_free_sale, p_free_sale_reason, p_free_sale_notes, p_skip_stock_movement,
    v_payment_account_id, v_billing_status
  )
  returning id into v_sale_id;

  for v_line in select * from jsonb_array_elements(v_quote -> 'lines')
  loop
    insert into public.sale_items (
      sale_id, product_id, quantity, list_unit_price, sale_unit_price,
      line_list_total, line_discount, line_surcharge, line_total, applied_price_condition_id, commissionable,
      applied_promotion_id, promotion_discount
    ) values (
      v_sale_id,
      (v_line ->> 'product_id')::uuid,
      (v_line ->> 'quantity')::numeric,
      (v_line ->> 'list_unit_price')::numeric,
      (v_line ->> 'sale_unit_price')::numeric,
      (v_line ->> 'line_list_total')::numeric,
      (v_line ->> 'line_discount')::numeric,
      coalesce((v_line ->> 'line_surcharge')::numeric, 0),
      (v_line ->> 'line_total')::numeric,
      nullif(v_line ->> 'applied_price_condition_id', '')::uuid,
      (v_line ->> 'commissionable')::boolean,
      nullif(v_line ->> 'applied_promotion_id', '')::uuid,
      coalesce((v_line ->> 'promotion_discount')::numeric, 0)
    );
  end loop;

  if not p_skip_stock_movement then
    for v_required in
      with items as (
        select id as sale_item_id, product_id, quantity
        from public.sale_items
        where sale_id = v_sale_id
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
        p_allow_negative => v_allow_negative,
        p_source_sale_item_id => v_required.sale_item_id
      );
    end loop;
  end if;

  return jsonb_build_object(
    'sale_id', v_sale_id,
    'sale_number', v_sale_number,
    'total', (v_quote ->> 'total')::numeric,
    'subtotal', (v_quote ->> 'subtotal')::numeric,
    'discount_total', (v_quote ->> 'discount_total')::numeric,
    'surcharge_total', coalesce((v_quote ->> 'surcharge_total')::numeric, 0),
    'commission_total', v_commission_total,
    'applied_price_condition_name', v_quote ->> 'applied_price_condition_name',
    'explanation', v_quote ->> 'explanation',
    'is_free_sale', p_is_free_sale,
    'stock_skipped', p_skip_stock_movement,
    'billing_status', v_billing_status,
    'lines', v_quote -> 'lines'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) fn_exchange_new_item_price — misma firma, agrega line_surcharge.
-- ---------------------------------------------------------------------------
create or replace function public.fn_exchange_new_item_price(
  p_product_id uuid,
  p_quantity numeric,
  p_payment_method_id uuid,
  p_sold_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_condition public.price_conditions;
  v_list_price numeric;
  v_sale_price numeric;
begin
  if p_quantity is null or p_quantity <= 0 then
    return jsonb_build_object('ok', false, 'error_message', 'La cantidad tiene que ser mayor a 0.');
  end if;

  if not exists (select 1 from public.products where id = p_product_id and active = true) then
    return jsonb_build_object('ok', false, 'error_message', 'El producto nuevo no existe o está inactivo.');
  end if;

  select * into v_condition
  from public.price_conditions
  where rule_type = 'PAYMENT_METHOD' and payment_method_id = p_payment_method_id and active = true
  order by priority asc
  limit 1;

  if v_condition is null then
    return jsonb_build_object(
      'ok', false,
      'error_message', 'No hay una condición de precio configurada para la forma de pago de la venta original.'
    );
  end if;

  select pp.amount into v_sale_price
  from public.product_prices pp
  where pp.product_id = p_product_id
    and pp.price_condition_id = v_condition.id
    and pp.active = true
    and pp.amount > 0
    and pp.valid_from <= p_sold_at
    and (pp.valid_until is null or pp.valid_until > p_sold_at)
  order by pp.valid_from desc
  limit 1;

  if v_sale_price is null then
    return jsonb_build_object(
      'ok', false,
      'error_message', format('El producto nuevo no tiene precio configurado para %s.', v_condition.name)
    );
  end if;

  select pp.amount into v_list_price
  from public.product_prices pp
  join public.price_conditions lc on lc.id = pp.price_condition_id and lc.rule_type = 'BASE'
  where pp.product_id = p_product_id
    and pp.active = true
    and pp.amount > 0
    and pp.valid_from <= p_sold_at
    and (pp.valid_until is null or pp.valid_until > p_sold_at)
  order by pp.valid_from desc
  limit 1;

  v_list_price := coalesce(v_list_price, v_sale_price);

  return jsonb_build_object(
    'ok', true,
    'error_message', null,
    'product_id', p_product_id,
    'quantity', p_quantity,
    'applied_price_condition_id', v_condition.id,
    'applied_price_condition_code', v_condition.code,
    'applied_price_condition_name', v_condition.name,
    'list_unit_price', v_list_price,
    'sale_unit_price', v_sale_price,
    'line_list_total', round(v_list_price * p_quantity, 2),
    'line_discount', round(greatest((v_list_price - v_sale_price) * p_quantity, 0), 2),
    'line_surcharge', round(greatest((v_sale_price - v_list_price) * p_quantity, 0), 2),
    'line_total', round(v_sale_price * p_quantity, 2)
  );
end;
$$;

grant execute on function public.fn_exchange_new_item_price(uuid, numeric, uuid, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 5) create_sale_exchange — misma firma, agrega surcharge_total/line_surcharge.
--    Para líneas copiadas/remanente (snapshot histórico): line_surcharge se
--    CALCULA desde list_unit_price/sale_unit_price/quantity ya guardados
--    (nunca se repriza, solo se deriva el campo nuevo de datos que ya
--    existían) — mismo criterio que line_discount, que ya se recalculaba así.
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
  select quantity into v_root_quantity from public.sale_items where id = v_physical_source_id;

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

  -- Líneas no tocadas: copiadas verbatim, con line_surcharge DERIVADO desde
  -- su propio snapshot (list_unit_price/sale_unit_price/quantity) — nunca
  -- repreciadas, solo se completa el campo nuevo desde datos que ya existían.
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
    'physical_source_sale_item_id', null
  );

  -- subtotal/discount_total/surcharge_total/total SIEMPRE sumados desde las
  -- líneas ya construidas — nunca derivados por resta.
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
      applied_promotion_id, promotion_discount, physical_source_sale_item_id
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
      nullif(v_line ->> 'physical_source_sale_item_id', '')::uuid
    )
    returning id into v_new_sale_item_id;

    if v_line ->> 'role' = 'new' then
      v_new_line_item_id := v_new_sale_item_id;
    end if;
  end loop;

  for v_movement in
    select location_id, product_id, quantity_delta
    from public.stock_movements
    where movement_type = 'SALE'
      and source_sale_item_id = v_physical_source_id
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

grant execute on function public.create_sale_exchange(uuid, uuid, numeric, uuid, numeric, text) to authenticated;
