-- pgTAP: BUGFIX PRIORITARIO — Cambios/Devoluciones: producto devuelto no
-- reintegra stock en ventas anteriores a source_sale_item_id (caso real
-- Roncari, MJ-37-20260902-0003 -> MJ-37-20260903-0002). Simula una "venta
-- legado" anulando manualmente source_sale_item_id de su movimiento SALE
-- (como quedaría cualquier venta real confirmada antes de que
-- 20260201000033_sale_exchanges_schema.sql llegara a producción) y verifica
-- que create_sale_exchange/create_sale_return ahora sí reintegran stock por
-- el fallback de ledger completo — sin tocar kit_components vigente.
-- Casos pedidos (secciones 8 y 9 del pedido), en orden:
--   1) Caso real: Niacinamida -> Sérum Exfoliante (venta legado, 1 unidad)
--   2) Producto simple -> producto simple, venta MODERNA (no debe activar
--      el fallback — confirma que el camino exacto sigue igual)
--   3) Cantidad 2, se devuelve 1 (venta legado)
--   4) Kit -> producto (venta legado) — reintegra proporcionalmente los
--      componentes físicos reales, nunca kit_components vigente
--   5) Producto -> kit (venta legado) — el producto vuelve, el kit nuevo
--      descuenta sus componentes (camino ya existente, sin tocar)
--   6) Cambio encadenado con raíz legado (A -> B -> C)
--   7) Fallo en el reintegro -> ROLLBACK completo (nada queda a medias)
--   8) Fallo en el descuento del producto nuevo -> ROLLBACK completo
-- Correr con: supabase test db (requiere Supabase CLI + Docker) o
-- scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(23);

insert into auth.users (id, email) values
  ('fb000000-0000-0000-0000-000000000001', 'admin.legacyfix@test.maguirejuve.com'),
  ('fb000000-0000-0000-0000-000000000002', 'seller.legacyfix@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'fb000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'fb000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'fb000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'fb000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'SED-37';

set role authenticated;
select set_config('request.jwt.claim.sub', 'fb000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Catálogo de prueba, aislado del resto del seed. Se opera en SED-37 (misma
-- sede que el caso real) — la devolución física siempre tiene que volver
-- ahí, nunca a Depósito (sección 5 del pedido, verificado en cada caso).
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('BUG-NIA', 'Serum Niacinamida Bugfix', 'product', 'Test', true, true, false, true),
  ('BUG-EXF', 'Serum Exfoliante Bugfix', 'product', 'Test', true, true, false, true),
  ('BUG-CREMA', 'Crema Componente Bugfix', 'product', 'Test', true, true, false, true),
  ('BUG-SERUM', 'Serum Componente Bugfix', 'product', 'Test', true, true, false, true),
  ('BUG-KIT', 'Kit Bugfix', 'kit', 'Test', false, true, false, true),
  ('BUG-NEW2', 'Producto Nuevo Encadenado Bugfix', 'product', 'Test', true, true, false, true);

insert into public.kit_components (kit_product_id, component_product_id, quantity) values
  ((select id from products where sku = 'BUG-KIT'), (select id from products where sku = 'BUG-CREMA'), 2),
  ((select id from products where sku = 'BUG-KIT'), (select id from products where sku = 'BUG-SERUM'), 1);

select set_product_price((select id from products where sku = 'BUG-NIA'), (select id from price_conditions where rule_type = 'BASE'), 10000);
select set_product_price((select id from products where sku = 'BUG-NIA'), (select id from price_conditions where code = 'CASH'), 9000);
select set_product_price((select id from products where sku = 'BUG-EXF'), (select id from price_conditions where rule_type = 'BASE'), 12000);
select set_product_price((select id from products where sku = 'BUG-EXF'), (select id from price_conditions where code = 'CASH'), 10800);
select set_product_price((select id from products where sku = 'BUG-CREMA'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'BUG-CREMA'), (select id from price_conditions where code = 'CASH'), 4500);
select set_product_price((select id from products where sku = 'BUG-SERUM'), (select id from price_conditions where rule_type = 'BASE'), 3000);
select set_product_price((select id from products where sku = 'BUG-SERUM'), (select id from price_conditions where code = 'CASH'), 2700);
select set_product_price((select id from products where sku = 'BUG-KIT'), (select id from price_conditions where rule_type = 'BASE'), 20000);
select set_product_price((select id from products where sku = 'BUG-KIT'), (select id from price_conditions where code = 'CASH'), 18000);
select set_product_price((select id from products where sku = 'BUG-NEW2'), (select id from price_conditions where rule_type = 'BASE'), 8000);
select set_product_price((select id from products where sku = 'BUG-NEW2'), (select id from price_conditions where code = 'CASH'), 7200);

insert into public.customers (full_name, dni) values ('Roncari Regis Valentina (test)', '30999777');

select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'BUG-NIA'), 50, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'BUG-EXF'), 50, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'BUG-CREMA'), 50, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'BUG-SERUM'), 50, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'BUG-NEW2'), 50, 'RECEPTION');

