-- pgTAP: cierre de BLOQUE D — el medio de pago elegido en
-- mark_web_order_paid() es la fuente de verdad final de la venta (no solo
-- payment_status/cuenta), y viewer queda bloqueado en las 2 acciones
-- operativas pero SÍ puede leer la bandeja de Notificaciones.
-- Casos, en orden:
--   1) Caso A: pedido creado PENDING+Transferencia, se cobra en Efectivo ->
--      payment_method_id=CASH, payment_account_id=NULL,
--      payment_status=PAID, billing_status=NOT_REQUIRED.
--   2) Caso B: pedido creado PENDING+Efectivo, se cobra por Transferencia
--      con cuenta -> payment_method_id=TRANSFER, payment_account_id=cuenta
--      elegida, payment_status=PAID, billing_status=PENDING.
--   3) Control: cobrar por Transferencia SIN indicar cuenta (y sin cuenta
--      previa) se rechaza — la cuenta sigue siendo obligatoria para el
--      medio finalmente elegido, no para el original.
--   4) Caso C: pedido creado PENDING+Efectivo, se cobra con CARD_1 y cuenta
--      -> payment_method_id=CARD_1, cuenta persistida,
--      billing_status=PENDING (misma regla que Transferencia).
--   5) Viewer no puede llamar mark_web_order_paid (rechazado en backend,
--      más allá de que la UI ya oculte el botón).
--   6) Viewer no puede llamar deliver_web_pickup.
--   7) Viewer SÍ puede leer web_pending_pickups() de su propia sede (ve la
--      bandeja, solo no puede actuar).
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(7);

insert into auth.users (id, email) values
  ('cc000000-0000-0000-0000-000000000001', 'admin.setup.paidmethod@test.maguirejuve.com'),
  ('cc000000-0000-0000-0000-000000000002', 'viewer25.paidmethod@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'cc000000-0000-0000-0000-000000000001';
update public.profiles set role = 'viewer', active = true where id = 'cc000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'cc000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'cc000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'SED-25';

set role authenticated;
select set_config('request.jwt.claim.sub', 'cc000000-0000-0000-0000-000000000001', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('PAIDM-A', 'Producto Cambio Medio de Pago', 'product', 'Test', true, true, false, true);
select set_product_price((select id from products where sku = 'PAIDM-A'), (select id from price_conditions where rule_type = 'BASE'), 10000);
select set_product_price((select id from products where sku = 'PAIDM-A'), (select id from price_conditions where code = 'CASH'), 9000);
select set_product_price((select id from products where sku = 'PAIDM-A'), (select id from price_conditions where code = 'TRANSFER'), 10000);

insert into public.customers (full_name, dni) values ('Clienta Cambio Medio de Pago (test)', '30777711');

select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'PAIDM-A'), 20, 'RECEPTION');

select id as web_channel_id from sales_channels where code = 'WEB' \gset
select id as sed25_id from stock_locations where code = 'SED-25' \gset
select id as cash_method_id from payment_methods where code = 'CASH' \gset
select id as transfer_method_id from payment_methods where code = 'TRANSFER' \gset
select id as card1_method_id from payment_methods where code = 'CARD_1' \gset
select id as account_1_id from payment_accounts where active order by sort_order limit 1 \gset
select id as account_2_id from payment_accounts where active order by sort_order offset 1 limit 1 \gset
select id as customer_id from customers where dni = '30777711' \gset
select id as a_id from products where sku = 'PAIDM-A' \gset

-- ===========================================================================
-- Caso A: creado PENDING+Transferencia, se cobra en Efectivo.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'transfer_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PENDING'::sale_payment_status
) ->> 'sale_id')::uuid as sale_a_id \gset

select mark_web_order_paid(:'sale_a_id'::uuid, :'cash_method_id'::uuid, null);

select is(
  (select row(payment_method_id, payment_account_id, payment_status, billing_status) from sales where id = :'sale_a_id'),
  row(:'cash_method_id'::uuid, null::uuid, 'PAID'::sale_payment_status, 'NOT_REQUIRED'::sale_billing_status),
  'Caso A: cobrar en Efectivo un pedido creado por Transferencia deja payment_method_id=CASH, cuenta NULL, billing_status NOT_REQUIRED'
);

