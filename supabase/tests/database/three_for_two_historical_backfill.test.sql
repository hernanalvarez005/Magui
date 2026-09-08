-- pgTAP: PROD_HISTORICAL_BACKFILL_065_three_for_two.sql (backfill histórico
-- quirúrgico, 4 sale_items conocidas — NO es una migración, no vive en
-- supabase/migrations/, ver comentario de cabecera de ese archivo). Este
-- test arma una venta SINTÉTICA con los MISMOS UUIDs hardcodeados en el
-- script (no toca producción — corre en una transacción con rollback en la
-- base de test local) para poder probar su lógica exacta.
--
-- La lógica del script se ejecuta acá adentro como una función pg_temp
-- (misma sesión, se descarta sola al terminar) cuyo cuerpo es una copia
-- EXACTA (extraída por script, nunca retipeada a mano) del bloque `do $$`
-- del archivo real — ver el comentario "GENERADO DESDE" más abajo.
--
-- Casos, en orden:
--   1-4) Guards fallan ANTES de tocar nada: cantidad/precio con drift,
--        applied_promotion_id previo distinto, ancla inválida, sales.total
--        con drift — cada uno se prueba tamperando la fixture y se revierte
--        con SAVEPOINT antes del siguiente, así todos parten del mismo
--        estado limpio.
--   5-10) Corrida exitosa: las 4 líneas quedan tagueadas con la promoción
--        correcta, snapshot copiado desde el ancla de CADA venta, precios/
--        cantidades/totales de venta sin cambios, promotion_performance_report
--        ahora refleja Ventas=2/Unidades=6/Facturación=179900.
--   11-12) Idempotencia: correr el script una 2ª vez no falla y no duplica
--        nada (sigue habiendo exactamente 4 líneas tagueadas).
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(12);

