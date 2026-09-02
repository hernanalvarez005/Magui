-- pgTAP: Recargo comercial (Opción B) — una condición de pago más cara que
-- Lista es una condición comercial válida, no una excepción.
--   line_discount   = GREATEST((list_unit_price - sale_unit_price) * quantity, 0)
--   line_surcharge  = GREATEST((sale_unit_price - list_unit_price) * quantity, 0)
--   discount_total  = SUM(line_discount)   -- sumado desde las líneas
--   surcharge_total = SUM(line_surcharge)  -- sumado desde las líneas
--   total           = SUM(line_total)
--   total = subtotal - discount_total + surcharge_total
-- Correr con: supabase test db (requiere Supabase CLI + Docker).
begin;
select plan(42);

insert into auth.users (id, email) values
  ('fc200000-0000-0000-0000-000000000001', 'admin.surcharge@test.maguirejuve.com'),
  ('fc200000-0000-0000-0000-000000000002', 'seller.surcharge@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'fc200000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'fc200000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'fc200000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'fc200000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'DEP';

insert into public.customers (full_name, dni) values ('Cliente Recargo Test', '30888444');

set role authenticated;
select set_config('request.jwt.claim.sub', 'fc200000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Catálogo completo (todos los casos), armado de punta a punta como admin
-- antes de vender nada como vendedora — mismo criterio que el resto de los
-- tests de este módulo.
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('TEST-SUR-EQ', 'Igual a Lista', 'product', 'Test', true, true, false, true),
  ('TEST-SUR-DISC', 'Con Descuento', 'product', 'Test', true, true, false, true),
  ('TEST-SUR-SUR', 'Con Recargo', 'product', 'Test', true, true, false, true),
  ('TEST-SUR-P4', 'Promo Bajo Lista', 'product', 'Test', true, true, false, true),
  ('TEST-SUR-P5', 'Promo Sigue Arriba', 'product', 'Test', true, true, false, true),
  ('TEST-SUR-P6', 'Promo Cae Justo En Lista', 'product', 'Test', true, true, false, true),
  ('TEST-SUR-MIXA', 'Mix Con Descuento', 'product', 'Test', true, true, false, true),
  ('TEST-SUR-MIXB', 'Mix Con Recargo', 'product', 'Test', true, true, false, true),
  ('TEST-SUR-KITCOMP', 'Componente Kit Recargo', 'product', 'Test', true, true, false, true),
  ('TEST-SUR-KIT', 'Kit Con Recargo', 'kit', 'Test', false, true, false, true),
  ('TEST-SUR-EXCH-OLD', 'Cambio Original', 'product', 'Test', true, true, false, true),
  ('TEST-SUR-EXCH-NEW', 'Cambio Nuevo Con Recargo', 'product', 'Test', true, true, false, true);

insert into public.kit_components (kit_product_id, component_product_id, quantity)
values ((select id from products where sku = 'TEST-SUR-KIT'), (select id from products where sku = 'TEST-SUR-KITCOMP'), 2);

select set_product_price((select id from products where sku = 'TEST-SUR-EQ'), (select id from price_conditions where rule_type = 'BASE'), 25000);
select set_product_price((select id from products where sku = 'TEST-SUR-EQ'), (select id from price_conditions where code = 'CARD_1'), 25000);

select set_product_price((select id from products where sku = 'TEST-SUR-DISC'), (select id from price_conditions where rule_type = 'BASE'), 30000);
select set_product_price((select id from products where sku = 'TEST-SUR-DISC'), (select id from price_conditions where code = 'CASH'), 25000);

select set_product_price((select id from products where sku = 'TEST-SUR-SUR'), (select id from price_conditions where rule_type = 'BASE'), 30000);
select set_product_price((select id from products where sku = 'TEST-SUR-SUR'), (select id from price_conditions where code = 'TRANSFER'), 33000);

select set_product_price((select id from products where sku = 'TEST-SUR-P4'), (select id from price_conditions where rule_type = 'BASE'), 30000);
select set_product_price((select id from products where sku = 'TEST-SUR-P4'), (select id from price_conditions where code = 'CASH'), 30000);

select set_product_price((select id from products where sku = 'TEST-SUR-P5'), (select id from price_conditions where rule_type = 'BASE'), 30000);
select set_product_price((select id from products where sku = 'TEST-SUR-P5'), (select id from price_conditions where code = 'CASH'), 30000);
select set_product_price((select id from products where sku = 'TEST-SUR-P5'), (select id from price_conditions where code = 'TRANSFER'), 33000);

select set_product_price((select id from products where sku = 'TEST-SUR-P6'), (select id from price_conditions where rule_type = 'BASE'), 30000);
select set_product_price((select id from products where sku = 'TEST-SUR-P6'), (select id from price_conditions where code = 'CASH'), 30000);
select set_product_price((select id from products where sku = 'TEST-SUR-P6'), (select id from price_conditions where code = 'TRANSFER'), 40000);

select set_product_price((select id from products where sku = 'TEST-SUR-MIXA'), (select id from price_conditions where rule_type = 'BASE'), 30000);
select set_product_price((select id from products where sku = 'TEST-SUR-MIXA'), (select id from price_conditions where code = 'TRANSFER'), 25000);
select set_product_price((select id from products where sku = 'TEST-SUR-MIXB'), (select id from price_conditions where rule_type = 'BASE'), 20000);
select set_product_price((select id from products where sku = 'TEST-SUR-MIXB'), (select id from price_conditions where code = 'TRANSFER'), 23000);

select set_product_price((select id from products where sku = 'TEST-SUR-KIT'), (select id from price_conditions where rule_type = 'BASE'), 50000);
select set_product_price((select id from products where sku = 'TEST-SUR-KIT'), (select id from price_conditions where code = 'TRANSFER'), 53000);

select set_product_price((select id from products where sku = 'TEST-SUR-EXCH-OLD'), (select id from price_conditions where rule_type = 'BASE'), 20000);
select set_product_price((select id from products where sku = 'TEST-SUR-EXCH-OLD'), (select id from price_conditions where code = 'CASH'), 18000);
select set_product_price((select id from products where sku = 'TEST-SUR-EXCH-NEW'), (select id from price_conditions where rule_type = 'BASE'), 25000);
select set_product_price((select id from products where sku = 'TEST-SUR-EXCH-NEW'), (select id from price_conditions where code = 'CASH'), 27000);

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active)
values
  ('TEST-SUR-PROMO4', 'Promo 20% sobre Lista', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.2, 50, false, true),
  ('TEST-SUR-PROMO5', 'Promo 5% sobre Transferencia', 'KIT_PERCENT', (select id from price_conditions where code = 'TRANSFER'), 0.05, 51, false, true),
  ('TEST-SUR-PROMO6', 'Promo 25% sobre Transferencia', 'KIT_PERCENT', (select id from price_conditions where code = 'TRANSFER'), 0.25, 52, false, true);
select set_promotion_products((select id from promotions where code = 'TEST-SUR-PROMO4'), array[(select id from products where sku = 'TEST-SUR-P4')]);
select set_promotion_products((select id from promotions where code = 'TEST-SUR-PROMO5'), array[(select id from products where sku = 'TEST-SUR-P5')]);
select set_promotion_products((select id from promotions where code = 'TEST-SUR-PROMO6'), array[(select id from products where sku = 'TEST-SUR-P6')]);

select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-SUR-EQ'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-SUR-DISC'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-SUR-SUR'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-SUR-P4'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-SUR-P5'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-SUR-P6'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-SUR-MIXA'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-SUR-MIXB'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-SUR-KITCOMP'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-SUR-EXCH-OLD'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-SUR-EXCH-NEW'), 20, 'RECEPTION');

set role authenticated;
select set_config('request.jwt.claim.sub', 'fc200000-0000-0000-0000-000000000002', false);

-- ===========================================================================
-- Caso 1: Lista = venta -> descuento 0 / recargo 0.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-SUR-EQ'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CARD_1'),
  (select id from customers where dni = '30888444'),
  null, null, null, null, now(), false, null, null, false,
  (select id from payment_accounts where code = 'MERCADO_PAGO')
) ->> 'sale_id')::uuid as sale_eq_id \gset

