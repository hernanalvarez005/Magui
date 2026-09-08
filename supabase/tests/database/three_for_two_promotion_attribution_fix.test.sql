-- pgTAP: fix de atribución THREE_FOR_TWO en Analytics de promociones
-- (migración 64). Casos, en orden:
--   1-3)   Múltiplo exacto (compra 3, group_size=3): exactamente 2 filas
--          (gratis + pagas-en-grupo), ninguna excedente, ambas tagueadas.
--   4-8)   Con excedente (compra 4, group_size=3): exactamente 3 filas
--          (gratis/pagas-en-grupo/excedente); solo la excedente SIN tag;
--          REGRESIÓN explícita: el total cobrado es idéntico al que daba la
--          fórmula vieja (promo_price * (qty - free_units)) — este archivo
--          corrige atribución/analytics, nunca pricing.
--   9)     Múltiplo x2 (compra 6): free=2, paying=4, sin excedente.
--   10)    Multi-producto: distribución correcta de free/paying/excedente
--          entre 2 productos del mismo 3x2, según el ranking por precio.
--   11)    promotion_performance_report sobre la venta del caso 1: revenue
--          real (> 0), coincide con la suma manual de líneas tagueadas.
--   12-14) Regresión: DUO_PERCENT/KIT_PERCENT/QUANTITY_DISCOUNT sin cambios
--          (auditados como ya correctos, no debían tocarse).
--   15)    Cambio (create_sale_exchange) sobre una venta con el split nuevo
--          de 3 filas no rompe — sigue funcionando línea por línea.
--   16)    Devolución parcial sobre la línea "pagas-en-grupo" — sale_item_net
--          neta correctamente sin tocar applied_promotion_id.
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(16);

insert into auth.users (id, email) values
  ('b2000000-0000-0000-0000-000000000001', 'admin.t2fix@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'b2000000-0000-0000-0000-000000000001';
insert into public.profile_locations (profile_id, location_id)
  select 'b2000000-0000-0000-0000-000000000001', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Catálogo: TFT-A (más barato, siempre recibe la unidad gratis primero por
-- el ranking) y TFT-B (más caro), ambos elegibles para el mismo 3x2.
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('TFT-A', 'Fix 3x2 A (barato)', 'product', 'Test', true, true, true, true),
  ('TFT-B', 'Fix 3x2 B (caro)', 'product', 'Test', true, true, true, true);

select set_product_price((select id from products where sku = 'TFT-A'), (select id from price_conditions where code = 'LIST'), 30000);
select set_product_price((select id from products where sku = 'TFT-A'), (select id from price_conditions where code = 'CASH'), 30000);
select set_product_price((select id from products where sku = 'TFT-B'), (select id from price_conditions where code = 'LIST'), 35000);
select set_product_price((select id from products where sku = 'TFT-B'), (select id from price_conditions where code = 'CASH'), 35000);

select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'TFT-A'), 100, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'TFT-B'), 100, 'RECEPTION');

select id as sed25_id from stock_locations where code = 'SED-25' \gset
select id as branch_channel_id from sales_channels where code <> 'WEB' limit 1 \gset
select id as cash_id from payment_methods where code = 'CASH' \gset
select id as base_pc_id from price_conditions where rule_type = 'BASE' \gset

insert into public.promotions (code, name, type, price_condition_id, group_size, priority, stackable) values
  ('TFT-3X2', 'Fix 3x2 test', 'THREE_FOR_TWO', :'base_pc_id', 3, 40, false);
select set_promotion_products(
  (select id from promotions where code = 'TFT-3X2'),
  array[(select id from products where sku = 'TFT-A'), (select id from products where sku = 'TFT-B')]
);
select id as promo_id from promotions where code = 'TFT-3X2' \gset

-- Cliente identificado desde el arranque: sales es RPC-only (sin policy de
-- UPDATE directo), así que el customer_id tiene que quedar seteado en la
-- CREACIÓN de la venta si más adelante hace falta para un cambio/devolución
-- (casos 15-16) — un UPDATE crudo sobre sales quedaría en 0 filas por RLS.
insert into public.customers (full_name, dni) values ('Clienta Fix 3x2 (test)', '30666655');
select id as customer_id from customers where dni = '30666655' \gset

-- ===========================================================================
-- Casos 1-3: múltiplo exacto (compra 3 de TFT-A sola) -> free=1, paying=2,
-- sin excedente.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TFT-A'), 'quantity', 3)),
  :'sed25_id', :'branch_channel_id', :'cash_id', :'customer_id'
) ->> 'sale_id')::uuid as sale_exact_id \gset

select is(
  (select count(*)::int from sale_items where sale_id = :'sale_exact_id'::uuid and product_id = (select id from products where sku = 'TFT-A')),
  2,
  'Caso 1: compra exacta de 3 (group_size=3) genera exactamente 2 filas — sin excedente'
);