set role authenticated;
select set_config('request.jwt.claim.sub', 'fb000000-0000-0000-0000-000000000002', false);

-- ===========================================================================
-- Caso 1 (sección 8): reproducción exacta — Niacinamida x1 (venta legado,
-- SIN source_sale_item_id) -> Sérum Exfoliante x1.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'BUG-NIA'), 'quantity', 1)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999777')
) ->> 'sale_id')::uuid as sale_1_id \gset
select id as item_1_id from sale_items where sale_id = :'sale_1_id' \gset

reset role;
update stock_movements set source_sale_item_id = null where sale_id = :'sale_1_id';
set role authenticated;
select set_config('request.jwt.claim.sub', 'fb000000-0000-0000-0000-000000000002', false);

select (
  select quantity from inventory_balances
  where location_id = (select id from stock_locations where code = 'SED-37')
    and product_id = (select id from products where sku = 'BUG-NIA')
) as nia_before_1 \gset

select create_sale_exchange(
  :'sale_1_id'::uuid, :'item_1_id'::uuid, 1,
  (select id from products where sku = 'BUG-EXF'), 1
) as result_1 \gset

select is(
  (select quantity from inventory_balances
    where location_id = (select id from stock_locations where code = 'SED-37')
      and product_id = (select id from products where sku = 'BUG-NIA')),
  (:nia_before_1::numeric + 1),
  'Caso 1 (real): Niacinamida devuelta de una venta legado SE reintegra a Sede 37 (+1) — antes del fix se quedaba sin volver'
);
select is(
  (select quantity from inventory_balances
    where location_id = (select id from stock_locations where code = 'SED-37')
      and product_id = (select id from products where sku = 'BUG-EXF')),
  49.00,
  'Caso 1 (real): Sérum Exfoliante nuevo se descuenta correctamente (50 -> 49), como ya funcionaba'
);
select is((select status from sales where id = :'sale_1_id'), 'replaced'::sale_status, 'Caso 1: la venta original queda replaced');
select is(
  (select status from sales where replaces_sale_id = :'sale_1_id'),
  'confirmed'::sale_status,
  'Caso 1: la venta de reemplazo queda confirmed'
);
select is(
  (select location_id from stock_movements
    where movement_type = 'RETURN' and product_id = (select id from products where sku = 'BUG-NIA')
    order by created_at desc limit 1),
  (select id from stock_locations where code = 'SED-37'),
  'Caso 1: el movimiento RETURN quedó registrado en Sede 37 (nunca Depósito/otra sede)'
);

-- ===========================================================================
-- Caso 2 (9.1): producto simple -> producto simple, venta MODERNA (con
-- source_sale_item_id intacto) — confirma que el camino exacto de siempre
-- sigue funcionando igual, el fallback no interfiere.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'BUG-NIA'), 'quantity', 1)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999777')
) ->> 'sale_id')::uuid as sale_2_id \gset
select id as item_2_id from sale_items where sale_id = :'sale_2_id' \gset

select (
  select quantity from inventory_balances
  where location_id = (select id from stock_locations where code = 'SED-37')
    and product_id = (select id from products where sku = 'BUG-NIA')
) as nia_before_2 \gset