select is((select line_discount from sale_items where sale_id = :'sale_eq_id'), 0.00, 'Caso 1: line_discount = 0 cuando la condición vale igual que Lista');
select is((select line_surcharge from sale_items where sale_id = :'sale_eq_id'), 0.00, 'Caso 1: line_surcharge = 0 cuando la condición vale igual que Lista');
select is((select discount_total from sales where id = :'sale_eq_id'), 0.00, 'Caso 1: discount_total = 0');
select is((select surcharge_total from sales where id = :'sale_eq_id'), 0.00, 'Caso 1: surcharge_total = 0');
select is((select total from sales where id = :'sale_eq_id'), 25000.00, 'Caso 1: total = precio de Lista (25.000)');

-- ===========================================================================
-- Caso 2: venta < Lista -> descuento positivo / recargo 0.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-SUR-DISC'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30888444')
) ->> 'sale_id')::uuid as sale_disc_id \gset

select is((select line_discount from sale_items where sale_id = :'sale_disc_id'), 5000.00, 'Caso 2: line_discount = 5.000 (30.000 Lista - 25.000 Efectivo)');
select is((select line_surcharge from sale_items where sale_id = :'sale_disc_id'), 0.00, 'Caso 2: line_surcharge = 0');
select is((select discount_total from sales where id = :'sale_disc_id'), 5000.00, 'Caso 2: discount_total = 5.000');
select is((select surcharge_total from sales where id = :'sale_disc_id'), 0.00, 'Caso 2: surcharge_total = 0');
select is((select total from sales where id = :'sale_disc_id'), 25000.00, 'Caso 2: total = 25.000');

