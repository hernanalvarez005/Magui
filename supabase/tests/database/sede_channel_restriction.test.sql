-- pgTAP: Ajuste — sede habilitada por usuario + canal Web exclusivo de
-- admin. La restricción de sede en backend (has_location_access) YA existía
-- y ya era rol-agnóstica — este archivo la ejercita explícitamente desde
-- create_sale() y agrega cobertura para el gap real: el canal Web.
-- Correr con: supabase test db  (requiere Supabase CLI + Docker)
begin;
select plan(8);

insert into auth.users (id, email) values
  ('f6000000-0000-0000-0000-000000000001', 'admin.sedes@test.maguirejuve.com'),
  ('f6000000-0000-0000-0000-000000000002', 'seller.sede25@test.maguirejuve.com'),
  ('f6000000-0000-0000-0000-000000000003', 'seller.sede37@test.maguirejuve.com'),
  ('f6000000-0000-0000-0000-000000000004', 'seller.ambas@test.maguirejuve.com'),
  ('f6000000-0000-0000-0000-000000000005', 'seller.sinsede@test.maguirejuve.com');

update public.profiles set role = 'admin', active = true where id = 'f6000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id in (
  'f6000000-0000-0000-0000-000000000002', 'f6000000-0000-0000-0000-000000000003',
  'f6000000-0000-0000-0000-000000000004', 'f6000000-0000-0000-0000-000000000005'
);

insert into public.profile_locations (profile_id, location_id)
  select 'f6000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'f6000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'SED-25';
insert into public.profile_locations (profile_id, location_id)
  select 'f6000000-0000-0000-0000-000000000003', id from public.stock_locations where code = 'SED-37';
insert into public.profile_locations (profile_id, location_id)
  select 'f6000000-0000-0000-0000-000000000004', id from public.stock_locations where code in ('SED-25', 'SED-37');
-- f6...005 (sin sede) deliberadamente sin filas en profile_locations.

set role authenticated;
select set_config('request.jwt.claim.sub', 'f6000000-0000-0000-0000-000000000001', false);
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'PROD-ESP'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'PROD-ESP'), 20, 'RECEPTION');

-- ---------------------------------------------------------------------------
-- Sedes 1: vendedor con solo Sede 25 puede registrar una venta en Sede 25.
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'f6000000-0000-0000-0000-000000000002', false);

select lives_ok(
  $$select create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-ESP'), 'quantity', 1)),
    (select id from stock_locations where code = 'SED-25'),
    (select id from sales_channels where code = 'BRANCH'),
    (select id from payment_methods where code = 'CASH')
  )$$,
  'Sedes 1: vendedor habilitado solo para Sede 25 puede vender en Sede 25'
);

-- ---------------------------------------------------------------------------
-- Sedes 2: vendedor con solo Sede 37 puede registrar una venta en Sede 37.
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'f6000000-0000-0000-0000-000000000003', false);

select lives_ok(
  $$select create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-ESP'), 'quantity', 1)),
    (select id from stock_locations where code = 'SED-37'),
    (select id from sales_channels where code = 'BRANCH'),
    (select id from payment_methods where code = 'CASH')
  )$$,
  'Sedes 2: vendedor habilitado solo para Sede 37 puede vender en Sede 37'
);

-- ---------------------------------------------------------------------------
-- Sedes 3: vendedor con Sede 25 + Sede 37 puede elegir cualquiera de las 2.
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'f6000000-0000-0000-0000-000000000004', false);

select lives_ok(
  $$select create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-ESP'), 'quantity', 1)),
    (select id from stock_locations where code = 'SED-25'),
    (select id from sales_channels where code = 'BRANCH'),
    (select id from payment_methods where code = 'CASH')
  )$$,
  'Sedes 3a: vendedor con ambas sedes puede vender en Sede 25'
);
select lives_ok(
  $$select create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-ESP'), 'quantity', 1)),
    (select id from stock_locations where code = 'SED-37'),
    (select id from sales_channels where code = 'BRANCH'),
    (select id from payment_methods where code = 'CASH')
  )$$,
  'Sedes 3b: el mismo vendedor con ambas sedes también puede vender en Sede 37'
);

-- ---------------------------------------------------------------------------
-- Sedes 4: un vendedor que intenta canal Web (manipulando la request) es
-- rechazado, aunque esté vendiendo desde una sede que sí tiene habilitada.
-- ---------------------------------------------------------------------------
select throws_like(
  $$select create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-ESP'), 'quantity', 1)),
    (select id from stock_locations where code = 'SED-25'),
    (select id from sales_channels where code = 'WEB'),
    (select id from payment_methods where code = 'CASH')
  )$$,
  '%administrador%Web%',
  'Sedes 4: un vendedor no puede registrar una venta con canal Web, ni manipulando la request'
);

-- ---------------------------------------------------------------------------
-- Sedes 5: un vendedor habilitado SOLO para Sede 25 que manda Sede 37
-- manipulando la request es rechazado por el backend (no alcanza con el
-- filtro del selector del frontend).
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'f6000000-0000-0000-0000-000000000002', false);

select throws_like(
  $$select create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-ESP'), 'quantity', 1)),
    (select id from stock_locations where code = 'SED-37'),
    (select id from sales_channels where code = 'BRANCH'),
    (select id from payment_methods where code = 'CASH')
  )$$,
  '%no tiene acceso a esta sucursal%',
  'Sedes 5: vendedor de Sede 25 no puede vender en Sede 37 aunque la mande manualmente'
);

-- ---------------------------------------------------------------------------
-- Sedes 6: un vendedor sin ninguna sede habilitada no puede crear ventas en
-- absoluto (nunca una sede por defecto arbitraria).
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'f6000000-0000-0000-0000-000000000005', false);

select throws_like(
  $$select create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-ESP'), 'quantity', 1)),
    (select id from stock_locations where code = 'SED-25'),
    (select id from sales_channels where code = 'BRANCH'),
    (select id from payment_methods where code = 'CASH')
  )$$,
  '%no tiene acceso a esta sucursal%',
  'Sedes 6: un vendedor sin ninguna sede habilitada no puede crear ventas en ninguna'
);

-- ---------------------------------------------------------------------------
-- Sedes 7: el admin mantiene acceso permitido al canal Web (siempre que
-- también tenga acceso a la sede — has_location_access es rol-agnóstica,
-- y este admin de fixture está en profile_locations de todas las sedes).
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'f6000000-0000-0000-0000-000000000001', false);

select lives_ok(
  $$select create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-ESP'), 'quantity', 1)),
    (select id from stock_locations where code = 'SED-25'),
    (select id from sales_channels where code = 'WEB'),
    (select id from payment_methods where code = 'CASH')
  )$$,
  'Sedes 7: un admin sí puede registrar una venta con canal Web'
);

-- Sedes 8 (stock corresponde a la sede autorizada) ya está cubierto por
-- rls.test.sql ("Seller Sede 25 no ve inventario de Sede 37" / "sí ve el
-- inventario de su propia sede") — Nueva Venta consulta product_stock_status
-- siempre con la sede seleccionada (ya filtrada a las habilitadas), así que
-- no hay una query nueva que probar acá; no se duplica ese test.

select * from finish();
rollback;
