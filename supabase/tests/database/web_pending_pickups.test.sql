-- pgTAP: web_pending_pickups (BLOQUE D — bandeja de Notificaciones).
-- Casos, en orden:
--   1) Admin sin ninguna sede asignada ve TODOS los pendientes (Sede 25 y
--      Sede 37), sin depender de profile_locations.
--   2) Vendedora de Sede 25 ve solo el pendiente de Sede 25.
--   3) Vendedor de Sede 37 ve solo el pendiente de Sede 37.
--   4) Nunca incluye SHIPPING (fulfillment_status=SHIPPED desde que se crea).
--   5) Nunca incluye un pedido ya DELIVERED.
--   6) Nunca incluye un pedido cancelado (aunque siga PENDING_PICKUP).
--   7) Nunca incluye una venta presencial (no-Web).
--   8) Devuelve los campos esperados para un pedido real: cliente, DNI,
--      items (con cantidad y kit/no-kit), total, medio de pago,
--      payment_status, sede de retiro, quién cargó la venta.
--   9) Un kit aparece en items con is_kit=true.
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(11);

insert into auth.users (id, email) values
  ('dd000000-0000-0000-0000-000000000001', 'admin.sinsede.notif@test.maguirejuve.com'),
  ('dd000000-0000-0000-0000-000000000002', 'seller25.notif@test.maguirejuve.com'),
  ('dd000000-0000-0000-0000-000000000003', 'seller37.notif@test.maguirejuve.com'),
  ('dd000000-0000-0000-0000-000000000004', 'admin.setup.notif@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true, full_name = 'Admin Sin Sede (test)' where id = 'dd000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true, full_name = 'Vendedora Sede 25 (test)' where id = 'dd000000-0000-0000-0000-000000000002';
update public.profiles set role = 'seller', active = true, full_name = 'Vendedor Sede 37 (test)' where id = 'dd000000-0000-0000-0000-000000000003';
update public.profiles set role = 'admin', active = true, full_name = 'Admin Setup (test)' where id = 'dd000000-0000-0000-0000-000000000004';
-- dd...001 (admin bajo prueba) NO recibe NINGUNA fila en profile_locations
-- a propósito.
insert into public.profile_locations (profile_id, location_id)
  select 'dd000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'SED-25';
insert into public.profile_locations (profile_id, location_id)
  select 'dd000000-0000-0000-0000-000000000003', id from public.stock_locations where code = 'SED-37';
insert into public.profile_locations (profile_id, location_id)
  select 'dd000000-0000-0000-0000-000000000004', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'dd000000-0000-0000-0000-000000000004', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('NOTIF-A', 'Producto Notif A', 'product', 'Test', true, true, false, true),
  ('NOTIF-COMP', 'Componente Notif', 'product', 'Test', true, true, false, true),
  ('NOTIF-KIT', 'Kit Notif', 'kit', 'Test', false, true, false, true);
insert into public.kit_components (kit_product_id, component_product_id, quantity) values
  ((select id from products where sku = 'NOTIF-KIT'), (select id from products where sku = 'NOTIF-COMP'), 2);

select set_product_price((select id from products where sku = 'NOTIF-A'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'NOTIF-A'), (select id from price_conditions where code = 'CASH'), 4500);
select set_product_price((select id from products where sku = 'NOTIF-COMP'), (select id from price_conditions where rule_type = 'BASE'), 3000);
select set_product_price((select id from products where sku = 'NOTIF-COMP'), (select id from price_conditions where code = 'CASH'), 2700);
select set_product_price((select id from products where sku = 'NOTIF-KIT'), (select id from price_conditions where rule_type = 'BASE'), 8000);
select set_product_price((select id from products where sku = 'NOTIF-KIT'), (select id from price_conditions where code = 'CASH'), 7200);

insert into public.customers (full_name, dni) values ('Clienta Notif (test)', '30888811');

select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'NOTIF-A'), 10, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'NOTIF-A'), 10, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'NOTIF-COMP'), 10, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'NOTIF-COMP'), 10, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'NOTIF-A'), 10, 'RECEPTION');

select id as web_channel_id from sales_channels where code = 'WEB' \gset
select id as presencial_channel_id from sales_channels where code <> 'WEB' limit 1 \gset
select id as sed25_id from stock_locations where code = 'SED-25' \gset
select id as sed37_id from stock_locations where code = 'SED-37' \gset
select id as dep_id from stock_locations where code = 'DEP' \gset
select id as cash_method_id from payment_methods where code = 'CASH' \gset
select id as customer_id from customers where dni = '30888811' \gset
select id as a_id from products where sku = 'NOTIF-A' \gset
select id as kit_id from products where sku = 'NOTIF-KIT' \gset