select is(
  (select (quantity, sale_unit_price, applied_promotion_id) from sale_items
   where sale_id = :'sale_exact_id'::uuid and product_id = (select id from products where sku = 'TFT-A') and sale_unit_price = 0),
  (1::numeric, 0::numeric, :'promo_id'::uuid),
  'Caso 2: la fila gratis del múltiplo exacto tiene quantity=1, $0 y applied_promotion_id seteado'
);

select is(
  (select (quantity, sale_unit_price, applied_promotion_id) from sale_items
   where sale_id = :'sale_exact_id'::uuid and product_id = (select id from products where sku = 'TFT-A') and sale_unit_price > 0),
  (2::numeric, 30000::numeric, :'promo_id'::uuid),
  'Caso 3: la fila pagas-en-grupo del múltiplo exacto tiene quantity=2, precio promo Y applied_promotion_id seteado (antes: null)'
);

-- ===========================================================================
-- Casos 4-8: con excedente (compra 4 de TFT-A sola) -> free=1, paying=2,
-- excedente=1.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TFT-A'), 'quantity', 4)),
  :'sed25_id', :'branch_channel_id', :'cash_id', :'customer_id'
) ->> 'sale_id')::uuid as sale_excess_id \gset

select is(
  (select count(*)::int from sale_items where sale_id = :'sale_excess_id'::uuid and product_id = (select id from products where sku = 'TFT-A')),
  3,
  'Caso 4: compra de 4 (group_size=3) genera exactamente 3 filas — gratis + pagas-en-grupo + excedente'
);

select is(
  (select (quantity, sale_unit_price, applied_promotion_id) from sale_items
   where sale_id = :'sale_excess_id'::uuid and product_id = (select id from products where sku = 'TFT-A') and sale_unit_price = 0),
  (1::numeric, 0::numeric, :'promo_id'::uuid),
  'Caso 5: la fila gratis sigue igual (quantity=1, $0, tagueada)'
);

select is(
  (select (quantity, sale_unit_price, applied_promotion_id) from sale_items
   where sale_id = :'sale_excess_id'::uuid and product_id = (select id from products where sku = 'TFT-A')
     and sale_unit_price > 0 and applied_promotion_id is not null),
  (2::numeric, 30000::numeric, :'promo_id'::uuid),
  'Caso 6: la fila pagas-en-grupo tiene quantity=2, precio promo, tagueada'
);

select is(
  (select (quantity, sale_unit_price, applied_promotion_id) from sale_items
   where sale_id = :'sale_excess_id'::uuid and product_id = (select id from products where sku = 'TFT-A')
     and sale_unit_price > 0 and applied_promotion_id is null),
  (1::numeric, 30000::numeric, null::uuid),
  'Caso 7: la fila excedente (la 4ª unidad) tiene quantity=1, MISMO precio promo, pero SIN applied_promotion_id'
);

-- REGRESIÓN explícita de pricing: el total cobrado con excedente es
-- exactamente igual al que daba la fórmula vieja de un solo remanente
-- (promo_price * (qty - free_units) = 30000 * 3 = 90000), sea cual sea el
-- split de atribución interno. Este archivo corrige analytics, no pricing.
select is(
  (select total from sales where id = :'sale_excess_id'::uuid),
  90000::numeric,
  'Caso 8 (REGRESIÓN): total cobrado con excedente = 90000 (0 + 2×30000 + 1×30000), idéntico a la fórmula vieja — el fix no cambia pricing'
);

-- ===========================================================================
-- Caso 9: múltiplo x2 exacto (compra 6) -> free=2, paying=4, sin excedente.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TFT-A'), 'quantity', 6)),
  :'sed25_id', :'branch_channel_id', :'cash_id'
) ->> 'sale_id')::uuid as sale_double_id \gset

select is(
  (select jsonb_build_object(
    'rows', count(*),
    'all_tagged', bool_and(applied_promotion_id is not null),
    'free_qty', sum(quantity) filter (where sale_unit_price = 0),
    'paying_qty', sum(quantity) filter (where sale_unit_price > 0)
  ) from sale_items where sale_id = :'sale_double_id'::uuid and product_id = (select id from products where sku = 'TFT-A')),
  jsonb_build_object('rows', 2, 'all_tagged', true, 'free_qty', 2, 'paying_qty', 4),
  'Caso 9: compra de 6 (2×group_size) -> free=2 y paying=4, ambas tagueadas, sin fila de excedente (serían 3 filas si hubiera una tercera)'
);

