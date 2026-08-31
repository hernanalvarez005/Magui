-- pgTAP: Bloque A del bloque "Stock, promociones y anulación de ventas" —
-- estado de stock por sede (nunca global) + stock total físico (nunca kits).
-- Correr con: supabase test db (Supabase CLI + Docker).
begin;
select plan(9);

insert into auth.users (id, email) values
  ('f0000000-0000-0000-0000-000000000001', 'admin.stock@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'f0000000-0000-0000-0000-000000000001';
insert into public.profile_locations (profile_id, location_id)
  select 'f0000000-0000-0000-0000-000000000001', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'f0000000-0000-0000-0000-000000000001', false);

-- Un producto propio (no kit) con default_min_stock = 5, para no depender de
-- los mínimos del seed.
insert into public.products (sku, name, product_type, track_stock, default_min_stock, commissionable, promo_eligible)
values ('TEST-STK-A', 'Producto Test Stock A', 'product', true, 5, true, true);

-- ---------------------------------------------------------------------------
-- Casos 1-4: la regla es sin_stock <= 0, bajo (0, min], ok (> min) — evaluada
-- por sede, nunca contra un total global.
-- ---------------------------------------------------------------------------
select set_stock(
  (select id from stock_locations where code = 'DEP'),
  (select id from products where sku = 'TEST-STK-A'),
  10, 'RECEPTION'
);
select is(
  (select status from product_stock_status
    where product_id = (select id from products where sku = 'TEST-STK-A')
      and location_id = (select id from stock_locations where code = 'DEP'))::text,
  'ok',
  'Caso 1: stock 10 / mínimo 5 -> ok'
);

select set_stock(
  (select id from stock_locations where code = 'DEP'),
  (select id from products where sku = 'TEST-STK-A'),
  5, 'RECEPTION'
);
select is(
  (select status from product_stock_status
    where product_id = (select id from products where sku = 'TEST-STK-A')
      and location_id = (select id from stock_locations where code = 'DEP'))::text,
  'bajo',
  'Caso 2: stock 5 / mínimo 5 -> bajo (stock > 0 AND stock <= min_stock)'
);

select set_stock(
  (select id from stock_locations where code = 'DEP'),
  (select id from products where sku = 'TEST-STK-A'),
  1, 'RECEPTION'
);
select is(
  (select status from product_stock_status
    where product_id = (select id from products where sku = 'TEST-STK-A')
      and location_id = (select id from stock_locations where code = 'DEP'))::text,
  'bajo',
  'Caso 3: stock 1 / mínimo 5 -> bajo'
);

select set_stock(
  (select id from stock_locations where code = 'DEP'),
  (select id from products where sku = 'TEST-STK-A'),
  0, 'RECEPTION'
);
select is(
  (select status from product_stock_status
    where product_id = (select id from products where sku = 'TEST-STK-A')
      and location_id = (select id from stock_locations where code = 'DEP'))::text,
  'sin_stock',
  'Caso 4: stock 0 -> sin_stock'
);

-- ---------------------------------------------------------------------------
-- Caso 5: una sede con stock alto no queda "contaminada" por otra sede en
-- rojo — el estado se evalúa por sede, nunca contra el stock global.
-- ---------------------------------------------------------------------------
select set_stock(
  (select id from stock_locations where code = 'SED-25'),
  (select id from products where sku = 'TEST-STK-A'),
  18, 'RECEPTION'
);
select is(
  (select status from product_stock_status
    where product_id = (select id from products where sku = 'TEST-STK-A')
      and location_id = (select id from stock_locations where code = 'SED-25'))::text,
  'ok',
  'Caso 5a: Sede 25 con stock 18 / mínimo 5 -> ok, sin importar que Depósito esté en sin_stock'
);

select is(
  (select sum(quantity) from product_stock_status
    where product_id = (select id from products where sku = 'TEST-STK-A')),
  18.00,
  'Caso 5b: el stock total general suma las unidades físicas de todas las sedes (0 + 18)'
);

-- ---------------------------------------------------------------------------
-- Caso 6: la disponibilidad de kit (kit_availability) es una vista aparte y
-- NUNCA se suma al stock físico total — armar kits no crea unidades nuevas.
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, track_stock, commissionable, promo_eligible)
values ('TEST-STK-KIT', 'Kit Test Stock', 'kit', false, true, true);
insert into public.kit_components (kit_product_id, component_product_id, quantity)
values ((select id from products where sku = 'TEST-STK-KIT'), (select id from products where sku = 'TEST-STK-A'), 2);

select is(
  (select buildable_qty from kit_availability
    where kit_product_id = (select id from products where sku = 'TEST-STK-KIT')
      and location_id = (select id from stock_locations where code = 'SED-25')),
  9::numeric,
  'Caso 6a: con 18 unidades del componente se pueden armar 9 kits (floor(18/2))'
);

select is(
  (select sum(quantity) from product_stock_status
    where product_id = (select id from products where sku = 'TEST-STK-A')),
  18.00,
  'Caso 6b: el stock físico total NO cambia por la disponibilidad virtual de kits (sigue en 18)'
);

select ok(
  not exists (
    select 1 from product_stock_status
    where product_id = (select id from products where sku = 'TEST-STK-KIT')
  ),
  'Caso 6c: el kit mismo (track_stock = false) no aparece en product_stock_status — no tiene stock propio que sumar dos veces'
);

select * from finish();
rollback;