-- Pedido pendiente de Sede 25.
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 2)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PENDING'::sale_payment_status
) ->> 'sale_id')::uuid as sale_25_id \gset

-- Pedido pendiente de Sede 37 (kit, para el caso 9).
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'kit_id'::uuid, 'quantity', 1)),
  :'sed37_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_37_id \gset

-- SHIPPING (nunca debe aparecer).
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'dep_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'SHIPPING'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_shipping_id \gset

-- Un pickup que se va a entregar (nunca debe aparecer después de entregado).
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_to_deliver_id \gset
select deliver_web_pickup(:'sale_to_deliver_id'::uuid);

-- Un pickup que se va a cancelar (nunca debe aparecer después, aunque
-- fulfillment_status siga PENDING_PICKUP).
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_to_cancel_id \gset
select cancel_sale(:'sale_to_cancel_id'::uuid, 'Cliente se arrepintió (test)');

-- Venta presencial (nunca debe aparecer).
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed25_id'::uuid, :'presencial_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid
) ->> 'sale_id')::uuid as sale_presencial_id \gset

-- ===========================================================================
-- Caso 1: admin sin ninguna sede asignada ve TODOS los pendientes.
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'dd000000-0000-0000-0000-000000000001', false);

select is(
  (select count(*)::int from web_pending_pickups()),
  2,
  'Caso 1: admin sin sedes asignadas ve los 2 pendientes (Sede 25 + Sede 37), nunca 0'
);

select is(
  (select count(*)::int from web_pending_pickups() where sale_id in (:'sale_25_id', :'sale_37_id')),
  2,
  'Caso 1b: exactamente los 2 pedidos esperados están en la lista del admin'
);

-- ===========================================================================
-- Caso 2: vendedora de Sede 25 ve solo el de Sede 25.
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'dd000000-0000-0000-0000-000000000002', false);

select is(
  (select array_agg(sale_id) from web_pending_pickups()),
  array[:'sale_25_id'::uuid],
  'Caso 2: vendedora de Sede 25 ve únicamente el pendiente de Sede 25'
);

-- ===========================================================================
-- Caso 3: vendedor de Sede 37 ve solo el de Sede 37.
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'dd000000-0000-0000-0000-000000000003', false);

select is(
  (select array_agg(sale_id) from web_pending_pickups()),
  array[:'sale_37_id'::uuid],
  'Caso 3: vendedor de Sede 37 ve únicamente el pendiente de Sede 37'
);

-- ===========================================================================
-- Casos 4-7: exclusiones (vuelvo a admin, que ve todo salvo lo excluido).
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'dd000000-0000-0000-0000-000000000001', false);

select is(
  (select count(*)::int from web_pending_pickups() where sale_id = :'sale_shipping_id'),
  0,
  'Caso 4: un pedido SHIPPING nunca aparece'
);

select is(
  (select count(*)::int from web_pending_pickups() where sale_id = :'sale_to_deliver_id'),
  0,
  'Caso 5: un pedido ya DELIVERED nunca aparece'
);

select is(
  (select count(*)::int from web_pending_pickups() where sale_id = :'sale_to_cancel_id'),
  0,
  'Caso 6: un pedido cancelado nunca aparece, aunque fulfillment_status siga PENDING_PICKUP'
);

select is(
  (select count(*)::int from web_pending_pickups() where sale_id = :'sale_presencial_id'),
  0,
  'Caso 7: una venta presencial (no-Web) nunca aparece'
);

-- ===========================================================================
-- Caso 8: datos completos del pedido de Sede 25.
-- ===========================================================================
select is(
  (select row(customer_name, customer_dni, total, payment_method_name, payment_status, pickup_location_code, seller_name)
   from web_pending_pickups() where sale_id = :'sale_25_id'),
  row(
    'Clienta Notif (test)'::text, '30888811'::text, 9000.00::numeric, 'Efectivo'::text,
    'PENDING'::sale_payment_status, 'SED-25'::text, 'Admin Setup (test)'::text
  ),
  'Caso 8: cliente, DNI, total, medio de pago, payment_status, sede y vendedor son correctos'
);

select is(
  (select items from web_pending_pickups() where sale_id = :'sale_25_id'),
  '[{"is_kit": false, "quantity": 2.00, "product_name": "Producto Notif A"}]'::jsonb,
  'Caso 8b: items trae producto, cantidad e is_kit=false'
);

-- ===========================================================================
-- Caso 9: un kit aparece con is_kit=true.
-- ===========================================================================
select is(
  (select items from web_pending_pickups() where sale_id = :'sale_37_id'),
  '[{"is_kit": true, "quantity": 1.00, "product_name": "Kit Notif"}]'::jsonb,
  'Caso 9: un kit aparece en items con is_kit=true'
);

select * from finish();
rollback;