-- ===========================================================================
-- Caso B: creado PENDING+Efectivo, se cobra por Transferencia con cuenta.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PENDING'::sale_payment_status
) ->> 'sale_id')::uuid as sale_b_id \gset

select mark_web_order_paid(:'sale_b_id'::uuid, :'transfer_method_id'::uuid, :'account_1_id'::uuid);

select is(
  (select row(payment_method_id, payment_account_id, payment_status, billing_status) from sales where id = :'sale_b_id'),
  row(:'transfer_method_id'::uuid, :'account_1_id'::uuid, 'PAID'::sale_payment_status, 'PENDING'::sale_billing_status),
  'Caso B: cobrar por Transferencia un pedido creado en Efectivo persiste el medio y la cuenta finales, billing_status pasa a PENDING'
);

-- ===========================================================================
-- Control: cobrar por Transferencia SIN cuenta (y sin cuenta previa) se
-- rechaza — la cuenta la exige el medio FINAL, no el original.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PENDING'::sale_payment_status
) ->> 'sale_id')::uuid as sale_control_id \gset

select throws_ok(
  format($$select mark_web_order_paid('%s'::uuid, '%s'::uuid, null)$$, :'sale_control_id', :'transfer_method_id'),
  'Control: cobrar por Transferencia sin indicar cuenta (y sin cuenta previa) se rechaza'
);

-- ===========================================================================
-- Caso C: creado PENDING+Efectivo, se cobra con CARD_1 y cuenta.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PENDING'::sale_payment_status
) ->> 'sale_id')::uuid as sale_c_id \gset

select mark_web_order_paid(:'sale_c_id'::uuid, :'card1_method_id'::uuid, :'account_2_id'::uuid);

select is(
  (select row(payment_method_id, payment_account_id, payment_status, billing_status) from sales where id = :'sale_c_id'),
  row(:'card1_method_id'::uuid, :'account_2_id'::uuid, 'PAID'::sale_payment_status, 'PENDING'::sale_billing_status),
  'Caso C: cobrar con CARD_1 persiste el medio y la cuenta, billing_status pasa a PENDING (misma regla que Transferencia)'
);

-- ===========================================================================
-- Caso 5: viewer no puede cobrar (mark_web_order_paid), aunque la UI ya
-- oculte el botón — el backend es la autoridad real.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PENDING'::sale_payment_status
) ->> 'sale_id')::uuid as sale_viewer_pay_id \gset

select set_config('request.jwt.claim.sub', 'cc000000-0000-0000-0000-000000000002', false);

select throws_ok(
  format($$select mark_web_order_paid('%s'::uuid)$$, :'sale_viewer_pay_id'),
  'Caso 5: un viewer no puede cobrar un pedido Web (mark_web_order_paid), lo rechaza el backend'
);

-- ===========================================================================
-- Caso 6: viewer no puede entregar (deliver_web_pickup).
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'cc000000-0000-0000-0000-000000000001', false);
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_viewer_deliver_id \gset

select set_config('request.jwt.claim.sub', 'cc000000-0000-0000-0000-000000000002', false);

select throws_ok(
  format($$select deliver_web_pickup('%s'::uuid)$$, :'sale_viewer_deliver_id'),
  'Caso 6: un viewer no puede entregar un pedido Web (deliver_web_pickup), lo rechaza el backend'
);

-- ===========================================================================
-- Caso 7: viewer SÍ puede leer la bandeja de su propia sede (Sede 25) —
-- solo se le bloquean las acciones, nunca la lectura.
-- ===========================================================================
select is(
  (select count(*)::int from web_pending_pickups() where sale_id = :'sale_viewer_deliver_id'),
  1,
  'Caso 7: el viewer SÍ ve en la bandeja el pedido PAID de su sede (Sede 25) que todavía no se pudo entregar — solo se le bloquean las acciones, nunca la lectura'
);

select * from finish();
rollback;
