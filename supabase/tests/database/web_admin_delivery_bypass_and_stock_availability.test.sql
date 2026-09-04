-- pgTAP: cierre de los dos puntos pendientes de BLOQUE C (20260201000058) —
-- bypass de admin en deliver_web_pickup + web_admin_stock_availability.
-- Casos, en orden:
--   1) Admin SIN ninguna sede asignada entrega un pickup de Sede 25 -> OK.
--   2) Mismo admin entrega un pickup de Sede 37 -> OK.
--   3) Control (sin cambios): vendedora de Sede 25 sigue pudiendo entregar
--      un pickup de Sede 25 (acceso real, no por el bypass de admin).
--   4) Control (sin cambios): esa misma vendedora sigue SIN poder entregar
--      un pickup de Sede 37 — el bypass es exclusivo de admin.
--   5) web_admin_stock_availability: el admin sin sedes ve disponible REAL
--      (no vacío) para Sede 25 — esto es justamente lo que RLS le esconde
--      hoy en /ventas/nueva vía product_stock_status.
--   6) Disponible baja exactamente por una reserva ACTIVE real (un pickup
--      creado y sin entregar todavía).
--   7) Kits: buildable_qty también refleja el disponible reservado-aware
--      de cada componente, no el físico crudo.
--   8) Un no-admin (vendedor) sigue rechazado por esta RPC.
--   9) p_location_id filtra correctamente — todas las filas devueltas
--      corresponden a esa sede, ninguna a las otras.
--   10) El disponible también refleja una baja de físico real (venta
--       PRESENCIAL, sin pasar por reservas) — no es solo reservation-aware.
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(11);

insert into auth.users (id, email) values
  ('ee000000-0000-0000-0000-000000000001', 'admin.sinsede.deliv@test.maguirejuve.com'),
  ('ee000000-0000-0000-0000-000000000002', 'seller25.deliv@test.maguirejuve.com'),
  ('ee000000-0000-0000-0000-000000000003', 'admin.setup.deliv@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'ee000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'ee000000-0000-0000-0000-000000000002';
update public.profiles set role = 'admin', active = true where id = 'ee000000-0000-0000-0000-000000000003';
-- ee...001 (admin bajo prueba) NO recibe NINGUNA fila en profile_locations
-- a propósito — es exactamente el caso que hay que probar en ambos flujos
-- (entrega y disponibilidad de stock).
insert into public.profile_locations (profile_id, location_id)
  select 'ee000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'SED-25';
insert into public.profile_locations (profile_id, location_id)
  select 'ee000000-0000-0000-0000-000000000003', id from public.stock_locations;

-- El admin de setup (con acceso a todo) arma el catálogo de prueba.
set role authenticated;
select set_config('request.jwt.claim.sub', 'ee000000-0000-0000-0000-000000000003', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('WSTOCK-A', 'Producto Web Bypass Entrega', 'product', 'Test', true, true, false, true),
  ('WSTOCK-B', 'Producto Web Disponibilidad', 'product', 'Test', true, true, false, true),
  ('WSTOCK-COMP', 'Componente Web Disponibilidad', 'product', 'Test', true, true, false, true),
  ('WSTOCK-KIT', 'Kit Web Disponibilidad', 'kit', 'Test', false, true, false, true),
  ('WSTOCK-PRES', 'Producto Web Presencial Físico', 'product', 'Test', true, true, false, true);

insert into public.kit_components (kit_product_id, component_product_id, quantity) values
  ((select id from products where sku = 'WSTOCK-KIT'), (select id from products where sku = 'WSTOCK-COMP'), 2);

select set_product_price((select id from products where sku = 'WSTOCK-A'), (select id from price_conditions where rule_type = 'BASE'), 10000);
select set_product_price((select id from products where sku = 'WSTOCK-A'), (select id from price_conditions where code = 'CASH'), 9000);
select set_product_price((select id from products where sku = 'WSTOCK-B'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'WSTOCK-B'), (select id from price_conditions where code = 'CASH'), 4500);
select set_product_price((select id from products where sku = 'WSTOCK-COMP'), (select id from price_conditions where rule_type = 'BASE'), 3000);
select set_product_price((select id from products where sku = 'WSTOCK-COMP'), (select id from price_conditions where code = 'CASH'), 2700);
select set_product_price((select id from products where sku = 'WSTOCK-KIT'), (select id from price_conditions where rule_type = 'BASE'), 8000);
select set_product_price((select id from products where sku = 'WSTOCK-KIT'), (select id from price_conditions where code = 'CASH'), 7200);
select set_product_price((select id from products where sku = 'WSTOCK-PRES'), (select id from price_conditions where rule_type = 'BASE'), 2000);
select set_product_price((select id from products where sku = 'WSTOCK-PRES'), (select id from price_conditions where code = 'CASH'), 1800);

insert into public.customers (full_name, dni) values ('Clienta Web Disponibilidad (test)', '30999933');

select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'WSTOCK-A'), 10, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'WSTOCK-A'), 10, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'WSTOCK-B'), 30, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'WSTOCK-COMP'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'WSTOCK-PRES'), 15, 'RECEPTION');

