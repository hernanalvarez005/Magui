-- pgTAP: BLOQUE F — Stock disponible transversal (20260201000061).
-- Casos, en orden:
--   1) quantity (físico) NO cambia por la sola existencia de una reserva.
--   2) reserved refleja exactamente la suma de reservas ACTIVE.
--   3) reserved excluye reservas RELEASED (liberadas por cancel_sale).
--   4) available = quantity - reserved.
--   5) available_status se calcula sobre available, no sobre quantity.
--   6) kit_availability.buildable_qty usa el disponible real de cada
--      componente (no el físico crudo).
--   7) create_sale_exchange: intentar consumir más que el disponible del
--      producto nuevo se rechaza (el reservado por un pickup Web pendiente
--      no se puede entregar en un cambio).
--   8) create_sale_exchange: consumir dentro del disponible funciona OK.
--   9) transfer_stock: transferir por encima del disponible de origen se
--      rechaza.
--   10) transfer_stock: transferir dentro del disponible funciona OK.
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(10);

insert into auth.users (id, email) values
  ('aa000000-0000-0000-0000-000000000001', 'admin.setup.stockf@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'aa000000-0000-0000-0000-000000000001';
insert into public.profile_locations (profile_id, location_id)
  select 'aa000000-0000-0000-0000-000000000001', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'aa000000-0000-0000-0000-000000000001', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('STKF-A', 'Producto Stock F A', 'product', 'Test', true, true, false, true),
  ('STKF-COMP', 'Componente Stock F', 'product', 'Test', true, true, false, true),
  ('STKF-KIT', 'Kit Stock F', 'kit', 'Test', false, true, false, true),
  ('STKF-OLD', 'Producto Stock F Old (cambio)', 'product', 'Test', true, true, false, true),
  ('STKF-NEW', 'Producto Stock F New (cambio)', 'product', 'Test', true, true, false, true),
  ('STKF-TR', 'Producto Stock F Transfer', 'product', 'Test', true, true, false, true);

insert into public.kit_components (kit_product_id, component_product_id, quantity) values
  ((select id from products where sku = 'STKF-KIT'), (select id from products where sku = 'STKF-COMP'), 2);

select set_product_price((select id from products where sku = 'STKF-A'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'STKF-A'), (select id from price_conditions where code = 'CASH'), 4500);
select set_product_price((select id from products where sku = 'STKF-COMP'), (select id from price_conditions where rule_type = 'BASE'), 3000);
select set_product_price((select id from products where sku = 'STKF-COMP'), (select id from price_conditions where code = 'CASH'), 2700);
select set_product_price((select id from products where sku = 'STKF-KIT'), (select id from price_conditions where rule_type = 'BASE'), 8000);
select set_product_price((select id from products where sku = 'STKF-KIT'), (select id from price_conditions where code = 'CASH'), 7200);
select set_product_price((select id from products where sku = 'STKF-OLD'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'STKF-OLD'), (select id from price_conditions where code = 'CASH'), 4500);
select set_product_price((select id from products where sku = 'STKF-NEW'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'STKF-NEW'), (select id from price_conditions where code = 'CASH'), 4500);
select set_product_price((select id from products where sku = 'STKF-TR'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'STKF-TR'), (select id from price_conditions where code = 'CASH'), 4500);

insert into public.customers (full_name, dni) values ('Clienta Stock F (test)', '30444411');

select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'STKF-A'), 10, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'STKF-COMP'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'STKF-OLD'), 10, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'STKF-NEW'), 5, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'STKF-TR'), 10, 'RECEPTION');

select id as web_channel_id from sales_channels where code = 'WEB' \gset
select id as presencial_channel_id from sales_channels where code <> 'WEB' limit 1 \gset
select id as sed25_id from stock_locations where code = 'SED-25' \gset
select id as sed37_id from stock_locations where code = 'SED-37' \gset
select id as cash_method_id from payment_methods where code = 'CASH' \gset
select id as customer_id from customers where dni = '30444411' \gset
select id as a_id from products where sku = 'STKF-A' \gset
select id as kit_id from products where sku = 'STKF-KIT' \gset
select id as old_id from products where sku = 'STKF-OLD' \gset
select id as new_id from products where sku = 'STKF-NEW' \gset
select id as tr_id from products where sku = 'STKF-TR' \gset