select create_sale_exchange(
  :'sale_2_id'::uuid, :'item_2_id'::uuid, 1,
  (select id from products where sku = 'BUG-EXF'), 1
) as result_2 \gset

select is(
  (select quantity from inventory_balances
    where location_id = (select id from stock_locations where code = 'SED-37')
      and product_id = (select id from products where sku = 'BUG-NIA')),
  (:nia_before_2::numeric + 1),
  'Caso 2: producto simple -> simple en una venta MODERNA sigue reintegrando por la vía exacta (sin cambios)'
);

-- ===========================================================================
-- Caso 3 (9.2): cantidad 2, se devuelve 1 (venta legado) — el reintegro
-- tiene que ser proporcional (+1), nunca la cantidad total de la línea.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'BUG-NIA'), 'quantity', 2)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999777')
) ->> 'sale_id')::uuid as sale_3_id \gset
select id as item_3_id from sale_items where sale_id = :'sale_3_id' \gset

reset role;
update stock_movements set source_sale_item_id = null where sale_id = :'sale_3_id';
set role authenticated;
select set_config('request.jwt.claim.sub', 'fb000000-0000-0000-0000-000000000002', false);

select (
  select quantity from inventory_balances
  where location_id = (select id from stock_locations where code = 'SED-37')
    and product_id = (select id from products where sku = 'BUG-NIA')
) as nia_before_3 \gset

select create_sale_exchange(
  :'sale_3_id'::uuid, :'item_3_id'::uuid, 1,
  (select id from products where sku = 'BUG-EXF'), 1
) as result_3 \gset

select is(
  (select quantity from inventory_balances
    where location_id = (select id from stock_locations where code = 'SED-37')
      and product_id = (select id from products where sku = 'BUG-NIA')),
  (:nia_before_3::numeric + 1),
  'Caso 3: de una línea de 2 unidades (venta legado) se devuelve 1 -> reintegra exactamente 1, no 2'
);
select is(
  (select quantity from sale_items where sale_id = (select id from sales where replaces_sale_id = :'sale_3_id') and product_id = (select id from products where sku = 'BUG-NIA')),
  1::numeric,
  'Caso 3: la unidad restante (no devuelta) sigue como línea "remainder" en la venta de reemplazo'
);

-- ===========================================================================
-- Caso 4 (9.3): kit -> producto (venta legado) — reintegra proporcionalmente
-- los componentes físicos reales (CREMA x2, SERUM x1 por kit), nunca vía
-- kit_components vigente.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'BUG-KIT'), 'quantity', 1)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999777')
) ->> 'sale_id')::uuid as sale_4_id \gset
select id as item_4_id from sale_items where sale_id = :'sale_4_id' \gset

reset role;
update stock_movements set source_sale_item_id = null where sale_id = :'sale_4_id';
set role authenticated;
select set_config('request.jwt.claim.sub', 'fb000000-0000-0000-0000-000000000002', false);

select (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='BUG-CREMA')) as crema_before_4 \gset
select (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='BUG-SERUM')) as serum_before_4 \gset

select create_sale_exchange(
  :'sale_4_id'::uuid, :'item_4_id'::uuid, 1,
  (select id from products where sku = 'BUG-EXF'), 1
) as result_4 \gset

select is(
  (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='BUG-CREMA')),
  (:crema_before_4::numeric + 2),
  'Caso 4: kit devuelto (venta legado) reintegra CREMA proporcionalmente (+2, la composición histórica real del kit)'
);
select is(
  (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='BUG-SERUM')),
  (:serum_before_4::numeric + 1),
  'Caso 4: kit devuelto (venta legado) reintegra SERUM proporcionalmente (+1)'
);

-- ===========================================================================
-- Caso 5 (9.4): producto -> kit (venta legado) — el producto devuelto
-- reintegra (fix), el kit nuevo descuenta sus componentes (camino ya
-- existente, sin tocar).
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'BUG-NIA'), 'quantity', 1)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999777')
) ->> 'sale_id')::uuid as sale_5_id \gset
select id as item_5_id from sale_items where sale_id = :'sale_5_id' \gset

reset role;
update stock_movements set source_sale_item_id = null where sale_id = :'sale_5_id';
set role authenticated;
select set_config('request.jwt.claim.sub', 'fb000000-0000-0000-0000-000000000002', false);

