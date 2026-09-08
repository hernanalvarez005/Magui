-- =============================================================================
-- Maguirejuve · 65 · Backfill histórico THREE_FOR_TWO — 4 filas conocidas
-- =============================================================================
-- IMPORTANTE — por qué este archivo NO vive en supabase/migrations/:
-- los 4 sale_item_id y las 2 sales.id de acá abajo son de PRODUCCIÓN — no
-- existen en ninguna base nueva/local/CI. Si este script fuera una migración
-- más (20260201000065_...), el rebuild-from-scratch que usamos para validar
-- toda la suite (recrear la base y aplicar las ~80 migraciones en orden)
-- fallaría siempre en este paso, en cualquier entorno que no sea la
-- producción real — rompería el mismo mecanismo que valida cada migración
-- de este proyecto. Por eso es un script de una sola ejecución manual,
-- exactamente el mismo criterio que PROD_DEPLOY_WEB_FULFILLMENT_054_062.sql:
-- se corre UNA vez, a mano, en el SQL Editor de Supabase producción — nunca
-- se agrega a supabase/migrations/, nunca se corre en un rebuild local/CI.
-- El test pgTAP que lo acompaña (three_for_two_historical_backfill.test.sql)
-- sí corre en la suite normal — arma una venta sintética CON LOS MISMOS ids
-- hardcodeados acá abajo (no toca producción, corre en una transacción con
-- rollback en la base de test local) para poder probar la lógica exacta de
-- este script sin depender de que exista una base de producción real.
--
-- Quirúrgico, NO genérico. Corrige EXCLUSIVAMENTE las 4 sale_items ya
-- identificadas y clasificadas como REPARABLE_INEQUIVOCAMENTE por el sizing
-- de solo lectura (sizing_three_for_two_backfill_candidates*.sql), sobre
-- exactamente 2 ventas:
--   - MJ-25-20260907-0001 (b36f38ef-89fa-4dd2-832a-14c516a48bf3)
--       huérfanas: 53f17c15-8902-49e0-a990-89054eee2f5f (Serum Vitamina C)
--                  8c459f62-93a7-4f03-869c-103bee6c2446 (Crema antiage)
--       ancla:     f68e7bb1-be70-43d3-a013-3cf4afa587db (Contorno de ojos, $0)
--   - MJ-37-20260908-0001 (00b73ac9-1847-4f5e-b697-b08e6ca4844e)
--       huérfanas: 53360aec-f499-478e-bab9-fd21e39ac20d (Serum Niacinamida)
--                  77e04afc-1372-4b58-9f6d-850558000d6d (Serum Vitamina C)
--       ancla:     794de7d0-5380-4a65-a62c-97f662a03e6f (Crema pieles sensibles, $0)
-- Promoción: "Promo septiembre 3x2" (01d7b21c-9e94-48c7-b07e-dad2ca2b54ad).
--
-- NO backfill genérico: ningún WHERE por composición de promotion_products,
-- ningún criterio de fecha/rango, ningún JOIN abierto — los 4 sale_item_id
-- están hardcodeados. Ninguna otra fila de sale_items puede verse afectada
-- por este archivo, sea cual sea el estado de la base al momento de correrlo.
--
-- Qué modifica por línea: applied_promotion_id, promotion_name_snapshot,
-- promotion_type_snapshot (copiados de la línea ancla de la MISMA venta).
-- Qué NO modifica, nunca: sale_unit_price, line_total, line_list_total,
-- line_discount, line_surcharge, quantity, applied_price_condition_id,
-- commissionable, promotion_discount (quieta en 0, ya lo estaba), stock,
-- sales.total/subtotal/discount_total/surcharge_total/commission_total, y
-- no inserta ni borra ninguna fila de sale_items.
--
-- Seguridad: idempotente (puede correr más de una vez sin error ni doble
-- aplicación — la 2ª corrida encuentra las 4 líneas ya en el estado
-- objetivo y no falla), defensiva (guards con RAISE EXCEPTION ANTES del
-- UPDATE, verificando cada precondición exacta — sale_item_id pertenece a
-- la venta esperada, ancla única de tipo THREE_FOR_TWO por venta, ningún
-- applied_promotion_id previo distinto del esperado, montos/cantidades
-- exactamente los observados en el sizing, sales.total sin drift), y una
-- verificación posterior a la actualización que aborta toda la migración
-- (ROLLBACK automático) si algo no cierra.
-- =============================================================================
begin;

