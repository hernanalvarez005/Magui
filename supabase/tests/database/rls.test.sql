-- pgTAP: Row Level Security — acceso por sede, permisos de precio, usuarios inactivos.
-- Correr con: supabase test db  (requiere Supabase CLI + Docker)
begin;
select plan(7);

insert into auth.users (id, email) values
  ('c0000000-0000-0000-0000-000000000001', 'admin.rls@test.maguirejuve.com'),
  ('c0000000-0000-0000-0000-000000000002', 'seller25.rls@test.maguirejuve.com'),
  ('c0000000-0000-0000-0000-000000000003', 'inactivo.rls@test.maguirejuve.com'),
  ('c0000000-0000-0000-0000-000000000004', 'admin.autorizado.rls@test.maguirejuve.com');

update public.profiles set role = 'admin', active = true where id = 'c0000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'c0000000-0000-0000-0000-000000000002';
update public.profiles set role = 'seller', active = false where id = 'c0000000-0000-0000-0000-000000000003';
update public.profiles set role = 'admin', active = true, can_view_financial_reports = true
  where id = 'c0000000-0000-0000-0000-000000000004';

insert into public.profile_locations (profile_id, location_id)
  select 'c0000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'c0000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'SED-25';
insert into public.profile_locations (profile_id, location_id)
  select 'c0000000-0000-0000-0000-000000000004', id from public.stock_locations;

set role authenticated;

-- Seller de Sede 25 no puede ver stock de Sede 37 (RLS por sede)
select set_config('request.jwt.claim.sub', 'c0000000-0000-0000-0000-000000000002', false);
select is(
  (select count(*)::int from public.inventory_balances ib
     join public.stock_locations sl on sl.id = ib.location_id where sl.code = 'SED-37'),
  0,
  'Seller Sede 25 no ve inventario de Sede 37'
);

select is(
  (select count(*)::int from public.inventory_balances ib
     join public.stock_locations sl on sl.id = ib.location_id where sl.code = 'SED-25'),
  6,
  'Seller Sede 25 sí ve el inventario de su propia sede'
);

-- Seller no puede modificar precios
select throws_ok(
  $$select set_product_price(
    (select id from products where sku='PROD-VITC'),
    (select id from price_conditions where code='LIST'),
    99999
  )$$,
  'Seller no puede modificar precios (set_product_price)'
);

-- Seller no puede ver comisiones/ventas de otro vendedor (columna commission_total incluida
-- porque sales_select exige seller_id = auth.uid() salvo admin)
select is(
  (select count(*)::int from public.sales where seller_id <> 'c0000000-0000-0000-0000-000000000002'),
  0,
  'Seller no ve ventas de otros vendedores (ni su comisión) vía SELECT directo'
);

-- Admin autorizado (con acceso a ambas sedes) sí puede operar sobre ambas
select set_config('request.jwt.claim.sub', 'c0000000-0000-0000-0000-000000000004', false);
select is(
  (select count(*)::int from public.inventory_balances),
  12,
  'Admin con acceso a ambas sedes ve el inventario completo (6+6)'
);

select lives_ok(
  $$select set_product_price(
    (select id from products where sku='PROD-VITC'),
    (select id from price_conditions where code='LIST'),
    45300
  )$$,
  'Admin autorizado sí puede modificar precios'
);

-- Usuario desactivado no puede operar (todas las policies dependen de is_active_profile())
select set_config('request.jwt.claim.sub', 'c0000000-0000-0000-0000-000000000003', false);
select is(
  (select count(*)::int from public.products),
  0,
  'Usuario desactivado no puede leer ni siquiera el catálogo de productos'
);

select * from finish();
rollback;
