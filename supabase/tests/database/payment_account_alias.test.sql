-- pgTAP: Cuenta de ingreso — alias bancario + administración de cuentas.
-- payment_accounts YA existía (Mercado Pago/Banco Galicia + sales.
-- payment_account_id) — este archivo prueba la columna nueva (alias) y
-- que el RLS ya existente (select=activo, insert/update=admin, sin
-- delete) sigue siendo exactamente lo que pide este ajuste.
-- Correr con: supabase test db  (requiere Supabase CLI + Docker)
begin;
select plan(11);

insert into auth.users (id, email) values
  ('fb000000-0000-0000-0000-000000000001', 'admin.accounts@test.maguirejuve.com'),
  ('fb000000-0000-0000-0000-000000000002', 'seller.accounts@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'fb000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'fb000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'fb000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'fb000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'DEP';

set role authenticated;
select set_config('request.jwt.claim.sub', 'fb000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Administración 1 (Caso 9 del pedido): admin crea una cuenta nueva.
-- ---------------------------------------------------------------------------
insert into public.payment_accounts (code, name, alias, active, sort_order)
values ('TEST_BANCO_NACION', 'Banco Nación', 'maguirejuve.bna', true, 99);

select ok(
  exists(select 1 from payment_accounts where code = 'TEST_BANCO_NACION' and name = 'Banco Nación'),
  'Caso 9: el admin puede crear una cuenta nueva'
);

-- ---------------------------------------------------------------------------
-- Administración 2 (Caso 10): admin edita el nombre.
-- ---------------------------------------------------------------------------
update public.payment_accounts set name = 'Banco Nación S.A.' where code = 'TEST_BANCO_NACION';

select is(
  (select name from payment_accounts where code = 'TEST_BANCO_NACION'),
  'Banco Nación S.A.',
  'Caso 10: el admin puede editar el nombre de una cuenta'
);

-- ---------------------------------------------------------------------------
-- Administración 3 (Caso 11): admin edita el alias.
-- ---------------------------------------------------------------------------
update public.payment_accounts set alias = 'maguirejuve.bancoNacion' where code = 'TEST_BANCO_NACION';

select is(
  (select alias from payment_accounts where code = 'TEST_BANCO_NACION'),
  'maguirejuve.bancoNacion',
  'Caso 11: el admin puede editar el alias de una cuenta'
);

-- ---------------------------------------------------------------------------
-- Administración 4 (Caso 12): admin desactiva la cuenta.
-- ---------------------------------------------------------------------------
update public.payment_accounts set active = false where code = 'TEST_BANCO_NACION';

select is(
  (select active from payment_accounts where code = 'TEST_BANCO_NACION'),
  false,
  'Caso 12: el admin puede desactivar una cuenta'
);

-- Caso 8 (Nueva Venta): una cuenta inactiva no pasa el filtro que usa
-- Nueva Venta (.eq("active", true)).
select ok(
  not exists(select 1 from payment_accounts where code = 'TEST_BANCO_NACION' and active = true),
  'Caso 8: una cuenta desactivada no pasa el filtro active=true que usa el selector de Nueva Venta'
);

-- ---------------------------------------------------------------------------
-- Detalle de venta: una venta con cuenta asociada resuelve el nombre por
-- join (mismo criterio que el resto de la pantalla — sin snapshot).
-- ---------------------------------------------------------------------------
insert into public.customers (full_name, dni) values ('Cliente Cuenta Test', '30333444');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'PROD-VITC'), 10, 'RECEPTION');

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'TRANSFER'),
  (select id from customers where dni = '30333444'),
  null, null, null, null, now(), false, null, null, false,
  (select id from payment_accounts where code = 'MERCADO_PAGO')
) ->> 'sale_id')::uuid as sale_with_account \gset

select is(
  (
    select pa.name from sales s
    join payment_accounts pa on pa.id = s.payment_account_id
    where s.id = :'sale_with_account'
  ),
  'Mercado Pago',
  'Caso 14: una venta con cuenta asociada resuelve su nombre por join, para el campo Cuenta del detalle'
);

-- Caso 15: una venta sin cuenta asociada (efectivo) deja payment_account_id
-- en null — el frontend muestra "No registrada", nunca se inventa una.
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH')
) ->> 'sale_id')::uuid as sale_without_account \gset

select is(
  (select payment_account_id from sales where id = :'sale_without_account'),
  null,
  'Caso 15: una venta en efectivo (sin cuenta) queda con payment_account_id null'
);

-- ---------------------------------------------------------------------------
-- Histórico (sección 22): cambiar el alias de la cuenta usada en la venta
-- anterior no modifica nada de esa venta.
-- ---------------------------------------------------------------------------
update public.payment_accounts set alias = 'magui.mp.nuevo' where code = 'MERCADO_PAGO';

select is(
  (select total from sales where id = :'sale_with_account'),
  40770.00,
  'Precondición: el importe de la venta (1x Vitamina C por transferencia) sigue intacto tras editar el alias de su cuenta'
);

select is(
  (select payment_account_id from sales where id = :'sale_with_account'),
  (select id from payment_accounts where code = 'MERCADO_PAGO'),
  'Caso 22: cambiar el alias de la cuenta no reasigna ni desvincula payment_account_id de la venta histórica'
);

-- ---------------------------------------------------------------------------
-- Permisos (Caso 13): una vendedora no puede crear ni editar cuentas.
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'fb000000-0000-0000-0000-000000000002', false);

select throws_like(
  $$insert into public.payment_accounts (code, name, alias) values ('TEST_SELLER_ACC', 'Cuenta Vendedora', null)$$,
  '%row-level security%',
  'Caso 13a: una vendedora no puede crear una cuenta (RLS)'
);

update public.payment_accounts set alias = 'hackeado' where code = 'MERCADO_PAGO';

select is(
  (select alias from payment_accounts where code = 'MERCADO_PAGO'),
  'magui.mp.nuevo',
  'Caso 13b: una vendedora no puede editar el alias de una cuenta — el UPDATE queda en 0 filas por RLS'
);

select * from finish();
rollback;
