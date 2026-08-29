-- =============================================================================
-- Maguirejuve · 34 · Precio manual por línea, exclusivo de admin
-- =============================================================================
-- Pedido: un admin tiene que poder editar a mano el precio de un producto al
-- cargar una venta (ej. un descuento puntual que no amerita crear una
-- condición de precio nueva). Va como una clave más DENTRO de cada elemento
-- de p_items ("manual_price"), no como parámetro nuevo — así ni quote_sale
-- ni create_sale cambian de firma (CREATE OR REPLACE alcanza, no hace falta
-- dropear nada).
--
-- Reglas:
--   - Exclusivo de admin. Se valida acá adentro, nunca confiando en que el
--     frontend oculte el campo (mismo criterio que backdatear una venta o
--     saltear stock — ver 20260201000015).
--   - Una línea con precio manual IGNORA por completo price_conditions: no
--     hace falta que el producto tenga precio cargado para el medio de pago
--     elegido. list_unit_price sigue siendo el precio de Lista (si existe),
--     solo como referencia para mostrar el descuento.
--   - Una línea con precio manual queda AFUERA de las promociones (3x2/duo%/
--     kit%) — ni participa como candidata, ni cuenta para el umbral de
--     cantidad de otro producto. Es un override puntual, no un precio que
--     las reglas automáticas deban seguir ajustando.
--   - No combina con "venta sin costo" (son dos modos de excepción distintos
--     con su propia auditoría — mezclarlos genera ambigüedad en los reportes).
--   - Precio manual > 0 siempre: para $0 real existe el flujo de venta sin
--     costo (motivo obligatorio, comisión forzada a 0, auditado como tal).
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
  kit_resolved as (
    select w.id as promotion_id, w.discount_percent, w.product_ids[1] as product_id
    from winners w
    where w.type = 'KIT_PERCENT'
  ),
  sub_lines as (
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
      'applied_promotion_id', applied_promotion_id, 'promotion_discount', promotion_discount,
      'manual_price', false
    )), '[]'::jsonb),
    'promotion_discount_total', coalesce(sum(promotion_discount), 0)
  )
  from sub_lines;
$$;

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
      -- "descuento" en el resumen — si el producto ni siquiera tiene lista
      -- cargada, se usa el propio precio manual (sin referencia = sin
      -- descuento que mostrar, no es un error).
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
        'line_discount', round((v_line.list_unit_price - v_line.manual_price) * v_line.quantity, 2),
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

      v_auto_lines := v_auto_lines || jsonb_build_object(
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
    end if;
  end loop;

  -- Promociones: se evalúan solo sobre las líneas SIN precio manual — un
  -- override puntual no participa como candidata de 3x2/duo%/kit%, ni
  -- cuenta para el umbral de cantidad de otro producto.
  v_promo_result := public.fn_apply_promotions(v_auto_lines, p_sold_at);
  v_lines := v_manual_lines || (v_promo_result -> 'lines');

  select coalesce(sum((elem ->> 'line_total')::numeric), 0)
  into v_total
  from jsonb_array_elements(v_lines) elem;

  v_discount := v_subtotal - v_total;

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
    'total', round(v_total, 2),
    'lines', v_lines
  );
end;
$$;

revoke execute on function public.fn_pricing_quote(jsonb, uuid, timestamptz, boolean) from public;
