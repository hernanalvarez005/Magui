-- pgTAP: Bugfix Precios — "No hay cambios para guardar". La causa raíz era
-- 100% frontend (ver lib/pricing/price-matrix-changes.ts y
-- tests/price-matrix-changes.test.ts), pero "borrar un precio" no tenía
-- NINGÚN camino de persistencia (set_product_price exige amount > 0). Este
-- archivo prueba la función nueva que lo resuelve: clear_product_price()
-- desactiva la vigencia (nunca guarda $0, nunca borra filas, no toca
-- ventas históricas) — misma estrategia que ya usa set_product_price().
-- Correr con: supabase test db  (requiere Supabase CLI + Docker)
begin;
select plan(9);

insert into auth.users (id, email) values
  ('f8000000-0000-0000-0000-000000000001', 'admin.clearprice@test.maguirejuve.com'),
  ('f8000000-0000-0000-0000-000000000002', 'seller.clearprice@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'f8000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'f8000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'f8000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'f8000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'SED-25';

set role authenticated;
select set_config('request.jwt.claim.sub', 'f8000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Precondición: PROD-OJOS ya tiene precio TRANSFER (del seed). Confirmamos
-- que hay exactamente 1 fila activa antes de tocar nada.
-- ---------------------------------------------------------------------------
select is(
  (
    select count(*)::int from product_prices
    where product_id = (select id from products where sku = 'PROD-OJOS')
      and price_condition_id = (select id from price_conditions where code = 'TRANSFER')
      and active = true
  ),
  1,
  'Precondición: PROD-OJOS tiene 1 precio Transferencia activo antes de borrarlo'
);

select lives_ok(
  $$select clear_product_price(
    (select id from products where sku = 'PROD-OJOS'),
    (select id from price_conditions where code = 'TRANSFER')
  )$$,
  'Caso 1: el admin puede borrar (desactivar) un precio existente sin error'
);

-- ---------------------------------------------------------------------------
-- Caso 2: tras borrarlo, ya no queda ninguna fila ACTIVA para esa
-- condición — vuelve a mostrarse "Sin configurar", nunca $0.
-- ---------------------------------------------------------------------------
select is(
  (
    select count(*)::int from product_prices
    where product_id = (select id from products where sku = 'PROD-OJOS')
      and price_condition_id = (select id from price_conditions where code = 'TRANSFER')
      and active = true
  ),
  0,
  'Caso 2: después de borrarlo, 0 filas activas — nunca se guarda $0'
);

-- ---------------------------------------------------------------------------
-- Caso 3: no es un DELETE — la fila sigue existiendo (soft-close), solo
-- queda inactiva con su vigencia cerrada. Mismo criterio histórico que
-- set_product_price().
-- ---------------------------------------------------------------------------
select is(
  (
    select count(*)::int from product_prices
    where product_id = (select id from products where sku = 'PROD-OJOS')
      and price_condition_id = (select id from price_conditions where code = 'TRANSFER')
      and active = false
      and valid_until is not null
  ),
  1,
  'Caso 3: la fila anterior sigue existiendo (inactiva, con vigencia cerrada) — no se borra'
);

-- ---------------------------------------------------------------------------
-- Caso 4: quote_sale para esa condición ya no encuentra precio -> ok:false
-- (nunca $0), mismo comportamiento que cualquier condición sin precio
-- configurado (mismo criterio que "Caso 7" de pricing_and_sales.test.sql).
-- ---------------------------------------------------------------------------
select is(
  (quote_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-OJOS'), 'quantity', 1)),
    (select id from payment_methods where code = 'TRANSFER')
  ) ->> 'ok')::boolean,
  false,
  'Caso 4: sin precio activo para Transferencia, quote_sale devuelve ok:false en vez de cobrar $0'
);

-- ---------------------------------------------------------------------------
-- Caso 5: se puede volver a cargar un precio normalmente después de
-- haberlo borrado — set_product_price crea una fila activa nueva.
-- ---------------------------------------------------------------------------
select lives_ok(
  $$select set_product_price(
    (select id from products where sku = 'PROD-OJOS'),
    (select id from price_conditions where code = 'TRANSFER'),
    36900
  )$$,
  'Caso 5: después de borrarlo, se puede volver a cargar un precio nuevo sin error'
);

select is(
  (
    select amount from product_prices
    where product_id = (select id from products where sku = 'PROD-OJOS')
      and price_condition_id = (select id from price_conditions where code = 'TRANSFER')
      and active = true
  ),
  36900.00,
  'Caso 5b: el precio recargado queda activo con el monto nuevo'
);

-- ---------------------------------------------------------------------------
-- Precondición + Caso 6: una vendedora no puede borrar un precio (mismo
-- permiso admin-only que set_product_price).
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'f8000000-0000-0000-0000-000000000002', false);

select throws_like(
  $$select clear_product_price(
    (select id from products where sku = 'PROD-ANTI'),
    (select id from price_conditions where rule_type = 'BASE')
  )$$,
  '%no tiene permiso%',
  'Caso 6: una vendedora no puede borrar un precio — exclusivo de admin'
);

-- ---------------------------------------------------------------------------
-- Caso 7: borrar/recargar un precio no modifica ventas ya confirmadas —
-- sale_items guarda su propio snapshot, no una referencia viva.
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'f8000000-0000-0000-0000-000000000001', false);

select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'PROD-ANTI'), 5, 'RECEPTION');

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-ANTI'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH')
) ->> 'sale_id')::uuid as new_sale_id \gset

select clear_product_price(
  (select id from products where sku = 'PROD-ANTI'),
  (select id from price_conditions where code = 'CASH')
);

select ok(
  (select sale_unit_price from sale_items where sale_id = :'new_sale_id') is not null
    and (select sale_unit_price from sale_items where sale_id = :'new_sale_id') > 0,
  'Caso 7: borrar el precio vigente HOY no afecta el snapshot de una venta ya confirmada'
);

select * from finish();
rollback;