-- ===========================================================================
-- Caso 3: venta > Lista -> descuento 0 / recargo positivo. El ejemplo
-- original del pedido: Lista $30.000, 3 cuotas $33.000.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-SUR-SUR'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'TRANSFER'),
  (select id from customers where dni = '30888444'),
  null, null, null, null, now(), false, null, null, false,
  (select id from payment_accounts where code = 'MERCADO_PAGO')
) ->> 'sale_id')::uuid as sale_sur_id \gset

select is((select line_discount from sale_items where sale_id = :'sale_sur_id'), 0.00, 'Caso 3: line_discount = 0 — antes esto rompía line_discount >= 0 en el INSERT');
select is((select line_surcharge from sale_items where sale_id = :'sale_sur_id'), 3000.00, 'Caso 3: line_surcharge = 3.000 (33.000 Transferencia - 30.000 Lista)');
select is((select discount_total from sales where id = :'sale_sur_id'), 0.00, 'Caso 3: discount_total = 0');
select is((select surcharge_total from sales where id = :'sale_sur_id'), 3000.00, 'Caso 3: surcharge_total = 3.000');
select is((select total from sales where id = :'sale_sur_id'), 33000.00, 'Caso 3: total = 33.000 (el importe realmente cobrado, no el de Lista)');

-- ===========================================================================
-- Caso 4: promoción deja el precio por DEBAJO de Lista (caso normal).
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-SUR-P4'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30888444')
) ->> 'sale_id')::uuid as sale_p4_id \gset

select is((select line_discount from sale_items where sale_id = :'sale_p4_id'), 6000.00, 'Caso 4: promo 20% sobre Lista $30.000 -> descuento $6.000');
select is((select line_surcharge from sale_items where sale_id = :'sale_p4_id'), 0.00, 'Caso 4: recargo 0');

-- ===========================================================================
-- Caso 5: condición base de la promo YA es más cara que Lista, y el % de la
-- promo no alcanza a bajarla de Lista -> sigue siendo recargo, nunca
-- descuento negativo.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-SUR-P5'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30888444')
) ->> 'sale_id')::uuid as sale_p5_id \gset