do $$
declare
  v_promo_id constant uuid := '01d7b21c-9e94-48c7-b07e-dad2ca2b54ad';

  v_sale1_id constant uuid := 'b36f38ef-89fa-4dd2-832a-14c516a48bf3';
  v_sale1_number constant text := 'MJ-25-20260907-0001';
  v_sale1_expected_total constant numeric := 90300.00;
  v_sale1_anchor_id constant uuid := 'f68e7bb1-be70-43d3-a013-3cf4afa587db';
  v_sale1_line1_id constant uuid := '53f17c15-8902-49e0-a990-89054eee2f5f'; -- Serum Vitamina C
  v_sale1_line2_id constant uuid := '8c459f62-93a7-4f03-869c-103bee6c2446'; -- Crema antiage

  v_sale2_id constant uuid := '00b73ac9-1847-4f5e-b697-b08e6ca4844e';
  v_sale2_number constant text := 'MJ-37-20260908-0001';
  v_sale2_expected_total constant numeric := 89600.00;
  v_sale2_anchor_id constant uuid := '794de7d0-5380-4a65-a62c-97f662a03e6f';
  v_sale2_line1_id constant uuid := '53360aec-f499-478e-bab9-fd21e39ac20d'; -- Serum Niacinamida
  v_sale2_line2_id constant uuid := '77e04afc-1372-4b58-9f6d-850558000d6d'; -- Serum Vitamina C

  v_anchor1 public.sale_items;
  v_anchor2 public.sale_items;
  v_line record;
  v_total numeric;
