-- pgTAP: rol "viewer" (modo observador / solo lectura) — ve dashboard,
-- reportes, ventas, stock y clientes en todas sus sedes; no puede escribir
-- nada, ni por RLS directo ni por RPC. Correr con: supabase test db
-- (Supabase CLI + Docker).
begin;
select plan(12);

insert into auth.users (id, email) values
  ('c1000000-0000-0000-0000-000000000001', 'admin.viewer@test.maguirejuve.com'),
  ('c1000000-0000-0000-0000-000000000002', 'sellerA.viewer@test.maguirejuve.com'),
  ('c1000000-0000-0000-0000-000000000003', 'sellerB.viewer@test.maguirejuve.com'),
  ('c1000000-0000-0000-0000-000000000004', 'observer.viewer@test.maguirejuve.com');

update public.profiles set role = 'admin', active = true where id = 'c1000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'c1000000-0000-0000-0000-000000000002';
update public.profiles set role = 'seller', active = true where id = 'c1000000-0000-0000-0000-000000000003';
update public.profiles set role = 'viewer', active = true, can_view_financial_reports = true
  where id = 'c1000000-0000-0000-0000-000000000004';

insert into public.profile_locations (profile_id, location_id)
  select 'c1000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'c1000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'DEP';
insert into public.profile_locations (profile_id, location_id)
  select 'c1000000-0000-0000-0000-000000000003', id from public.stock_locations where code = 'SED-25';
-- "Todas las sedes" del observador — asignación explícita, igual que un admin.
insert into public.profile_locations (profile_id, location_id)
  select 'c1000000-0000-0000-0000-000000000004', id from public.stock_locations;

-- Vendedora A vende algo en Depósito, para tener datos que el observador
-- deba poder ver aunque no sea suya. set_stock es exclusivo de admin, así
-- que el stock se carga como admin y la venta se hace como la vendedora.
set role authenticated;
select set_config('request.jwt.claim.sub', 'c1000000-0000-0000-0000-000000000001', false);
-- 20, no 10: PROD-VITC tiene default_min_stock = 10 en el seed — con 10
-- unidades, vender 1 ya deja el producto en "bajo" (9 <= 10), lo que no
-- prueba nada distinto pero confunde el nombre del caso de test.
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'PROD-VITC'), 20, 'RECEPTION');

set role authenticated;
select set_config('request.jwt.claim.sub', 'c1000000-0000-0000-0000-000000000002', false);
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH')
) ->> 'sale_id')::uuid as seller_a_sale_id \gset

-- Un admin crea un cliente real para poder probar el UPDATE del observador
-- más abajo contra una fila que existe.
set role authenticated;
select set_config('request.jwt.claim.sub', 'c1000000-0000-0000-0000-000000000001', false);
insert into public.customers (full_name, dni) values ('Cliente Para Update Test', '77777777');

-- ---------------------------------------------------------------------------
-- A partir de acá, todo como el observador.
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'c1000000-0000-0000-0000-000000000004', false);

-- ---------------------------------------------------------------------------
-- LECTURA: tiene que ver todo lo que pidió el bloque.
-- ---------------------------------------------------------------------------
select is(
  (select count(*)::int from sales where id = :'seller_a_sale_id'),
  1,
  'El observador ve una venta que NO hizo él (a diferencia de una vendedora común, que solo ve las propias)'
);

select isnt_empty(
  $$select * from profiles where id = 'c1000000-0000-0000-0000-000000000002'$$,
  'El observador puede leer el perfil (nombre) de otra vendedora — para mostrar "vendido por"'
);

select is(
  (select count(*)::int from profile_locations where profile_id = 'c1000000-0000-0000-0000-000000000004'),
  (select count(*)::int from stock_locations),
  'El observador tiene TODAS las sedes asignadas (mismo criterio que un admin)'
);

select is(
  (select status from product_stock_status
    where product_id = (select id from products where sku = 'PROD-VITC')
      and location_id = (select id from stock_locations where code = 'DEP')),
  'ok',
  'El observador puede leer product_stock_status de una sede aunque no sea suya "de vendedora"'
);

select lives_ok(
  $$select dashboard_report(current_date - 7, current_date)$$,
  'El observador puede llamar a dashboard_report (can_view_financial_reports = true)'
);

select lives_ok(
  $$select * from customers limit 1$$,
  'El observador puede leer la ficha de clientes'
);

-- ---------------------------------------------------------------------------
-- ESCRITURA: nada de esto debe funcionar, ni por RPC ni por RLS directo.
-- ---------------------------------------------------------------------------
select throws_like(
  $$select create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
    (select id from stock_locations where code = 'DEP'),
    (select id from sales_channels limit 1),
    (select id from payment_methods where code = 'CASH')
  )$$,
  '%solo lectura%',
  'create_sale rechaza a un viewer con el mensaje de solo lectura'
);

select throws_like(
  format($$select cancel_sale('%s'::uuid, 'Intento de anulación por observador')$$, :'seller_a_sale_id'),
  '%solo lectura%',
  'cancel_sale rechaza a un viewer con el mensaje de solo lectura'
);

select throws_like(
  $$select adjust_stock(
    (select id from stock_locations where code = 'DEP'),
    (select id from products where sku = 'PROD-VITC'),
    5, 'RECEPTION'
  )$$,
  '%solo lectura%',
  'adjust_stock rechaza a un viewer con el mensaje de solo lectura'
);

select throws_ok(
  $$select set_stock(
    (select id from stock_locations where code = 'DEP'),
    (select id from products where sku = 'PROD-VITC'),
    99, 'RECEPTION'
  )$$,
  'set_stock (exclusivo de admin) rechaza a un viewer'
);

-- customers INSERT: falla el WITH CHECK de la policy -> excepción real de
-- Postgres (a diferencia de un UPDATE filtrado, un INSERT sin fila "vieja"
-- que ocultar no puede quedar en silencio: rechaza con error).
select throws_ok(
  $$insert into public.customers (full_name, dni) values ('Cliente Intento Observador', '99999999')$$,
  'Un viewer no puede crear un cliente — RLS rechaza el INSERT'
);

-- customers UPDATE: acá si el USING de la policy filtra a 0 filas, el UPDATE
-- simplemente no afecta ninguna fila (comportamiento estándar de RLS en
-- Postgres, no lanza excepción) — se verifica por resultado.
update public.customers set full_name = 'Editado Por Observador' where dni = '77777777';
select is(
  (select full_name from customers where dni = '77777777'),
  'Cliente Para Update Test',
  'Un viewer no puede editar un cliente existente — el UPDATE queda en 0 filas por RLS'
);

select * from finish();
rollback;