-- 33.000 * (1 - 0.05) = 31.350 -> sigue por encima de Lista ($30.000).
select is((select sale_unit_price from sale_items where sale_id = :'sale_p5_id'), 31350.00, 'Precondición Caso 5: el precio post-promo sigue en $31.350');
select is((select line_discount from sale_items where sale_id = :'sale_p5_id'), 0.00, 'Caso 5: descuento 0 (nunca negativo) aunque haya una promoción aplicada');
select is((select line_surcharge from sale_items where sale_id = :'sale_p5_id'), 1350.00, 'Caso 5: recargo $1.350 — la promoción atenúa el recargo pero no lo saca del todo');

-- ===========================================================================
-- Caso 6: condición base > Lista + promoción termina EXACTAMENTE en Lista ->
-- ni descuento ni recargo.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-SUR-P6'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30888444')
) ->> 'sale_id')::uuid as sale_p6_id \gset

-- 40.000 * (1 - 0.25) = 30.000 = Lista exacto.
select is((select sale_unit_price from sale_items where sale_id = :'sale_p6_id'), 30000.00, 'Precondición Caso 6: el precio post-promo cae exacto en Lista ($30.000)');
select is((select line_discount from sale_items where sale_id = :'sale_p6_id'), 0.00, 'Caso 6: descuento 0 cuando cae exacto en Lista');
select is((select line_surcharge from sale_items where sale_id = :'sale_p6_id'), 0.00, 'Caso 6: recargo 0 cuando cae exacto en Lista');

-- ===========================================================================
-- Caso 7: una venta con UNA línea con descuento y OTRA con recargo, bajo la
-- misma forma de pago (Transferencia).
-- ===========================================================================
select (create_sale(
  jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-SUR-MIXA'), 'quantity', 1),
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-SUR-MIXB'), 'quantity', 1)
  ),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'TRANSFER'),
  (select id from customers where dni = '30888444'),
  null, null, null, null, now(), false, null, null, false,
  (select id from payment_accounts where code = 'MERCADO_PAGO')
) ->> 'sale_id')::uuid as sale_mix_id \gset

select is((select line_discount from sale_items where sale_id = :'sale_mix_id' and product_id = (select id from products where sku = 'TEST-SUR-MIXA')), 5000.00, 'Caso 7: la línea A tiene descuento $5.000');
select is((select line_surcharge from sale_items where sale_id = :'sale_mix_id' and product_id = (select id from products where sku = 'TEST-SUR-MIXA')), 0.00, 'Caso 7: la línea A no tiene recargo');
select is((select line_discount from sale_items where sale_id = :'sale_mix_id' and product_id = (select id from products where sku = 'TEST-SUR-MIXB')), 0.00, 'Caso 7: la línea B no tiene descuento');
select is((select line_surcharge from sale_items where sale_id = :'sale_mix_id' and product_id = (select id from products where sku = 'TEST-SUR-MIXB')), 3000.00, 'Caso 7: la línea B tiene recargo $3.000');
select is((select discount_total from sales where id = :'sale_mix_id'), 5000.00, 'Caso 7: discount_total = 5.000 (solo de la línea A)');
select is((select surcharge_total from sales where id = :'sale_mix_id'), 3000.00, 'Caso 7: surcharge_total = 3.000 (solo de la línea B)');
select is((select subtotal from sales where id = :'sale_mix_id'), 50000.00, 'Caso 7: subtotal = 50.000 (30.000 + 20.000, precio de Lista)');
select is((select total from sales where id = :'sale_mix_id'), 48000.00, 'Caso 7: total = 48.000 (25.000 + 23.000) — ni 50.000-5.000 ni 50.000+3.000, la identidad completa');

-- ===========================================================================
-- Caso 8: kit con recargo — la lógica de precio es independiente del fan-out
-- de stock a componentes.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-SUR-KIT'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'TRANSFER'),
  (select id from customers where dni = '30888444'),
  null, null, null, null, now(), false, null, null, false,
  (select id from payment_accounts where code = 'MERCADO_PAGO')
) ->> 'sale_id')::uuid as sale_kit_id \gset