-- ===========================================================================
-- Casos 1-5: product_stock_status con una reserva ACTIVE de 8/10 en STKF-A.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 8)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_a_id \gset

select is(
  (select quantity from product_stock_status where product_id = :'a_id'::uuid and location_id = :'sed25_id'::uuid),
  10.00::numeric,
  'Caso 1: quantity (físico) sigue en 10 — una reserva nunca toca el físico'
);

select is(
  (select reserved from product_stock_status where product_id = :'a_id'::uuid and location_id = :'sed25_id'::uuid),
  8.00::numeric,
  'Caso 2: reserved refleja exactamente la reserva ACTIVE (8)'
);

-- Cancela la reserva y crea otra de 3 para probar que RELEASED no suma.
select cancel_sale(:'sale_a_id'::uuid, 'Test: liberar reserva para Caso 3');

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 3)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_a2_id \gset

select is(
  (select reserved from product_stock_status where product_id = :'a_id'::uuid and location_id = :'sed25_id'::uuid),
  3.00::numeric,
  'Caso 3: reserved excluye la reserva RELEASED (cancelada) — solo cuenta la ACTIVE nueva (3)'
);

select is(
  (select row(quantity, reserved, available) from product_stock_status where product_id = :'a_id'::uuid and location_id = :'sed25_id'::uuid),
  row(10.00::numeric, 3.00::numeric, 7.00::numeric),
  'Caso 4: available = quantity - reserved (10 - 3 = 7)'
);

select is(
  (select available_status from product_stock_status where product_id = :'a_id'::uuid and location_id = :'sed25_id'::uuid),
  'ok'::text,
  'Caso 5: available_status se calcula sobre available (7, por encima del mínimo), no sobre quantity'
);

-- ===========================================================================
-- Caso 6: kit_availability.buildable_qty usa disponible real del componente.
-- Físico STKF-COMP=20, se reserva 4 -> disponible 16 -> buildable floor(16/2)=8.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'STKF-COMP'), 'quantity', 4)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_comp_id \gset

select is(
  (select buildable_qty from kit_availability where kit_product_id = :'kit_id'::uuid and location_id = :'sed25_id'::uuid),
  8::numeric,
  'Caso 6: kit buildable usa disponible real por componente (floor((20-4)/2) = 8, no floor(20/2) = 10)'
);

-- ===========================================================================
-- Casos 7-8: create_sale_exchange.
-- STKF-NEW: físico 5, se reserva 4 -> disponible 1.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'old_id'::uuid, 'quantity', 2)),
  :'sed25_id'::uuid, :'presencial_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid
) ->> 'sale_id')::uuid as orig_sale_id \gset
select id as orig_item_id from sale_items where sale_id = :'orig_sale_id' \gset

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'new_id'::uuid, 'quantity', 4)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_new_reserve_id \gset

select throws_ok(
  format(
    $$select create_sale_exchange('%s'::uuid, '%s'::uuid, 1, '%s'::uuid, 2)$$,
    :'orig_sale_id', :'orig_item_id', :'new_id'
  ),
  'Caso 7: un cambio no puede consumir más que el disponible del producto nuevo (disponible=1, pide 2)'
);

select lives_ok(
  format(
    $$select create_sale_exchange('%s'::uuid, '%s'::uuid, 1, '%s'::uuid, 1)$$,
    :'orig_sale_id', :'orig_item_id', :'new_id'
  ),
  'Caso 8: un cambio SÍ puede consumir dentro del disponible (disponible=1, pide 1)'
);

-- ===========================================================================
-- Casos 9-10: transfer_stock.
-- STKF-TR: físico 10, se reserva 8 -> disponible 2.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'tr_id'::uuid, 'quantity', 8)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_tr_reserve_id \gset

select throws_ok(
  format(
    $$select transfer_stock('%s'::uuid, '%s'::uuid, jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 3)))$$,
    :'sed25_id', :'sed37_id', :'tr_id'
  ),
  'Caso 9: transferir por encima del disponible de origen se rechaza (disponible=2, pide transferir 3)'
);

select lives_ok(
  format(
    $$select transfer_stock('%s'::uuid, '%s'::uuid, jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 2)))$$,
    :'sed25_id', :'sed37_id', :'tr_id'
  ),
  'Caso 10: transferir dentro del disponible funciona OK (disponible=2, transfiere 2)'
);

select * from finish();
rollback;