select id as web_channel_id from sales_channels where code = 'WEB' \gset
select id as presencial_channel_id from sales_channels where code <> 'WEB' limit 1 \gset
select id as sed25_id from stock_locations where code = 'SED-25' \gset
select id as sed37_id from stock_locations where code = 'SED-37' \gset
select id as cash_method_id from payment_methods where code = 'CASH' \gset
select id as customer_id from customers where dni = '30999933' \gset
select id as a_id from products where sku = 'WSTOCK-A' \gset
select id as b_id from products where sku = 'WSTOCK-B' \gset
select id as comp_id from products where sku = 'WSTOCK-COMP' \gset
select id as kit_id from products where sku = 'WSTOCK-KIT' \gset
select id as pres_id from products where sku = 'WSTOCK-PRES' \gset

-- El admin de setup crea los 4 pickups que se van a entregar en los casos
-- 1-4 (canal Web es admin-only, no depende de quién los entrega después).
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_1_id \gset

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed37_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_2_id \gset

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_3_id \gset

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed37_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_4_id \gset

-- ===========================================================================
-- Casos 1-2: admin SIN ninguna sede asignada entrega pickups de Sede 25 y 37.
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'ee000000-0000-0000-0000-000000000001', false);

select lives_ok(
  format($$select deliver_web_pickup('%s'::uuid)$$, :'sale_1_id'),
  'Caso 1: admin sin Sede 25 asignada SÍ puede entregar un pickup de Sede 25'
);

select lives_ok(
  format($$select deliver_web_pickup('%s'::uuid)$$, :'sale_2_id'),
  'Caso 2: el mismo admin SÍ puede entregar un pickup de Sede 37'
);

-- ===========================================================================
-- Casos 3-4 (control, sin cambios): vendedora de Sede 25 sigue pudiendo
-- entregar Sede 25, sigue sin poder entregar Sede 37.
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'ee000000-0000-0000-0000-000000000002', false);

select lives_ok(
  format($$select deliver_web_pickup('%s'::uuid)$$, :'sale_3_id'),
  'Caso 3 (control): vendedora de Sede 25 sigue pudiendo entregar un pickup de Sede 25 (acceso real)'
);

select throws_ok(
  format($$select deliver_web_pickup('%s'::uuid)$$, :'sale_4_id'),
  'Caso 4 (control): vendedora de Sede 25 sigue SIN poder entregar un pickup de Sede 37'
);

-- ===========================================================================
-- Caso 5: el admin sin sedes ve disponible REAL (no vacío) para Sede 25.
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'ee000000-0000-0000-0000-000000000001', false);

select is(
  (select available from web_admin_stock_availability(:'sed25_id'::uuid) where product_id = :'b_id'::uuid),
  30.00::numeric,
  'Caso 5: admin sin Sede 25 asignada ve disponible=30 vía la RPC (RLS se lo esconde en product_stock_status)'
);

-- ===========================================================================
-- Caso 6: disponible baja exactamente por una reserva ACTIVE real.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'b_id'::uuid, 'quantity', 12)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_6_id \gset

select is(
  (select available from web_admin_stock_availability(:'sed25_id'::uuid) where product_id = :'b_id'::uuid),
  18.00::numeric,
  'Caso 6: tras reservar 12 (pickup sin entregar), disponible baja a 18 (30 - 12)'
);

-- ===========================================================================
-- Caso 7: buildable_qty de un kit usa el disponible reservado-aware del
-- componente, no el físico crudo.
-- ===========================================================================
select is(
  (select available from web_admin_stock_availability(:'sed25_id'::uuid) where product_id = :'kit_id'::uuid and is_kit),
  10.00::numeric,
  'Caso 7a: antes de reservar nada del componente, el kit arma 10 (floor(20/2))'
);

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'kit_id'::uuid, 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_7_id \gset

select is(
  (select available from web_admin_stock_availability(:'sed25_id'::uuid) where product_id = :'kit_id'::uuid and is_kit),
  9.00::numeric,
  'Caso 7b: al reservar 2 unidades del componente (1 kit), el kit arma 9 (floor((20-2)/2))'
);

-- ===========================================================================
-- Caso 8: un no-admin (vendedor) sigue rechazado por esta RPC.
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'ee000000-0000-0000-0000-000000000002', false);

select throws_ok(
  $$select * from web_admin_stock_availability()$$,
  'Caso 8: un vendedor no puede llamar web_admin_stock_availability (solo admin)'
);

-- ===========================================================================
-- Caso 9: p_location_id filtra — todas las filas devueltas son de esa sede.
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'ee000000-0000-0000-0000-000000000001', false);

select is(
  (select count(*)::int from web_admin_stock_availability(:'sed25_id'::uuid) where location_id <> :'sed25_id'::uuid),
  0,
  'Caso 9: con p_location_id=Sede 25, ninguna fila devuelta pertenece a otra sede'
);

-- ===========================================================================
-- Caso 10: el disponible también refleja una baja de físico real (venta
-- PRESENCIAL, sin pasar por reservas).
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'ee000000-0000-0000-0000-000000000003', false);

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'pres_id'::uuid, 'quantity', 4)),
  :'sed25_id'::uuid, :'presencial_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid
) ->> 'sale_id')::uuid as sale_10_id \gset

select set_config('request.jwt.claim.sub', 'ee000000-0000-0000-0000-000000000001', false);

select is(
  (select available from web_admin_stock_availability(:'sed25_id'::uuid) where product_id = :'pres_id'::uuid),
  11.00::numeric,
  'Caso 10: una venta presencial (sin reserva) baja el físico y la RPC lo refleja (15 - 4 = 11)'
);

select * from finish();
rollback;
