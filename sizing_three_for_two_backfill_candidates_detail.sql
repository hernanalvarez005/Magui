-- =============================================================================
-- Sizing de solo lectura — DETALLE venta por venta (parte 2/2)
-- =============================================================================
-- Misma lógica exacta que sizing_three_for_two_backfill_candidates.sql (el
-- resumen) — correr ESE PRIMERO, este es el detalle. SOLO LECTURA, ningún
-- UPDATE/INSERT/DELETE. Ajustar p_cutoff_at al MISMO valor que usaste en el
-- resumen.
--
-- Supabase SQL Editor solo muestra el resultado del ÚLTIMO select de un
-- script — por eso el resumen y el detalle son dos archivos separados, para
-- poder correr cada uno y ver su resultado completo.
-- =============================================================================
with params as (
  select '2026-09-08 23:59:59+00'::timestamptz as p_cutoff_at  -- <<< AJUSTAR (mismo valor que el resumen)
),
anchors as (
  select
    si.id as anchor_item_id, si.sale_id, si.applied_promotion_id as promotion_id,
    si.applied_price_condition_id, si.promotion_name_snapshot, si.promotion_type_snapshot,
    s.sold_at, s.sale_number, s.location_id, s.total as sale_total, s.payment_method_id
  from public.sale_items si
  join public.sales s on s.id = si.sale_id
  join public.promotions p on p.id = si.applied_promotion_id
  cross join params
  where p.type = 'THREE_FOR_TWO'
    and si.sale_unit_price = 0
    and s.status = 'confirmed'
    and s.sold_at < params.p_cutoff_at
),
candidates as (
  select
    a.anchor_item_id, a.sale_id, a.promotion_id, a.applied_price_condition_id,
    a.sold_at, a.sale_number, a.location_id, a.sale_total, a.payment_method_id,
    si.id as candidate_item_id, si.product_id, si.quantity, si.sale_unit_price, si.line_total
  from anchors a
  join public.sale_items si
    on si.sale_id = a.sale_id
   and si.applied_promotion_id is null
   and si.applied_price_condition_id = a.applied_price_condition_id
),
sale_signature as (
  select sale_id, applied_price_condition_id, count(distinct promotion_id) as distinct_promos
  from anchors
  group by sale_id, applied_price_condition_id
),
payment_method_condition as (
  select s.id as sale_id, pc.id as payment_price_condition_id
  from public.sales s
  join public.price_conditions pc on pc.payment_method_id = s.payment_method_id and pc.rule_type = 'PAYMENT_METHOD'
),
classified as (
  select
    c.*,
    ss.distinct_promos,
    pmc.payment_price_condition_id,
    case
      when ss.distinct_promos > 1 then 'AMBIGUA'
      when pmc.payment_price_condition_id = c.applied_price_condition_id then 'HEURISTICA'
      else 'REPARABLE_INEQUIVOCAMENTE'
    end as classification,
    case
      when ss.distinct_promos > 1 then
        format(
          '%s promociones 3x2 distintas comparten applied_price_condition_id en la misma venta — no se puede saber a cuál pertenece esta línea',
          ss.distinct_promos
        )
      when pmc.payment_price_condition_id = c.applied_price_condition_id then
        'El price_condition del ancla coincide con el que hubiera resuelto el medio de pago normal de la venta — no se puede distinguir con certeza de una línea sin promoción'
      else
        'Único ancla 3x2 en la venta para ese price_condition, y no coincide con el price_condition del medio de pago normal — correlación inequívoca'
    end as classification_reason
  from candidates c
  join sale_signature ss on ss.sale_id = c.sale_id and ss.applied_price_condition_id = c.applied_price_condition_id
  left join payment_method_condition pmc on pmc.sale_id = c.sale_id
)
-- ---------------------------------------------------------------------------
-- 2) DETALLE venta por venta — una fila por (venta, promoción); las líneas
--    candidatas pagas de esa venta quedan agregadas en un array jsonb.
-- ---------------------------------------------------------------------------
select
  p.code as promotion_code,
  p.name as promotion_name,
  cl.classification,
  min(cl.classification_reason) as classification_reason,
  cl.sale_id,
  cl.sale_number,
  cl.sold_at::date as sale_date,
  loc.name as location_name,
  cl.sale_total,
  cl.anchor_item_id as anchor_free_line_id,
  jsonb_agg(
    jsonb_build_object(
      'sale_item_id', cl.candidate_item_id,
      'product_id', cl.product_id,
      'quantity', cl.quantity,
      'sale_unit_price', cl.sale_unit_price,
      'line_total', cl.line_total
    )
    order by cl.candidate_item_id
  ) as candidate_paying_lines,
  cl.applied_price_condition_id
from classified cl
join public.promotions p on p.id = cl.promotion_id
left join public.stock_locations loc on loc.id = cl.location_id
group by
  p.code, p.name, cl.classification, cl.sale_id, cl.sale_number, cl.sold_at, loc.name,
  cl.sale_total, cl.anchor_item_id, cl.applied_price_condition_id
order by p.code, cl.classification, cl.sold_at, cl.sale_id;
