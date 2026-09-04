-- pgTAP: BLOQUE C (cierre) — permisos de fulfillment para admin sin
-- profile_locations + timing de billing_status vs payment_status.
-- Casos, en orden:
--   1) Admin SIN ninguna sede asignada en profile_locations puede crear
--      WEB+PICKUP_25.
--   2) Mismo admin puede crear WEB+PICKUP_37.
--   3) Mismo admin puede crear WEB+SHIPPING (Depósito).
--   4) El MISMO admin sigue SIN poder crear una venta PRESENCIAL en Sede 25
--      — el bypass nunca aplica fuera del canal Web (control negativo).
--   5) Un vendedor CON acceso a Sede 25 sigue sin poder crear WEB+PICKUP_25
--      — el bypass es exclusivo de admin, el chequeo de rol para Web sigue
--      cortando antes (control negativo).
--   6) WEB + PENDING + Transferencia: billing_status queda NOT_REQUIRED al
--      crear (no antes de tiempo).
--   7) mark_web_order_paid sobre ese pedido activa billing_status=PENDING
--      recién en ese momento.
--   8) Control: WEB + PAID + Transferencia sigue con billing_status=PENDING
--      desde la creación (comportamiento de siempre, sin cambios).
--   9) Control: venta PRESENCIAL + Transferencia sigue con
--      billing_status=PENDING desde la creación (comportamiento de
--      siempre, sin cambios — payment_status ni existe para estas ventas).
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(10);

insert into auth.users (id, email) values
  ('ff000000-0000-0000-0000-000000000001', 'admin.sinsede.webful@test.maguirejuve.com'),
  ('ff000000-0000-0000-0000-000000000002', 'seller25.webful@test.maguirejuve.com'),
  ('ff000000-0000-0000-0000-000000000003', 'admin.setup.webful@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'ff000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'ff000000-0000-0000-0000-000000000002';
update public.profiles set role = 'admin', active = true where id = 'ff000000-0000-0000-0000-000000000003';
-- ff...001 (el admin bajo prueba) NO recibe NINGUNA fila en profile_locations
-- a propósito — es exactamente el caso que hay que probar.
insert into public.profile_locations (profile_id, location_id)
  select 'ff000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'SED-25';
insert into public.profile_locations (profile_id, location_id)
  select 'ff000000-0000-0000-0000-000000000003', id from public.stock_locations;

-- El admin de setup (con acceso a todo) arma el catálogo de prueba.
set role authenticated;
select set_config('request.jwt.claim.sub', 'ff000000-0000-0000-0000-000000000003', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('WPERM-A', 'Producto Permisos Web', 'product', 'Test', true, true, false, true);
select set_product_price((select id from products where sku = 'WPERM-A'), (select id from price_conditions where rule_type = 'BASE'), 20000);
select set_product_price((select id from products where sku = 'WPERM-A'), (select id from price_conditions where code = 'CASH'), 18000);
select set_product_price((select id from products where sku = 'WPERM-A'), (select id from price_conditions where code = 'TRANSFER'), 20000);

insert into public.customers (full_name, dni) values ('Clienta Permisos Web (test)', '30999922');

select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'WPERM-A'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'WPERM-A'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'WPERM-A'), 20, 'RECEPTION');

select id as web_channel_id from sales_channels where code = 'WEB' \gset
select id as presencial_channel_id from sales_channels where code <> 'WEB' limit 1 \gset
select id as sed25_id from stock_locations where code = 'SED-25' \gset
select id as sed37_id from stock_locations where code = 'SED-37' \gset
select id as dep_id from stock_locations where code = 'DEP' \gset
select id as cash_method_id from payment_methods where code = 'CASH' \gset
select id as transfer_method_id from payment_methods where code = 'TRANSFER' \gset
select id as account_id from payment_accounts where active limit 1 \gset
select id as customer_id from customers where dni = '30999922' \gset

-- ===========================================================================
-- Casos 1-3: admin SIN ninguna sede asignada puede crear los 3 fulfillment.
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', 'ff000000-0000-0000-0000-000000000001', false);

select is(
  (select count(*)::int from profile_locations where profile_id = 'ff000000-0000-0000-0000-000000000001'),
  0,
  'Control: el admin bajo prueba efectivamente no tiene NINGUNA fila en profile_locations'
);