begin
  -- -------------------------------------------------------------------------
  -- GUARD 1: las dos ventas existen, con el sale_number esperado y el total
  -- que tenían al momento del sizing (sin drift desde entonces).
  -- -------------------------------------------------------------------------
  select total into v_total from public.sales where id = v_sale1_id and sale_number = v_sale1_number;
  if not found then
    raise exception 'Backfill 065: la venta % (%) no existe o su sale_number no coincide.', v_sale1_id, v_sale1_number;
  end if;
  if v_total <> v_sale1_expected_total then
    raise exception 'Backfill 065: sales.total de % cambió desde el sizing (esperado %, actual %). Abortando.',
      v_sale1_number, v_sale1_expected_total, v_total;
  end if;

  select total into v_total from public.sales where id = v_sale2_id and sale_number = v_sale2_number;
  if not found then
    raise exception 'Backfill 065: la venta % (%) no existe o su sale_number no coincide.', v_sale2_id, v_sale2_number;
  end if;
  if v_total <> v_sale2_expected_total then
    raise exception 'Backfill 065: sales.total de % cambió desde el sizing (esperado %, actual %). Abortando.',
      v_sale2_number, v_sale2_expected_total, v_total;
  end if;

  -- -------------------------------------------------------------------------
  -- GUARD 2: exactamente una línea ancla THREE_FOR_TWO por venta (la unidad
  -- gratis, $0, ya tagueada con la promoción correcta) — ni cero ni más de
  -- una. Se usa para copiar el snapshot, nunca se modifica.
  -- -------------------------------------------------------------------------
  if (
    select count(*) from public.sale_items si
    join public.promotions p on p.id = si.applied_promotion_id
    where si.sale_id = v_sale1_id and p.type = 'THREE_FOR_TWO' and si.sale_unit_price = 0
  ) <> 1 then
    raise exception 'Backfill 065: % no tiene exactamente 1 línea ancla THREE_FOR_TWO ($0). Abortando.', v_sale1_number;
  end if;

  select * into v_anchor1 from public.sale_items where id = v_sale1_anchor_id and sale_id = v_sale1_id;
  if not found then
    raise exception 'Backfill 065: la línea ancla % no pertenece a la venta % o no existe.', v_sale1_anchor_id, v_sale1_number;
  end if;
  if v_anchor1.applied_promotion_id <> v_promo_id or v_anchor1.sale_unit_price <> 0
     or v_anchor1.promotion_type_snapshot <> 'THREE_FOR_TWO' or v_anchor1.promotion_name_snapshot is null then
    raise exception 'Backfill 065: la línea ancla % de % no tiene el estado esperado (promo/tipo/snapshot/$0).',
      v_sale1_anchor_id, v_sale1_number;
  end if;

  if (
    select count(*) from public.sale_items si
    join public.promotions p on p.id = si.applied_promotion_id
    where si.sale_id = v_sale2_id and p.type = 'THREE_FOR_TWO' and si.sale_unit_price = 0
  ) <> 1 then
    raise exception 'Backfill 065: % no tiene exactamente 1 línea ancla THREE_FOR_TWO ($0). Abortando.', v_sale2_number;
  end if;

  select * into v_anchor2 from public.sale_items where id = v_sale2_anchor_id and sale_id = v_sale2_id;
  if not found then
    raise exception 'Backfill 065: la línea ancla % no pertenece a la venta % o no existe.', v_sale2_anchor_id, v_sale2_number;
  end if;
  if v_anchor2.applied_promotion_id <> v_promo_id or v_anchor2.sale_unit_price <> 0
     or v_anchor2.promotion_type_snapshot <> 'THREE_FOR_TWO' or v_anchor2.promotion_name_snapshot is null then
    raise exception 'Backfill 065: la línea ancla % de % no tiene el estado esperado (promo/tipo/snapshot/$0).',
      v_sale2_anchor_id, v_sale2_number;
  end if;

  -- -------------------------------------------------------------------------
  -- GUARD 3: cada una de las 4 líneas huérfanas pertenece a la venta
  -- esperada, tiene exactamente los montos/cantidad observados en el sizing
  -- (sin drift), y su applied_promotion_id es null O YA es la promoción
  -- correcta (idempotencia — una 2ª corrida no debe fallar acá) — nunca
  -- otra promoción distinta.
  -- -------------------------------------------------------------------------
  for v_line in
    select * from (values
      (v_sale1_line1_id, v_sale1_id, v_sale1_number, 1::numeric, 45300.00::numeric, 45300.00::numeric),
      (v_sale1_line2_id, v_sale1_id, v_sale1_number, 1::numeric, 45000.00::numeric, 45000.00::numeric),
      (v_sale2_line1_id, v_sale2_id, v_sale2_number, 1::numeric, 44300.00::numeric, 44300.00::numeric),
      (v_sale2_line2_id, v_sale2_id, v_sale2_number, 1::numeric, 45300.00::numeric, 45300.00::numeric)
    ) as t(item_id, sale_id, sale_number, expected_qty, expected_price, expected_line_total)
  loop
    declare
      v_item public.sale_items;
    begin
      select * into v_item from public.sale_items where id = v_line.item_id and sale_id = v_line.sale_id;
      if not found then
        raise exception 'Backfill 065: la línea % no pertenece a la venta % o no existe. Abortando.',
          v_line.item_id, v_line.sale_number;
      end if;
      if v_item.quantity <> v_line.expected_qty
         or v_item.sale_unit_price <> v_line.expected_price
         or v_item.line_total <> v_line.expected_line_total then
        raise exception
          'Backfill 065: la línea % de % cambió desde el sizing (esperado qty=%/precio=%/total=%, actual qty=%/precio=%/total=%). Abortando.',
          v_line.item_id, v_line.sale_number, v_line.expected_qty, v_line.expected_price, v_line.expected_line_total,
          v_item.quantity, v_item.sale_unit_price, v_item.line_total;
      end if;
      if v_item.applied_promotion_id is not null and v_item.applied_promotion_id <> v_promo_id then
        raise exception
          'Backfill 065: la línea % de % ya tiene applied_promotion_id=% (distinto de la promoción esperada %). Abortando — nunca se pisa una atribución existente.',
          v_line.item_id, v_line.sale_number, v_item.applied_promotion_id, v_promo_id;
      end if;
    end;
  end loop;

  -- -------------------------------------------------------------------------
  -- UPDATE: exactamente 4 filas, por id + sale_id (defensa adicional en el
  -- WHERE). Nunca toca sale_unit_price/line_total/line_list_total/
  -- line_discount/line_surcharge/quantity/applied_price_condition_id/
  -- commissionable. promotion_discount se deja explícito en 0 (ya lo estaba
  -- — nunca hubo descuento individual en estas líneas, todo el ahorro del
  -- 3x2 está en la unidad gratis de cada venta, que no se toca).
  -- -------------------------------------------------------------------------
  update public.sale_items
  set applied_promotion_id = v_promo_id,
      promotion_name_snapshot = v_anchor1.promotion_name_snapshot,
      promotion_type_snapshot = v_anchor1.promotion_type_snapshot,
      promotion_discount = 0
  where id in (v_sale1_line1_id, v_sale1_line2_id) and sale_id = v_sale1_id;

  if not found then
    raise exception 'Backfill 065: el UPDATE de % no afectó ninguna fila — inesperado tras pasar los guards.', v_sale1_number;
  end if;

  update public.sale_items
  set applied_promotion_id = v_promo_id,
      promotion_name_snapshot = v_anchor2.promotion_name_snapshot,
      promotion_type_snapshot = v_anchor2.promotion_type_snapshot,
      promotion_discount = 0
  where id in (v_sale2_line1_id, v_sale2_line2_id) and sale_id = v_sale2_id;

  if not found then
    raise exception 'Backfill 065: el UPDATE de % no afectó ninguna fila — inesperado tras pasar los guards.', v_sale2_number;
  end if;

  -- -------------------------------------------------------------------------
  -- POST-VALIDACIÓN: exactamente 4 filas quedaron con la promoción correcta
  -- (ni una más, ni una menos), y sales.total de ambas ventas no cambió un
  -- peso. Si algo no cierra, esta excepción aborta TODA la migración
  -- (create/replace de arriba incluido no hay — este archivo es 100% DML —
  -- así que el ROLLBACK deja la base exactamente como estaba).
  -- -------------------------------------------------------------------------
  if (
    select count(*) from public.sale_items
    where id in (v_sale1_line1_id, v_sale1_line2_id, v_sale2_line1_id, v_sale2_line2_id)
      and applied_promotion_id = v_promo_id
  ) <> 4 then
    raise exception 'Backfill 065: post-validación falló — no quedaron exactamente 4 líneas con la promoción correcta.';
  end if;

  if (select total from public.sales where id = v_sale1_id) <> v_sale1_expected_total then
    raise exception 'Backfill 065: post-validación falló — sales.total de % cambió.', v_sale1_number;
  end if;
  if (select total from public.sales where id = v_sale2_id) <> v_sale2_expected_total then
    raise exception 'Backfill 065: post-validación falló — sales.total de % cambió.', v_sale2_number;
  end if;

  raise notice 'Backfill 065 OK: 4 líneas actualizadas (% y %), totales de venta sin cambios ($% / $%).',
    v_sale1_number, v_sale2_number, v_sale1_expected_total, v_sale2_expected_total;