select (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='BUG-NIA')) as nia_before_5 \gset
select (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='BUG-CREMA')) as crema_before_5 \gset

select create_sale_exchange(
  :'sale_5_id'::uuid, :'item_5_id'::uuid, 1,
  (select id from products where sku = 'BUG-KIT'), 1
) as result_5 \gset

select is(
  (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='BUG-NIA')),
  (:nia_before_5::numeric + 1),
  'Caso 5: producto -> kit (venta legado) — el producto devuelto reintegra (+1)'
);
select is(
  (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='BUG-CREMA')),
  (:crema_before_5::numeric - 2),
  'Caso 5: el kit nuevo descuenta sus componentes (CREMA -2), camino no tocado por este fix'
);

-- ===========================================================================
-- Caso 6 (9.5): cambio encadenado con raíz legado — A (legado) -> B -> C.
-- La segunda devolución (sobre la línea "remainder" de B) tiene que resolver
-- hasta la MISMA raíz física legado (A) y reintegrar Niacinamida de nuevo.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'BUG-NIA'), 'quantity', 2)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999777')
) ->> 'sale_id')::uuid as sale_a_id \gset
select id as item_a_id from sale_items where sale_id = :'sale_a_id' \gset

reset role;
update stock_movements set source_sale_item_id = null where sale_id = :'sale_a_id';
set role authenticated;
select set_config('request.jwt.claim.sub', 'fb000000-0000-0000-0000-000000000002', false);

select (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='BUG-NIA')) as nia_before_6 \gset

-- Cambio 1: A -> B (devuelve 1 de las 2 unidades, queda 1 de remanente).
select (create_sale_exchange(
  :'sale_a_id'::uuid, :'item_a_id'::uuid, 1,
  (select id from products where sku = 'BUG-EXF'), 1
) ->> 'sale_id')::uuid as sale_b_id \gset

select id as item_b_remainder_id from sale_items
  where sale_id = :'sale_b_id' and product_id = (select id from products where sku = 'BUG-NIA') \gset

-- Cambio 2: B (línea remanente) -> C.
select (create_sale_exchange(
  :'sale_b_id'::uuid, :'item_b_remainder_id'::uuid, 1,
  (select id from products where sku = 'BUG-NEW2'), 1
) ->> 'sale_id')::uuid as sale_c_id \gset

select is(
  (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='BUG-NIA')),
  (:nia_before_6::numeric + 2),
  'Caso 6: cambio encadenado (A legado -> B -> C) — las DOS devoluciones (1+1) resuelven a la misma raíz física y reintegran +2 en total'
);
select is((select status from sales where id = :'sale_a_id'), 'replaced'::sale_status, 'Caso 6: A queda replaced');
select is((select status from sales where id = :'sale_b_id'), 'replaced'::sale_status, 'Caso 6: B (reemplazo intermedio) también queda replaced al volver a cambiarse');
select is((select status from sales where id = :'sale_c_id'), 'confirmed'::sale_status, 'Caso 6: C (reemplazo final) queda confirmed');

-- ===========================================================================
-- Caso 7 (9.6): fallo en el reintegro -> ROLLBACK completo. No se puede
-- corromper location_id/product_id de una fila real de stock_movements (esa
-- tabla tiene sus propias FK) — se simula la falla de infraestructura con un
-- trigger temporal en inventory_balances, exclusivo del producto de este
-- caso, que revierte solo con el "rollback;" final del archivo (DDL
-- transaccional) sin tocar ningún dato real.
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', 'fb000000-0000-0000-0000-000000000001', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('BUG-FAILRET', 'Producto Fallo Reintegro Bugfix', 'product', 'Test', true, true, false, true);
select set_product_price((select id from products where sku = 'BUG-FAILRET'), (select id from price_conditions where rule_type = 'BASE'), 10000);
select set_product_price((select id from products where sku = 'BUG-FAILRET'), (select id from price_conditions where code = 'CASH'), 9000);
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'BUG-FAILRET'), 50, 'RECEPTION');