select lives_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid,
      null, null, null, null, now(), false, null, null, false, null,
      'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
    )$$,
    (select id from products where sku = 'WPERM-A'), :'sed25_id', :'web_channel_id', :'cash_method_id', :'customer_id'
  ),
  'Caso 1: admin sin Sede 25 asignada SÍ puede crear WEB+PICKUP_25'
);

select lives_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid,
      null, null, null, null, now(), false, null, null, false, null,
      'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
    )$$,
    (select id from products where sku = 'WPERM-A'), :'sed37_id', :'web_channel_id', :'cash_method_id', :'customer_id'
  ),
  'Caso 2: admin sin Sede 37 asignada SÍ puede crear WEB+PICKUP_37'
);

select lives_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid,
      null, null, null, null, now(), false, null, null, false, null,
      'SHIPPING'::sale_fulfillment_type, 'PAID'::sale_payment_status
    )$$,
    (select id from products where sku = 'WPERM-A'), :'dep_id', :'web_channel_id', :'cash_method_id', :'customer_id'
  ),
  'Caso 3: admin sin Depósito asignado SÍ puede crear WEB+SHIPPING'
);

-- ===========================================================================
-- Caso 4 (control negativo): el MISMO admin sigue sin poder crear una venta
-- PRESENCIAL en Sede 25 — el bypass nunca aplica fuera del canal Web.
-- ===========================================================================
select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid
    )$$,
    (select id from products where sku = 'WPERM-A'), :'sed25_id', :'presencial_channel_id', :'cash_method_id', :'customer_id'
  ),
  'Caso 4: el mismo admin sigue SIN poder crear una venta presencial en Sede 25 sin acceso asignado'
);

-- ===========================================================================
-- Caso 5 (control negativo): vendedor CON acceso a Sede 25 sigue sin poder
-- crear WEB+PICKUP_25 — el bypass es exclusivo de admin.
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', 'ff000000-0000-0000-0000-000000000002', false);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid,
      null, null, null, null, now(), false, null, null, false, null,
      'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
    )$$,
    (select id from products where sku = 'WPERM-A'), :'sed25_id', :'web_channel_id', :'cash_method_id', :'customer_id'
  ),
  'Caso 5: un vendedor con acceso a Sede 25 sigue sin poder crear ventas Web (rol, no sede)'
);

-- ===========================================================================
-- Caso 6: WEB + PENDING + Transferencia -> billing_status NOT_REQUIRED al crear.
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', 'ff000000-0000-0000-0000-000000000003', false);

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'WPERM-A'), 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'transfer_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, :'account_id'::uuid,
  'PICKUP'::sale_fulfillment_type, 'PENDING'::sale_payment_status
) ->> 'sale_id')::uuid as sale_6_id \gset

select is(
  (select billing_status from sales where id = :'sale_6_id'),
  'NOT_REQUIRED'::sale_billing_status,
  'Caso 6: WEB+PENDING+Transferencia queda billing_status NOT_REQUIRED al crear (nunca PENDING antes de tiempo)'
);

-- ===========================================================================
-- Caso 7: mark_web_order_paid activa billing_status=PENDING recién ahí.
-- ===========================================================================
select mark_web_order_paid(:'sale_6_id'::uuid, null, :'account_id'::uuid);

select is(
  (select billing_status from sales where id = :'sale_6_id'),
  'PENDING'::sale_billing_status,
  'Caso 7: al cobrar (mark_web_order_paid), billing_status pasa a PENDING recién ahí'
);

-- ===========================================================================
-- Caso 8 (control): WEB + PAID + Transferencia sigue con billing_status
-- PENDING desde la creación — comportamiento de siempre, sin cambios.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'WPERM-A'), 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'transfer_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, :'account_id'::uuid,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_8_id \gset

select is(
  (select billing_status from sales where id = :'sale_8_id'),
  'PENDING'::sale_billing_status,
  'Caso 8 (control): WEB+PAID+Transferencia sigue con billing_status PENDING desde la creación'
);

-- ===========================================================================
-- Caso 9 (control): venta PRESENCIAL + Transferencia sigue con
-- billing_status PENDING desde la creación — sin cambios.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'WPERM-A'), 'quantity', 1)),
  :'sed25_id'::uuid, :'presencial_channel_id'::uuid, :'transfer_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, :'account_id'::uuid
) ->> 'sale_id')::uuid as sale_9_id \gset

select is(
  (select billing_status from sales where id = :'sale_9_id'),
  'PENDING'::sale_billing_status,
  'Caso 9 (control): venta presencial + Transferencia sigue con billing_status PENDING desde la creación'
);

select * from finish();
rollback;
