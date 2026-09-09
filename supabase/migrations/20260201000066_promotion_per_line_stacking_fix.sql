-- =============================================================================
-- Maguirejuve · 66 · Promociones: ganador por producto contestado, no por venta
-- =============================================================================
-- NUMERACIÓN: sigue a la migración 64. El "65" no se usa acá — ya identifica,
-- en el historial de este proyecto, el backfill quirúrgico histórico
-- (PROD_HISTORICAL_BACKFILL_065_three_for_two.sql, deliberadamente fuera de
-- supabase/migrations/) — se salta para no tener dos cosas distintas con el
-- mismo número en la conversación del equipo.
--
-- CORRECCIÓN DE REGLA DE NEGOCIO (auditoría previa, aprobada por el usuario):
-- "Las promociones pueden convivir dentro de una misma venta cuando afectan
-- productos o unidades diferentes. Lo que NO debe acumularse con una
-- promoción es la condición de precio por forma de pago. La regla debe
-- evaluarse por línea/unidad comercial, no a nivel de venta completa."
--
-- CAUSA RAÍZ (auditada, no es una regresión no advertida — estaba documentada
-- así desde el origen del motor, 20260201000010_promotions_schema.sql:15-23,
-- y reconfirmada sin cuestionarla en 20260201000063_promotion_payment_methods.sql:40-44):
-- `exclusive_winner` elegía UN ÚNICO ganador para TODA LA VENTA entre las
-- promociones no-stackable que matcheaban — si alguna no-stackable matcheaba
-- (que es el valor por defecto de toda promoción nueva, ver el checkbox
-- "Combinable con otras promociones" en promotion-form-dialog.tsx,
-- default=false), se convertía en la ÚNICA promoción aplicada a TODA la
-- venta, y cualquier otra promoción — aunque matcheara productos totalmente
-- distintos, sin ninguna superposición real — quedaba descartada por
-- completo; sus productos caían al bucket "sin promoción" y recibían la
-- condición de precio del medio de pago en vez de su propio precio
-- promocional. Evidencia concreta ya en la suite antes de esta migración:
-- supabase/tests/database/promotions.test.sql (caso "No-stackable (3x2)
-- excluye a la stackable (duo)...") — un 3x2 sobre PROD-ESP/PROD-ANTI y un
-- duo% sobre PROD-NIAC/PROD-VITC (CERO productos en común) en el mismo
-- carrito: el duo quedaba completamente anulado. Ese caso se actualiza junto
-- con esta migración porque su expectativa vieja queda incorrecta.
--
-- POR QUÉ ESTO NUNCA HIZO FALTA (y por qué el cambio es seguro): un producto
-- no puede estar en dos promociones ACTIVAS a la vez — lo impiden dos
-- triggers desde el origen del esquema
-- (fn_check_promotion_product_exclusive / fn_check_promotion_activation_exclusive,
-- 20260201000010_promotions_schema.sql:77-137). Por construcción, dos
-- promociones activas JAMÁS comparten un producto — así que la "contienda
-- por el mismo producto" que `exclusive_winner` resolvía globalmente no
-- podía, de hecho, estar pasando nunca: lo único que ese mecanismo hacía en
-- la práctica era bloquear promociones que no competían entre sí.
--
-- FIX (opción defensiva, elegida explícitamente por el usuario sobre la
-- alternativa más simple de "confiar 100% en el trigger de escritura"): en
-- vez de un ganador único para toda la venta, se agrupan los matches que
-- efectivamente SE SUPERPONEN en al menos un product_id (`product_ids &&`,
-- operador de superposición de arrays) y, solo DENTRO de cada grupo
-- contestado, gana el de mayor prioridad (menor `priority`, con `id` como
-- desempate final determinístico — antes, un empate de `priority` entre dos
-- promociones no tenía desempate y el resultado no era determinístico; esto
-- también lo corrige de paso). Promociones sin superposición con ninguna
-- otra (el caso real, siempre, hoy) ganan directamente, sin competir con
-- nadie — exactamente lo que la regla de negocio pide. Esta capa es
-- defensa en profundidad: si alguna vez el trigger de exclusividad se
-- bypasea (ej. un insert directo con service_role), el motor de precios
-- igual nunca aplica dos promociones sobre la misma unidad — ver test de
-- este escenario en promotion_per_line_stacking.test.sql, caso 10.
--
-- QUÉ NO CAMBIA (alcance exacto aprobado): ninguna fórmula de precio,
-- descuento, recargo, line_total, etc. — se toca ÚNICAMENTE qué matches
-- entran a `winners`. El resto de la función (promo_base_prices, t2_ranked,
-- duo_resolved, kit_resolved, qty_resolved, todas las ramas de sub_lines,
-- incluida "sin promoción") es copia exacta de 20260201000064. No se toca
-- fn_pricing_quote, fn_create_sale_core, la validación de medios de pago
-- permitidos por promoción de la migración 63 (channel <> WEB se revisa
-- aparte, en otro bloque — no forma parte de este archivo), Web/fulfillment,
-- Changes ni Returns. El esquema (promotions.stackable/priority,
-- promotion_products, sus triggers de exclusividad) tampoco se toca —
-- `stackable` queda en la tabla y en la UI sin cambios; dado que la
-- contienda real por producto ya no puede ocurrir salvo bypaseando el
-- trigger, su efecto práctico pasa a ser exclusivamente el desempate
-- defensivo de esta migración (nunca vuelve a bloquear promociones sin
-- superposición real).
-- =============================================================================
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
  -- ---------------------------------------------------------------------
  -- Migración 66: ganador por GRUPO DE PRODUCTOS CONTESTADOS, no por venta
  -- completa. `overlaps` empareja matches que comparten al menos un
  -- product_id (hoy, por el trigger de exclusividad de promotion_products,
  -- esto nunca produce filas — es una capa defensiva). `losers` descarta,
  -- de cada par superpuesto, al de menor prioridad (mayor `priority`, `id`
  -- como desempate). Un match sin ninguna superposición nunca puede
  -- aparecer en `losers` — gana siempre, sin importar `stackable`.
  -- ---------------------------------------------------------------------
  promo_overlaps as (
    select m1.id, m2.id as other_id
    from matches m1
    join matches m2 on m2.id <> m1.id
    where m1.is_match and m2.is_match and m1.product_ids && m2.product_ids
  ),
  losers as (
    select o.id
    from promo_overlaps o
    join matches m1 on m1.id = o.id
    join matches m2 on m2.id = o.other_id
    where (m1.priority, m1.id) > (m2.priority, m2.id)
  ),
  winners as (
    select m.* from matches m
    where m.is_match and m.id not in (select id from losers)
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
  -- Migración 66: idéntico criterio que en el bloque de arriba — ver ese
  -- comentario. Duplicado acá porque este segundo `matches` trae columnas
  -- adicionales (discount_percent/group_size/minimum_quantity/total_eligible_qty)
  -- que las CTEs de abajo (t2_*, duo_resolved, kit_resolved, qty_resolved)
  -- necesitan de `winners` — mismo patrón que ya tenía 20260201000064.
  promo_overlaps as (
    select m1.id, m2.id as other_id
    from matches m1
    join matches m2 on m2.id <> m1.id
    where m1.is_match and m2.is_match and m1.product_ids && m2.product_ids
  ),
  losers as (
    select o.id
    from promo_overlaps o
    join matches m1 on m1.id = o.id
    join matches m2 on m2.id = o.other_id
    where (m1.priority, m1.id) > (m2.priority, m2.id)
  ),
  winners as (
    select m.* from matches m
    where m.is_match and m.id not in (select id from losers)
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
    select id as promotion_id, group_size, floor(total_eligible_qty / group_size)::int as free_total
    from winners
    where type = 'THREE_FOR_TWO'
  ),
  t2_free_by_product as (
    select
      r.promotion_id, r.product_id,
      count(*) filter (where r.rn <= ft.free_total) as free_units,
      count(*) filter (where r.rn > ft.free_total and r.rn <= ft.free_total * ft.group_size) as paying_units
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
  qty_resolved as (
    select w.id as promotion_id, w.price_condition_id, w.discount_percent, unnest(w.product_ids) as product_id
    from winners w
    where w.type = 'QUANTITY_DISCOUNT'
  ),
  sub_lines as (
    -- 3x2 — unidades PAGAS que integran un grupo completo. SIN CAMBIOS
    -- respecto de 20260201000064.
    select
      c.product_id, c.sku, c.name, t2.paying_units as quantity,
      c.list_unit_price, pbp.promo_unit_price as sale_unit_price,
      round(c.list_unit_price * t2.paying_units, 2) as line_list_total,
      round(greatest((c.list_unit_price - pbp.promo_unit_price) * t2.paying_units, 0), 2) as line_discount,
      round(greatest((pbp.promo_unit_price - c.list_unit_price) * t2.paying_units, 0), 2) as line_surcharge,
      round(pbp.promo_unit_price * t2.paying_units, 2) as line_total,
      c.commissionable, w.price_condition_id as applied_price_condition_id,
      t2.promotion_id as applied_promotion_id, 0::numeric as promotion_discount
    from cart c
    join t2_free_by_product t2 on t2.product_id = c.product_id
    join winners w on w.id = t2.promotion_id
    join promo_base_prices pbp on pbp.promotion_id = t2.promotion_id and pbp.product_id = c.product_id
    where t2.paying_units > 0

    union all

    -- 3x2 — EXCEDENTE, fuera de cualquier grupo completo. SIN CAMBIOS.
    select
      c.product_id, c.sku, c.name, (c.quantity - t2.free_units - t2.paying_units) as quantity,
      c.list_unit_price, pbp.promo_unit_price as sale_unit_price,
      round(c.list_unit_price * (c.quantity - t2.free_units - t2.paying_units), 2) as line_list_total,
      round(greatest((c.list_unit_price - pbp.promo_unit_price) * (c.quantity - t2.free_units - t2.paying_units), 0), 2)
        as line_discount,
      round(greatest((pbp.promo_unit_price - c.list_unit_price) * (c.quantity - t2.free_units - t2.paying_units), 0), 2)
        as line_surcharge,
      round(pbp.promo_unit_price * (c.quantity - t2.free_units - t2.paying_units), 2) as line_total,
      c.commissionable, w.price_condition_id as applied_price_condition_id,
      null::uuid as applied_promotion_id, 0::numeric as promotion_discount
    from cart c
    join t2_free_by_product t2 on t2.product_id = c.product_id
    join winners w on w.id = t2.promotion_id
    join promo_base_prices pbp on pbp.promotion_id = t2.promotion_id and pbp.product_id = c.product_id
    where (c.quantity - t2.free_units - t2.paying_units) > 0

    union all

    -- 3x2 — unidades gratis. SIN CAMBIOS.
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

    -- duo% — remanente fuera de la pareja. SIN CAMBIOS.
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

    -- duo% — pareja con el % de descuento aplicado. SIN CAMBIOS.
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

    -- kit%: toda la cantidad, a precio reducido sobre la condición base de
    -- la promo. SIN CAMBIOS.
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

    -- cantidad%: idéntico tratamiento unitario que kit%. SIN CAMBIOS.
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
    -- se pasa tal cual. SIN CAMBIOS.
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
  'line_discount/line_surcharge son complementarios y siempre >= 0 (GREATEST clampeado). '
  'MIGRACIÓN 66: el ganador se resuelve por GRUPO DE PRODUCTOS CONTESTADOS (overlap de '
  'product_ids), no por venta completa — varias promociones pueden convivir en la misma venta '
  'si afectan productos distintos, sin importar stackable; stackable/priority solo deciden algo '
  'cuando dos promociones activas realmente comparten un producto (hoy, únicamente si se '
  'bypasea el trigger de exclusividad de promotion_products — capa defensiva). MIGRACIÓN 64: '
  'THREE_FOR_TWO separa "pagas-en-grupo" (atribuidas a la promoción) de "excedente" (nunca '
  'atribuido) — sin cambios en esta migración. DUO_PERCENT/KIT_PERCENT/QUANTITY_DISCOUNT sin '
  'cambios de fórmula en ninguna de las dos migraciones.';