-- ===========================================================================
-- Caso 10: multi-producto. TFT-A (barato) + TFT-B (caro), 2 unidades cada
-- uno, group_size=3, total=4 -> por el ranking (precio asc, product_id,
-- unit_idx), TFT-A se lleva la única unidad gratis; de las 3 unidades
-- restantes del grupo participante (participating_total=3), 1 más de TFT-A
-- y 1 de TFT-B pagan-en-grupo; la 4ª unidad (de TFT-B) queda como excedente.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'TFT-A'), 'quantity', 2),
    jsonb_build_object('product_id', (select id from products where sku = 'TFT-B'), 'quantity', 2)
  ),
  :'sed25_id', :'branch_channel_id', :'cash_id'
) ->> 'sale_id')::uuid as sale_multi_id \gset

select is(
  (select jsonb_build_object(
    'a_free', (select count(*) from sale_items where sale_id = :'sale_multi_id'::uuid and product_id = (select id from products where sku = 'TFT-A') and sale_unit_price = 0),
    'a_paying', (select count(*) from sale_items where sale_id = :'sale_multi_id'::uuid and product_id = (select id from products where sku = 'TFT-A') and sale_unit_price > 0 and applied_promotion_id is not null),
    'a_excess', (select count(*) from sale_items where sale_id = :'sale_multi_id'::uuid and product_id = (select id from products where sku = 'TFT-A') and applied_promotion_id is null),
    'b_free', (select count(*) from sale_items where sale_id = :'sale_multi_id'::uuid and product_id = (select id from products where sku = 'TFT-B') and sale_unit_price = 0),
    'b_paying', (select count(*) from sale_items where sale_id = :'sale_multi_id'::uuid and product_id = (select id from products where sku = 'TFT-B') and sale_unit_price > 0 and applied_promotion_id is not null),
    'b_excess', (select count(*) from sale_items where sale_id = :'sale_multi_id'::uuid and product_id = (select id from products where sku = 'TFT-B') and applied_promotion_id is null)
  )),
  jsonb_build_object('a_free', 1, 'a_paying', 1, 'a_excess', 0, 'b_free', 0, 'b_paying', 1, 'b_excess', 1),
  'Caso 10: multi-producto reparte free/paying/excedente correctamente según el ranking por precio (TFT-A más barato se lleva la gratis)'
);

-- ===========================================================================
-- Caso 11: promotion_performance_report sobre la venta del caso 1 (múltiplo
-- exacto) -> revenue real (> 0), no $0. Sin cambios en el RPC — el fix está
-- 100% en fn_apply_promotions.
-- ===========================================================================
select ok(
  (
    select (row -> 'revenue')::numeric > 0
    from jsonb_array_elements(
      (promotion_performance_report((current_date - 1)::date, (current_date + 1)::date) -> 'rows')
    ) row
    where (row ->> 'promotion_id')::uuid = :'promo_id'::uuid
  ),
  'Caso 11: promotion_performance_report ya NO muestra $0 para el 3x2 — revenue real > 0, sin tocar el RPC'
);

-- ===========================================================================
-- Casos 12-14: regresión — DUO_PERCENT/KIT_PERCENT/QUANTITY_DISCOUNT sin
-- cambios (auditados como ya correctos, no debían tocarse por este archivo).
-- ===========================================================================
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('TFT-DUO-A', 'Duo A', 'product', 'Test', true, true, true, true),
  ('TFT-DUO-B', 'Duo B', 'product', 'Test', true, true, true, true),
  ('TFT-KIT', 'Kit test', 'product', 'Test', true, true, true, true),
  ('TFT-QTY', 'Cantidad test', 'product', 'Test', true, true, true, true);
select set_product_price((select id from products where sku = s), (select id from price_conditions where code = c), 20000)
from (values ('TFT-DUO-A','LIST'), ('TFT-DUO-A','CASH'), ('TFT-DUO-B','LIST'), ('TFT-DUO-B','CASH'),
             ('TFT-KIT','LIST'), ('TFT-KIT','CASH'), ('TFT-QTY','LIST'), ('TFT-QTY','CASH')) as t(s, c);
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = s), 50, 'RECEPTION')
from (values ('TFT-DUO-A'), ('TFT-DUO-B'), ('TFT-KIT'), ('TFT-QTY')) as t(s);

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable) values
  ('TFT-DUO', 'Duo regresión', 'DUO_PERCENT', :'base_pc_id', 0.10, 41, true),
  ('TFT-KIT', 'Kit regresión', 'KIT_PERCENT', :'base_pc_id', 0.10, 42, true);
select set_promotion_products((select id from promotions where code = 'TFT-DUO'),
  array[(select id from products where sku = 'TFT-DUO-A'), (select id from products where sku = 'TFT-DUO-B')]);
select set_promotion_products((select id from promotions where code = 'TFT-KIT'),
  array[(select id from products where sku = 'TFT-KIT')]);