set role authenticated;
select set_config('request.jwt.claim.sub', 'fb000000-0000-0000-0000-000000000002', false);

-- La venta original se hace ANTES de instalar el trigger — tiene que
-- completarse normal. El trigger recién se instala después, para que
-- interfiera EXCLUSIVAMENTE con el reintegro del cambio, no con la venta.
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'BUG-FAILRET'), 'quantity', 1)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999777')
) ->> 'sale_id')::uuid as sale_7_id \gset
select id as item_7_id from sale_items where sale_id = :'sale_7_id' \gset

reset role;
create or replace function public.__test_fail_on_reintegro() returns trigger language plpgsql as $$
begin
  if new.product_id = (select id from public.products where sku = 'BUG-FAILRET') then
    raise exception 'Fallo simulado de infraestructura (test Caso 7).';
  end if;
  return new;
end;
$$;
create trigger __test_fail_on_reintegro_trg
  before insert or update on public.inventory_balances
  for each row execute function public.__test_fail_on_reintegro();
set role authenticated;
select set_config('request.jwt.claim.sub', 'fb000000-0000-0000-0000-000000000002', false);

select (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='BUG-EXF')) as exf_before_7 \gset
select (select count(*) from sale_items) as sale_items_count_before_7 \gset

select throws_ok(
  format(
    $$select create_sale_exchange('%s'::uuid, '%s'::uuid, 1, (select id from products where sku = 'BUG-EXF'), 1)$$,
    :'sale_7_id', :'item_7_id'
  ),
  'Caso 7: si el reintegro falla (infraestructura), la función entera lanza excepción'
);
select is((select status from sales where id = :'sale_7_id'), 'confirmed'::sale_status, 'Caso 7: tras el fallo, la venta original SIGUE confirmed (no quedó replaced a medias)');
select is(
  (select count(*) from sale_items)::int, :sale_items_count_before_7::int,
  'Caso 7: no quedó ninguna línea nueva huérfana — el rollback fue completo'
);
select is(
  (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='BUG-EXF')),
  :exf_before_7::numeric,
  'Caso 7: el producto nuevo tampoco se descontó — nunca queda "nuevo descontado + viejo no reintegrado"'
);

-- ===========================================================================
-- Caso 8 (9.7): fallo en el descuento del producto nuevo -> ROLLBACK
-- completo. Producto nuevo sin stock y allow_negative_stock=false (default)
-- -> la función tiene que fallar DESPUÉS de haber calculado el reintegro, y
-- ese reintegro NO puede quedar persistido.
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', 'fb000000-0000-0000-0000-000000000001', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('BUG-SINSTOCK', 'Producto Sin Stock Bugfix', 'product', 'Test', true, true, false, true);
select set_product_price((select id from products where sku = 'BUG-SINSTOCK'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'BUG-SINSTOCK'), (select id from price_conditions where code = 'CASH'), 4500);
-- Nunca se le carga stock — queda en 0 (allow_negative_stock=false por
-- default en app_settings, sección 32 del pedido original de Depósito).

set role authenticated;
select set_config('request.jwt.claim.sub', 'fb000000-0000-0000-0000-000000000002', false);

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'BUG-NIA'), 'quantity', 1)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999777')
) ->> 'sale_id')::uuid as sale_8_id \gset
select id as item_8_id from sale_items where sale_id = :'sale_8_id' \gset

select (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='BUG-NIA')) as nia_before_8 \gset

select throws_ok(
  format(
    $$select create_sale_exchange('%s'::uuid, '%s'::uuid, 1, (select id from products where sku = 'BUG-SINSTOCK'), 1)$$,
    :'sale_8_id', :'item_8_id'
  ),
  'Caso 8: si el producto nuevo no tiene stock suficiente, la función entera lanza excepción'
);
select is((select status from sales where id = :'sale_8_id'), 'confirmed'::sale_status, 'Caso 8: tras el fallo, la venta original SIGUE confirmed');
select is(
  (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='BUG-NIA')),
  :nia_before_8::numeric,
  'Caso 8: el reintegro que se había calculado NO quedó persistido — rollback completo, nunca "nuevo descontado + viejo reintegrado a medias"'
);

select * from finish();
rollback;