end;
$$;

commit;

-- =============================================================================
-- VERIFICACIÓN POST-DEPLOY (solo lectura — correr después del commit de
-- arriba). Resultado esperado: 4 filas, todas con la promoción correcta y
-- los totales de venta intactos.
-- =============================================================================
select
  s.sale_number,
  si.id as sale_item_id,
  p.name as product_name,
  si.quantity,
  si.sale_unit_price,
  si.line_total,
  si.applied_promotion_id,
  pr.name as promotion_name,
  si.promotion_name_snapshot,
  si.promotion_type_snapshot,
  si.promotion_discount,
  s.total as sale_total
from public.sale_items si
join public.sales s on s.id = si.sale_id
join public.products p on p.id = si.product_id
left join public.promotions pr on pr.id = si.applied_promotion_id
where si.id in (
  '53f17c15-8902-49e0-a990-89054eee2f5f',
  '8c459f62-93a7-4f03-869c-103bee6c2446',
  '53360aec-f499-478e-bab9-fd21e39ac20d',
  '77e04afc-1372-4b58-9f6d-850558000d6d'
)
order by s.sale_number, si.id;

-- Confirmar que el reporte de rendimiento ahora refleja las 2 ventas
-- correctamente (Ventas=2, Unidades=6, Facturación=179900) para el rango
-- que incluya ambas fechas (2026-09-07 a 2026-09-08).
select promotion_performance_report('2026-09-01', '2026-09-30');