select id as duo_promo_id from promotions where code = 'TFT-DUO' \gset
select id as kit_promo_id from promotions where code = 'TFT-KIT' \gset

select (create_sale(
  jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'TFT-DUO-A'), 'quantity', 3),
    jsonb_build_object('product_id', (select id from products where sku = 'TFT-DUO-B'), 'quantity', 1)
  ),
  :'sed25_id', :'branch_channel_id', :'cash_id'
) ->> 'sale_id')::uuid as sale_duo_id \gset

select is(
  (select jsonb_build_object(
    'a_tagged', (select count(*) from sale_items where sale_id = :'sale_duo_id'::uuid and product_id = (select id from products where sku = 'TFT-DUO-A') and applied_promotion_id is not null),
    'a_untagged', (select count(*) from sale_items where sale_id = :'sale_duo_id'::uuid and product_id = (select id from products where sku = 'TFT-DUO-A') and applied_promotion_id is null)
  )),
  jsonb_build_object('a_tagged', 1, 'a_untagged', 1),
  'Caso 12: DUO_PERCENT sin cambios — pareja tagueada (1), remanente fuera de la pareja sin tag (1), igual que antes de la migración 64'
);

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TFT-KIT'), 'quantity', 5)),
  :'sed25_id', :'branch_channel_id', :'cash_id'
) ->> 'sale_id')::uuid as sale_kit_id \gset

select is(
  (select (count(*)::int, sum(quantity)) from sale_items where sale_id = :'sale_kit_id'::uuid and applied_promotion_id = :'kit_promo_id'::uuid),
  (1, 5::numeric),
  'Caso 13: KIT_PERCENT sin cambios — 1 sola fila, toda la cantidad (5) tagueada, sin remanente'
);

-- QUANTITY_DISCOUNT: producto propio (TFT-QTY), promo de cantidad mínima
-- independiente (mismo criterio unitario que kit%).
insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, minimum_quantity) values
  ('TFT-QTY-PROMO', 'Cantidad regresión', 'QUANTITY_DISCOUNT', :'base_pc_id', 0.10, 43, true, 2);
select set_promotion_products((select id from promotions where code = 'TFT-QTY-PROMO'), array[(select id from products where sku = 'TFT-QTY')]);
select id as qty_promo_id from promotions where code = 'TFT-QTY-PROMO' \gset

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TFT-QTY'), 'quantity', 2)),
  :'sed25_id', :'branch_channel_id', :'cash_id'
) ->> 'sale_id')::uuid as sale_qty_id \gset

select is(
  (select (count(*)::int, sum(quantity)) from sale_items where sale_id = :'sale_qty_id'::uuid and applied_promotion_id = :'qty_promo_id'::uuid),
  (1, 2::numeric),
  'Caso 14: QUANTITY_DISCOUNT sin cambios — 1 sola fila, toda la cantidad tagueada, sin remanente'
);

-- ===========================================================================
-- Caso 15: Cambio (create_sale_exchange) sobre la venta con excedente (3
-- filas) no rompe — sigue operando línea por línea. (customer_id ya quedó
-- seteado desde la creación, más arriba.)
-- ===========================================================================
select lives_ok(
  format(
    $$select create_sale_exchange(
      '%s'::uuid,
      (select id from sale_items where sale_id = '%s'::uuid and applied_promotion_id is null limit 1),
      1, '%s'::uuid, 1
    )$$,
    :'sale_excess_id', :'sale_excess_id', (select id from products where sku = 'TFT-B')
  ),
  'Caso 15: create_sale_exchange sobre una venta con split de 3 filas (gratis/pagas/excedente) funciona sin romper'
);

-- ===========================================================================
-- Caso 16: devolución parcial sobre la línea "pagas-en-grupo" — sale_item_net
-- neta correctamente, sin tocar applied_promotion_id de la fila.
-- ===========================================================================
select id as paying_item_id from sale_items
  where sale_id = :'sale_exact_id'::uuid and product_id = (select id from products where sku = 'TFT-A')
    and sale_unit_price > 0 \gset

select create_sale_return(
  :'sale_exact_id'::uuid,
  jsonb_build_array(jsonb_build_object('sale_item_id', :'paying_item_id'::uuid, 'quantity', 1)),
  'CASH'::sale_refund_method,
  null,
  'Test devolución parcial fix 3x2'
);

select is(
  (select (net_quantity, net_line_total, applied_promotion_id) from sale_item_net where sale_item_id = :'paying_item_id'::uuid),
  (1::numeric, 30000::numeric, :'promo_id'::uuid),
  'Caso 16: devolución parcial de 1/2 unidades netea correctamente (net_quantity=1, net_line_total=30000) sin alterar applied_promotion_id'
);

select * from finish();
rollback;
