-- pgTAP: Administración de productos — activar, desactivar y eliminar.
-- Correr con: supabase test db  (requiere Supabase CLI + Docker)
begin;
select plan(17);

insert into auth.users (id, email) values
  ('fa000000-0000-0000-0000-000000000001', 'admin.lifecycle@test.maguirejuve.com'),
  ('fa000000-0000-0000-0000-000000000002', 'seller.lifecycle@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'fa000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'fa000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'fa000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'fa000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'DEP';

set role authenticated;
select set_config('request.jwt.claim.sub', 'fa000000-0000-0000-0000-000000000001', false);

select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'PROD-OJOS'), 1, 'RECEPTION');
select set_product_price(
  (select id from products where sku = 'PROD-OJOS'),
  (select id from price_conditions where rule_type = 'BASE'),
  41000
);

-- ---------------------------------------------------------------------------
-- Desactivación
-- ---------------------------------------------------------------------------

-- Caso 1: admin desactiva un producto.
select deactivate_product((select id from products where sku = 'PROD-OJOS'));

select is(
  (select active from products where sku = 'PROD-OJOS'),
  false,
  'Caso 1: deactivate_product deja el producto en active = false'
);

-- Caso 2/9 (comercial): el filtro que ya usan Nueva Venta/Precios/selector
-- de promociones (active = true) automáticamente lo deja afuera — mismo
-- criterio en las 3 pantallas, no se duplica una regla nueva.
select ok(
  not exists (select 1 from products where sku = 'PROD-OJOS' and active = true),
  'Caso 2/3/4: el producto desactivado ya no pasa el filtro active=true que usan Nueva Venta, Precios y el selector de promociones'
);

-- Caso 5/6: con stock bajo/sin stock, un producto inactivo no cuenta como
-- alerta operativa (product_active en product_stock_status).
select is(
  (
    select count(*)::int from product_stock_status
    where product_id = (select id from products where sku = 'PROD-OJOS')
      and status in ('bajo', 'sin_stock')
      and product_active = true
  ),
  0,
  'Caso 5/6: producto inactivo con stock bajo no cuenta en el filtro de alertas (product_active)'
);

select is(
  (select bool_and(product_active = false) from product_stock_status where product_id = (select id from products where sku = 'PROD-OJOS')),
  true,
  'Caso 5b: product_stock_status refleja product_active = false para el producto recién desactivado'
);

-- Caso 7: historial (precio cargado antes de desactivar) sigue intacto.
select is(
  (
    select amount from product_prices
    where product_id = (select id from products where sku = 'PROD-OJOS')
      and price_condition_id = (select id from price_conditions where rule_type = 'BASE')
      and active = true
  ),
  41000.00,
  'Caso 7: desactivar no altera el precio histórico vigente'
);

-- ---------------------------------------------------------------------------
-- Reactivación
-- ---------------------------------------------------------------------------

-- Caso 8: admin reactiva.
select reactivate_product((select id from products where sku = 'PROD-OJOS'));

select is(
  (select active from products where sku = 'PROD-OJOS'),
  true,
  'Caso 8: reactivate_product deja el producto de nuevo en active = true'
);

-- Caso 9: vuelve a pasar el filtro comercial (Nueva Venta/Precios/promos).
select ok(
  exists (select 1 from products where sku = 'PROD-OJOS' and active = true),
  'Caso 9: tras reactivar, vuelve a pasar el filtro active=true del catálogo comercial'
);

-- Auditoría: quedaron las 2 acciones explícitas (además de lo que ya
-- audite trg_audit_products genéricamente sobre cada UPDATE).
select is(
  (
    select count(*)::int from audit_logs
    where entity_type = 'products'
      and entity_id = (select id from products where sku = 'PROD-OJOS')
      and action in ('PRODUCT_DEACTIVATED', 'PRODUCT_REACTIVATED')
  ),
  2,
  'Auditoría: quedan registradas PRODUCT_DEACTIVATED y PRODUCT_REACTIVATED'
);

-- ---------------------------------------------------------------------------
-- Eliminación
-- ---------------------------------------------------------------------------

-- Caso 10: producto sin ningún historial puede eliminarse.
insert into public.products (sku, name, product_type, category, active)
values ('TEST-LC-NOHIST', 'Sérum Test Sin Historial', 'product', 'Test', true);