select is((select line_surcharge from sale_items where sale_id = :'sale_kit_id'), 3000.00, 'Caso 8: el kit (como línea comercial única) tiene recargo $3.000');
select is((select total from sales where id = :'sale_kit_id'), 53000.00, 'Caso 8: total = 53.000');
select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-SUR-KITCOMP') and location_id = (select id from stock_locations where code = 'DEP')),
  18.00,
  'Caso 8: el recargo en el precio no altera el fan-out de stock a componentes (2 por kit, 20 -> 18)'
);

-- ===========================================================================
-- Caso 9: venta de reemplazo de Cambios/Devoluciones con recargo en el
-- producto nuevo.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-SUR-EXCH-OLD'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30888444')
) ->> 'sale_id')::uuid as sale_exch_orig_id \gset

select (create_sale_exchange(
  :'sale_exch_orig_id'::uuid,
  (select id from sale_items where sale_id = :'sale_exch_orig_id'),
  1,
  (select id from products where sku = 'TEST-SUR-EXCH-NEW'), 1
)) as result_exch \gset

select is(
  (select line_surcharge from sale_items where sale_id = (:'result_exch'::jsonb ->> 'sale_id')::uuid and product_id = (select id from products where sku = 'TEST-SUR-EXCH-NEW')),
  2000.00,
  'Caso 9: la línea del producto nuevo del cambio tiene recargo $2.000 (27.000 - 25.000)'
);
select is(
  (select surcharge_total from sales where id = (:'result_exch'::jsonb ->> 'sale_id')::uuid),
  2000.00,
  'Caso 9: surcharge_total de la venta de reemplazo = 2.000'
);
select is(
  (select total from sales where id = (:'result_exch'::jsonb ->> 'sale_id')::uuid),
  27000.00,
  'Caso 9: total de la venta de reemplazo = 27.000 (subtotal 25.000 - descuento 0 + recargo 2.000)'
);

-- ===========================================================================
-- Caso 10: las ventas históricas quedan invariantes — una fila con la forma
-- que ya existía ANTES de este cambio (sin especificar surcharge_total ni
-- line_surcharge) sigue insertando limpio, con los campos nuevos en 0 por
-- default, sin alterar ninguno de los valores históricos ya existentes.
-- ===========================================================================
reset role;
insert into public.sales (
  sale_number, sold_at, location_id, sales_channel_id, seller_id, payment_method_id,
  subtotal, discount_total, total, status
) values (
  'MJ-HIST-TEST-0001', now() - interval '30 days',
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  'fc200000-0000-0000-0000-000000000002',
  (select id from payment_methods where code = 'CASH'),
  30000.00, 5000.00, 25000.00, 'confirmed'
) returning id as hist_sale_id \gset

insert into public.sale_items (
  sale_id, product_id, quantity, list_unit_price, sale_unit_price,
  line_list_total, line_discount, line_total
) values (
  :'hist_sale_id', (select id from products where sku = 'TEST-SUR-DISC'), 1, 30000, 25000,
  30000, 5000, 25000
);

select is(
  (select surcharge_total from sales where id = :'hist_sale_id'),
  0.00,
  'Caso 10: una venta "histórica" (insertada sin especificar surcharge_total) queda en 0 por default'
);
select is(
  (select line_surcharge from sale_items where sale_id = :'hist_sale_id'),
  0.00,
  'Caso 10b: su línea (sin especificar line_surcharge) queda en 0 por default'
);
select is(
  (select discount_total from sales where id = :'hist_sale_id'),
  5000.00,
  'Caso 10c: discount_total histórico ($5.000) queda exactamente igual, no se recalcula'
);
select is(
  (select total from sales where id = :'hist_sale_id'),
  25000.00,
  'Caso 10d: total histórico ($25.000) queda exactamente igual, no se recalcula'
);
select lives_ok(
  $$select 1 where (select total from sales where sale_number = 'MJ-HIST-TEST-0001') =
    (select subtotal - discount_total + surcharge_total from sales where sale_number = 'MJ-HIST-TEST-0001')$$,
  'Caso 10e: la fila histórica satisface la nueva identidad total = subtotal - discount_total + surcharge_total sin haber sido tocada'
);

select * from finish();
rollback;