insert into auth.users (id, email) values
  ('d4000000-0000-0000-0000-000000000001', 'admin.backfill065@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'd4000000-0000-0000-0000-000000000001';
insert into public.profile_locations (profile_id, location_id)
  select 'd4000000-0000-0000-0000-000000000001', id from public.stock_locations;

-- Sin "set role authenticated": este test inserta directamente en sales/
-- sale_items (RPC-only, sin policy de INSERT para authenticated) para armar
-- la fixture con los MISMOS ids que el script real — igual que corre el
-- script real en Supabase (SQL Editor, como postgres/service_role, sin
-- RLS). set_config solo resuelve auth.uid() para promotion_performance_report
-- (caso 10), que sí lo necesita.
select set_config('request.jwt.claim.sub', 'd4000000-0000-0000-0000-000000000001', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('BF-0003', 'Contorno de ojos (backfill test)', 'product', 'Test', true, true, true, true),
  ('BF-0004', 'Crema antiage (backfill test)', 'product', 'Test', true, true, true, true),
  ('BF-VITC', 'Serum Vitamina C (backfill test)', 'product', 'Test', true, true, true, true),
  ('BF-0005', 'Crema pieles sensibles (backfill test)', 'product', 'Test', true, true, true, true),
  ('BF-0002', 'Serum de Niacinamida (backfill test)', 'product', 'Test', true, true, true, true);

insert into public.customers (full_name, dni) values ('Clienta Backfill 065 (test)', '30555444');
select id as customer_id from customers where dni = '30555444' \gset
select id as sed25_id from stock_locations where code = 'SED-25' \gset
select id as sed37_id from stock_locations where code = 'SED-37' \gset
select id as branch_channel_id from sales_channels where code <> 'WEB' limit 1 \gset
select id as cash_id from payment_methods where code = 'CASH' \gset
select id as list_pc_id from price_conditions where rule_type = 'BASE' \gset

-- Promoción con el MISMO id que el script hardcodea.
insert into public.promotions (id, code, name, type, price_condition_id, group_size, priority, stackable) values
  ('01d7b21c-9e94-48c7-b07e-dad2ca2b54ad', 'BF-3X2', 'Promo septiembre 3x2', 'THREE_FOR_TWO', :'list_pc_id', 3, 60, false);

-- Otra promoción, distinta, para el caso "applied_promotion_id previo
-- distinto del esperado" (caso 2).
insert into public.promotions (id, code, name, type, price_condition_id, group_size, priority, stackable) values
  ('02000000-0000-0000-0000-000000000099', 'BF-OTRA', 'Otra promo (backfill test)', 'THREE_FOR_TWO', :'list_pc_id', 3, 61, false);

-- ---------------------------------------------------------------------------
-- Venta 1 (id/sale_number/total EXACTOS a los que hardcodea el script) —
-- ancla gratis + 2 líneas huérfanas (pagas, sin tag — estado "pre-backfill").
-- ---------------------------------------------------------------------------
insert into public.sales (
  id, sale_number, sold_at, location_id, sales_channel_id, seller_id, customer_id,
  payment_method_id, applied_price_condition_id, subtotal, discount_total, surcharge_total, total,
  commission_total, status
) values (
  'b36f38ef-89fa-4dd2-832a-14c516a48bf3', 'MJ-25-20260907-0001', now() - interval '2 days',
  :'sed25_id', :'branch_channel_id', 'd4000000-0000-0000-0000-000000000001', :'customer_id',
  :'cash_id', :'list_pc_id', 133300, 43000, 0, 90300, 0, 'confirmed'
);

insert into public.sale_items (
  id, sale_id, product_id, quantity, list_unit_price, sale_unit_price, line_list_total, line_discount, line_total,
  applied_price_condition_id, commissionable, applied_promotion_id, promotion_discount,
  promotion_name_snapshot, promotion_type_snapshot
) values
  ('f68e7bb1-be70-43d3-a013-3cf4afa587db', 'b36f38ef-89fa-4dd2-832a-14c516a48bf3',
   (select id from products where sku = 'BF-0003'), 1, 43000, 0, 43000, 43000, 0,
   :'list_pc_id', true, '01d7b21c-9e94-48c7-b07e-dad2ca2b54ad', 43000, 'Promo septiembre 3x2', 'THREE_FOR_TWO'),
  ('53f17c15-8902-49e0-a990-89054eee2f5f', 'b36f38ef-89fa-4dd2-832a-14c516a48bf3',
   (select id from products where sku = 'BF-VITC'), 1, 45300, 45300, 45300, 0, 45300,
   :'list_pc_id', true, null, 0, null, null),
  ('8c459f62-93a7-4f03-869c-103bee6c2446', 'b36f38ef-89fa-4dd2-832a-14c516a48bf3',
   (select id from products where sku = 'BF-0004'), 1, 45000, 45000, 45000, 0, 45000,
   :'list_pc_id', true, null, 0, null, null);

-- ---------------------------------------------------------------------------
-- Venta 2 (idem).
-- ---------------------------------------------------------------------------
insert into public.sales (
  id, sale_number, sold_at, location_id, sales_channel_id, seller_id, customer_id,
  payment_method_id, applied_price_condition_id, subtotal, discount_total, surcharge_total, total,
  commission_total, status
) values (
  '00b73ac9-1847-4f5e-b697-b08e6ca4844e', 'MJ-37-20260908-0001', now() - interval '1 days',
  :'sed37_id', :'branch_channel_id', 'd4000000-0000-0000-0000-000000000001', :'customer_id',
  :'cash_id', :'list_pc_id', 133600, 44000, 0, 89600, 0, 'confirmed'
);

insert into public.sale_items (
  id, sale_id, product_id, quantity, list_unit_price, sale_unit_price, line_list_total, line_discount, line_total,
  applied_price_condition_id, commissionable, applied_promotion_id, promotion_discount,
  promotion_name_snapshot, promotion_type_snapshot
) values
  ('794de7d0-5380-4a65-a62c-97f662a03e6f', '00b73ac9-1847-4f5e-b697-b08e6ca4844e',
   (select id from products where sku = 'BF-0005'), 1, 44000, 0, 44000, 44000, 0,
   :'list_pc_id', true, '01d7b21c-9e94-48c7-b07e-dad2ca2b54ad', 44000, 'Promo septiembre 3x2', 'THREE_FOR_TWO'),
  ('53360aec-f499-478e-bab9-fd21e39ac20d', '00b73ac9-1847-4f5e-b697-b08e6ca4844e',
   (select id from products where sku = 'BF-0002'), 1, 44300, 44300, 44300, 0, 44300,
   :'list_pc_id', true, null, 0, null, null),
  ('77e04afc-1372-4b58-9f6d-850558000d6d', '00b73ac9-1847-4f5e-b697-b08e6ca4844e',
   (select id from products where sku = 'BF-VITC'), 1, 45300, 45300, 45300, 0, 45300,
   :'list_pc_id', true, null, 0, null, null);

-- ---------------------------------------------------------------------------
-- Función pg_temp con el cuerpo EXACTO del bloque `do $$` del script real
-- (GENERADO DESDE PROD_HISTORICAL_BACKFILL_065_three_for_two.sql — extraído
-- por script, nunca retipeado a mano — ver el comentario de la migración
-- 065 y el mensaje de cierre de este bloque de trabajo para la trazabilidad
-- exacta). Se descarta sola al cerrar la sesión.
-- ---------------------------------------------------------------------------
create or replace function pg_temp.run_backfill_065()
returns void
language plpgsql
as $$
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

-- Punto de retorno limpio: todo lo tamperado en los 4 guards de abajo se
-- revierte acá antes del siguiente caso, así todos parten del mismo estado
-- (fixture recién insertada, sin tocar).
savepoint sp_clean;

-- ===========================================================================
-- Caso 1: cantidad/precio con drift respecto de lo esperado -> falla.
-- ===========================================================================
update sale_items set sale_unit_price = 12345 where id = '53f17c15-8902-49e0-a990-89054eee2f5f';
select throws_ok(
  $$select pg_temp.run_backfill_065()$$,
  'Caso 1: guard de cantidad/precio con drift rechaza la corrida antes de tocar nada'
);
rollback to savepoint sp_clean;

-- ===========================================================================
-- Caso 2: una de las 4 líneas ya tiene un applied_promotion_id DISTINTO del
-- esperado -> falla (nunca se pisa una atribución existente).
-- ===========================================================================
update sale_items set applied_promotion_id = '02000000-0000-0000-0000-000000000099'
  where id = '8c459f62-93a7-4f03-869c-103bee6c2446';
select throws_ok(
  $$select pg_temp.run_backfill_065()$$,
  'Caso 2: guard de applied_promotion_id previo distinto rechaza la corrida'
);
rollback to savepoint sp_clean;

-- ===========================================================================
-- Caso 3: el ancla de una de las 2 ventas deja de ser THREE_FOR_TWO -> falla.
-- ===========================================================================
update sale_items set promotion_type_snapshot = 'KIT_PERCENT'
  where id = 'f68e7bb1-be70-43d3-a013-3cf4afa587db';
select throws_ok(
  $$select pg_temp.run_backfill_065()$$,
  'Caso 3: guard de línea ancla inválida (tipo distinto de THREE_FOR_TWO) rechaza la corrida'
);
rollback to savepoint sp_clean;

-- ===========================================================================
-- Caso 4: sales.total tiene drift respecto del esperado -> falla.
-- ===========================================================================
update sales set surcharge_total = 100, total = 89700 where id = '00b73ac9-1847-4f5e-b697-b08e6ca4844e';
select throws_ok(
  $$select pg_temp.run_backfill_065()$$,
  'Caso 4: guard de sales.total con drift rechaza la corrida'
);
rollback to savepoint sp_clean;

-- ===========================================================================
-- Casos 5-10: corrida exitosa (fixture limpia, restaurada por el savepoint).
-- ===========================================================================
select lives_ok(
  $$select pg_temp.run_backfill_065()$$,
  'Caso 5: con la fixture limpia, el backfill corre sin errores'
);

select is(
  (select array_agg(applied_promotion_id order by id) from sale_items
   where id in ('53f17c15-8902-49e0-a990-89054eee2f5f', '8c459f62-93a7-4f03-869c-103bee6c2446',
                '53360aec-f499-478e-bab9-fd21e39ac20d', '77e04afc-1372-4b58-9f6d-850558000d6d')),
  array_fill('01d7b21c-9e94-48c7-b07e-dad2ca2b54ad'::uuid, array[4]),
  'Caso 6: las 4 líneas quedan con applied_promotion_id = Promo septiembre 3x2'
);

select is(
  (select (promotion_name_snapshot, promotion_type_snapshot) from sale_items where id = '53f17c15-8902-49e0-a990-89054eee2f5f'),
  ('Promo septiembre 3x2'::text, 'THREE_FOR_TWO'::promotion_type),
  'Caso 7: snapshot copiado correctamente desde el ancla de la venta 1'
);

select is(
  (select (quantity, sale_unit_price, line_total) from sale_items where id = '53f17c15-8902-49e0-a990-89054eee2f5f'),
  (1::numeric, 45300::numeric, 45300::numeric),
  'Caso 8: quantity/sale_unit_price/line_total quedan exactamente iguales — el backfill nunca los toca'
);

select is(
  (select jsonb_build_object(
    'sale1', (select total from sales where id = 'b36f38ef-89fa-4dd2-832a-14c516a48bf3'),
    'sale2', (select total from sales where id = '00b73ac9-1847-4f5e-b697-b08e6ca4844e')
  )),
  jsonb_build_object('sale1', 90300, 'sale2', 89600),
  'Caso 9: sales.total de ambas ventas sin cambios'
);

select is(
  (
    select ((row ->> 'sales_count')::int, (row ->> 'units_sold')::numeric, (row -> 'revenue')::numeric)
    from jsonb_array_elements(
      (promotion_performance_report((current_date - 10)::date, (current_date + 1)::date) -> 'rows')
    ) row
    where (row ->> 'promotion_id')::uuid = '01d7b21c-9e94-48c7-b07e-dad2ca2b54ad'::uuid
  ),
  (2, 6::numeric, 179900::numeric),
  'Caso 10: promotion_performance_report ahora refleja Ventas=2, Unidades=6, Facturación=179900'
);

-- ===========================================================================
-- Caso 11: idempotencia — correr una 2ª vez no falla.
-- ===========================================================================
select lives_ok(
  $$select pg_temp.run_backfill_065()$$,
  'Caso 11: una 2ª corrida sobre datos ya reparados no falla (idempotente)'
);

select is(
  (select count(*)::int from sale_items
   where id in ('53f17c15-8902-49e0-a990-89054eee2f5f', '8c459f62-93a7-4f03-869c-103bee6c2446',
                '53360aec-f499-478e-bab9-fd21e39ac20d', '77e04afc-1372-4b58-9f6d-850558000d6d')
     and applied_promotion_id = '01d7b21c-9e94-48c7-b07e-dad2ca2b54ad'::uuid),
  4,
  'Caso 12: después de la 2ª corrida siguen siendo exactamente 4 líneas tagueadas — sin duplicar nada'
);

select * from finish();
rollback;
