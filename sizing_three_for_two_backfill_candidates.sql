-- =============================================================================
-- Sizing de solo lectura — candidatos a backfill histórico THREE_FOR_TWO
-- =============================================================================
-- SOLO LECTURA. Ningún UPDATE/INSERT/DELETE. No es una migración — no forma
-- parte de supabase/migrations/, se corre una vez a mano en el SQL Editor de
-- Supabase para ver el volumen real antes de decidir sobre la migración 065
-- (backfill histórico), que todavía NO está escrita ni aprobada.
--
-- Qué hace: busca, para cada venta con una línea "ancla" de un 3x2 (la
-- unidad gratis, que SIEMPRE tuvo applied_promotion_id correctamente seteado
-- — nunca fue parte del bug), las líneas "huérfanas" de la MISMA venta
-- (applied_promotion_id = null) que comparten el MISMO applied_price_condition_id
-- que el ancla — la señal de correlación histórica más fuerte disponible sin
-- depender de la composición ACTUAL de promotion_products (que puede no
-- representar la situación histórica).
--
-- Clasificación (nunca adivina — ver "motivo" en el detalle):
--   REPARABLE_INEQUIVOCAMENTE: exactamente 1 promoción-ancla en esa venta
--     para ese price_condition, y ese price_condition NO coincide con el que
--     hubiera resuelto el medio de pago normal de la venta.
--   HEURISTICA: cumple lo anterior salvo que el price_condition del ancla
--     coincide con el que resuelve el medio de pago normal de la venta — no
--     se puede distinguir con certeza matemática de una línea sin promoción.
--   AMBIGUA: más de una promoción-ancla comparte ese price_condition en la
--     misma venta — no se puede saber a cuál pertenece la línea huérfana.
--
-- AJUSTAR p_cutoff_at a la fecha/hora (UTC) INMEDIATAMENTE ANTERIOR al
-- momento en que se aplique la migración 064 en producción — así se excluyen
-- estructuralmente las ventas ya correctas creadas DESPUÉS del fix (su
-- "excedente" sin applied_promotion_id es comportamiento correcto, no un
-- caso a reparar).
-- =============================================================================
with params as (
  select '2026-09-08 23:59:59+00'::timestamptz as p_cutoff_at  -- <<< AJUSTAR
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
-- 1) RESUMEN por promoción y clasificación
-- ---------------------------------------------------------------------------
select
  p.code as promotion_code,
  p.name as promotion_name,
  cl.classification,
  count(distinct cl.sale_id) as ventas_afectadas,
  count(*) as lineas_candidatas
from classified cl
join public.promotions p on p.id = cl.promotion_id
group by p.code, p.name, cl.classification
order by p.code, cl.classification;