select lives_ok(
  $$select delete_product((select id from products where sku = 'TEST-LC-NOHIST'))$$,
  'Caso 10: un producto sin ventas/stock/kits/promociones puede eliminarse definitivamente'
);

select ok(
  not exists (select 1 from products where sku = 'TEST-LC-NOHIST'),
  'Caso 10b: la fila realmente desapareció (hard delete, no soft)'
);

-- Caso 11: producto con una venta NO puede eliminarse.
insert into public.products (sku, name, product_type, category, track_stock, active)
values ('TEST-LC-SALE', 'Sérum Test Con Venta', 'product', 'Test', true, true);
select set_product_price(
  (select id from products where sku = 'TEST-LC-SALE'),
  (select id from price_conditions where rule_type = 'BASE'),
  10000
);
select set_product_price(
  (select id from products where sku = 'TEST-LC-SALE'),
  (select id from price_conditions where code = 'CASH'),
  9000
);
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-LC-SALE'), 5, 'RECEPTION');
select create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-LC-SALE'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH')
);

select throws_like(
  $$select delete_product((select id from products where sku = 'TEST-LC-SALE'))$$,
  '%tiene historial%',
  'Caso 11: un producto con una venta confirmada no puede eliminarse definitivamente'
);

select ok(
  exists (select 1 from products where sku = 'TEST-LC-SALE'),
  'Caso 11b: el producto con venta sigue existiendo — el intento de borrado no dejó nada a mitad de camino'
);

-- Caso 12: producto con un movimiento de stock (sin venta) tampoco puede
-- eliminarse — inventory_balances/stock_movements ya son NO ACTION/RESTRICT.
insert into public.products (sku, name, product_type, category, track_stock, active)
values ('TEST-LC-STOCKMOV', 'Sérum Test Con Movimiento', 'product', 'Test', true, true);
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-LC-STOCKMOV'), 3, 'RECEPTION');

select throws_like(
  $$select delete_product((select id from products where sku = 'TEST-LC-STOCKMOV'))$$,
  '%tiene historial%',
  'Caso 12: un producto con un movimiento de stock (sin venta) tampoco puede eliminarse'
);

-- Caso 13: producto usado como componente de un kit no puede eliminarse.
insert into public.products (sku, name, product_type, category, active)
values ('TEST-LC-COMPONENT', 'Sérum Test Componente De Kit', 'product', 'Test', true);
insert into public.kit_components (kit_product_id, component_product_id, quantity)
values ((select id from products where sku = 'KIT-VN'), (select id from products where sku = 'TEST-LC-COMPONENT'), 1);

select throws_like(
  $$select delete_product((select id from products where sku = 'TEST-LC-COMPONENT'))$$,
  '%tiene historial%',
  'Caso 13: un producto usado como componente de un kit no puede eliminarse'
);

-- Caso 14: producto asociado a una promoción no puede eliminarse.
insert into public.products (sku, name, product_type, category, active)
values ('TEST-LC-PROMO', 'Sérum Test En Promoción', 'product', 'Test', true);
insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active)
values ('TEST-LC-PROMO-CODE', 'Promo test lifecycle', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.2, 60, false, true);
select set_promotion_products(
  (select id from promotions where code = 'TEST-LC-PROMO-CODE'),
  array[(select id from products where sku = 'TEST-LC-PROMO')]
);

select throws_like(
  $$select delete_product((select id from products where sku = 'TEST-LC-PROMO'))$$,
  '%tiene historial%',
  'Caso 14: un producto asociado a una promoción existente no puede eliminarse'
);

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'fa000000-0000-0000-0000-000000000002', false);

-- Caso 15a: una vendedora no puede desactivar productos.
select throws_like(
  $$select deactivate_product((select id from products where sku = 'PROD-OJOS'))$$,
  '%administrador%',
  'Caso 15a: una vendedora no puede desactivar un producto'
);

-- Caso 15b: una vendedora no puede eliminar productos.
select throws_like(
  $$select delete_product((select id from products where sku = 'TEST-LC-STOCKMOV'))$$,
  '%administrador%',
  'Caso 15b: una vendedora no puede eliminar un producto'
);

select * from finish();
rollback;
