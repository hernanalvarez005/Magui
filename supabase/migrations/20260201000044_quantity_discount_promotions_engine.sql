-- =============================================================================
-- Maguirejuve · 46 · Condiciones QUANTITY -> Promociones — motor (paso 3/5)
-- =============================================================================
-- fn_apply_promotions gana un cuarto tipo: QUANTITY_DISCOUNT. Mismo
-- tratamiento unitario que KIT_PERCENT (el % se aplica a TODA la cantidad
-- de cada producto ganador, no solo a un remanente) — la única diferencia
-- es la condición de match: en vez de "el producto está presente" (KIT_PERCENT)
-- o "los dos productos de la pareja están presentes" (DUO_PERCENT), acá es
-- "la SUMA de unidades entre los productos participantes >= minimum_quantity"
-- (sección 8 del pedido: cuenta unidades, no SKUs distintos — un producto no
-- participante NUNCA ayuda a alcanzar el mínimo, porque solo se suma sobre
-- cart.product_id = any(ppa.product_ids), el resto del carrito ni entra en
-- esa suma). No acumulable con nada más (mismo mecanismo exclusive_winner/
-- stackable ya existente — sección 11/12/13 del pedido, sin código nuevo).
-- Misma firma — CREATE OR REPLACE sin necesidad de DROP.
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
        when ap.type = 'QUANTITY_DISCOUNT' then
          ap.minimum_quantity is not null
          and (select coalesce(sum(c.quantity), 0) from cart c where c.product_id = any (ppa.product_ids)) >= ap.minimum_quantity
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
      ap.id, ap.type, ap.price_condition_id, ap.discount_percent, ap.group_size, ap.minimum_quantity,
      ap.priority, ap.stackable, ppa.product_ids,
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
        when ap.type = 'QUANTITY_DISCOUNT' then
          ap.minimum_quantity is not null
          and (select coalesce(sum(c.quantity), 0) from cart c where c.product_id = any (ppa.product_ids)) >= ap.minimum_quantity
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
  -- QUANTITY_DISCOUNT: mismo tratamiento unitario que kit_resolved (% sobre
  -- TODA la cantidad de cada producto ganador) — lo único distinto de KIT_PERCENT
  -- es cómo se activó el match (arriba, en `matches`), no cómo se aplica acá.
  qty_resolved as (
    select w.id as promotion_id, w.price_condition_id, w.discount_percent, unnest(w.product_ids) as product_id
    from winners w
    where w.type = 'QUANTITY_DISCOUNT'
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

    -- cantidad%: idéntico tratamiento unitario que kit% (toda la cantidad, a
    -- precio reducido sobre la condición base de la promo) — la elegibilidad
    -- (suma de unidades participantes >= minimum_quantity) ya se resolvió en
    -- `matches`/`winners`, acá solo se aplica el descuento.
    select
      c.product_id, c.sku, c.name, c.quantity,
      c.list_unit_price, round(pbp.promo_unit_price * (1 - q.discount_percent), 2) as sale_unit_price,
      c.line_list_total,
      round(greatest((c.list_unit_price - round(pbp.promo_unit_price * (1 - q.discount_percent), 2)) * c.quantity, 0), 2)
        as line_discount,
      round(greatest((round(pbp.promo_unit_price * (1 - q.discount_percent), 2) - c.list_unit_price) * c.quantity, 0), 2)
        as line_surcharge,
      round(round(pbp.promo_unit_price * (1 - q.discount_percent), 2) * c.quantity, 2) as line_total,
      c.commissionable, q.price_condition_id as applied_price_condition_id,
      q.promotion_id as applied_promotion_id,
      round(pbp.promo_unit_price * q.discount_percent * c.quantity, 2) as promotion_discount
    from cart c
    join qty_resolved q on q.product_id = c.product_id
    join promo_base_prices pbp on pbp.promotion_id = q.promotion_id and pbp.product_id = c.product_id

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
      and not exists (select 1 from qty_resolved q where q.product_id = c.product_id)
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
  'como recargo, nunca como descuento negativo. QUANTITY_DISCOUNT: la cantidad mínima se evalúa '
  'sobre la SUMA de unidades entre los productos de la promoción (nunca SKUs distintos, nunca '
  'productos no participantes) — sección 8/9 del pedido de migración QUANTITY -> Promociones.';
