-- pgTAP: Ajuste — columna "Detalle" en Facturación pendiente. sale_items ya
-- es la fuente de verdad comercial (un kit vendido queda 1 fila con su
-- propio product_id, sin importar qué componentes haya descontado el
-- stock internamente) — este archivo prueba exactamente eso, que es lo que
-- alimenta la columna nueva en app/(app)/admin/facturacion/page.tsx.
-- Correr con: supabase test db  (requiere Supabase CLI + Docker)
begin;
select plan(9);

insert into auth.users (id, email) values
  ('f9000000-0000-0000-0000-000000000001', 'admin.detalle@test.maguirejuve.com'),
  ('f9000000-0000-0000-0000-000000000002', 'seller.detalle@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'f9000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'f9000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'f9000000-0000-0000-0000-000000000001', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'f9000000-0000-0000-0000-000000000001', false);

select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'PROD-VITC'), 50, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'PROD-NIAC'), 50, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'PROD-ESP'), 50, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'PROD-ANTI'), 50, 'RECEPTION');
insert into public.customers (full_name, dni) values ('Cliente Detalle Test', '30222333');

-- ---------------------------------------------------------------------------
-- Caso 1: venta con 1 solo producto -> 1 fila en sale_items, cantidad 1.
-- ---------------------------------------------------------------------------
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-ESP'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH')
) ->> 'sale_id')::uuid as sale_single \gset

select is(
  (select count(*)::int from sale_items where sale_id = :'sale_single'),
  1,
  'Caso 1: una venta con 1 producto genera exactamente 1 fila en sale_items'
);

select is(
  (
    select p.name from sale_items si
    join products p on p.id = si.product_id
    where si.sale_id = :'sale_single'
  ),
  (select name from products where sku = 'PROD-ESP'),
  'Caso 1b: el nombre resuelto es el del producto vendido'
);

-- ---------------------------------------------------------------------------
-- Caso 2/3: venta con varios productos, uno con cantidad 2 -> todas las
-- filas aparecen, cada una con su cantidad correcta (2, no repetida 2 veces).
-- ---------------------------------------------------------------------------
select (create_sale(
  jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1),
    jsonb_build_object('product_id', (select id from products where sku = 'PROD-NIAC'), 'quantity', 2),
    jsonb_build_object('product_id', (select id from products where sku = 'PROD-ANTI'), 'quantity', 1)
  ),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH')
) ->> 'sale_id')::uuid as sale_multi \gset

select is(
  (select count(*)::int from sale_items where sale_id = :'sale_multi'),
  3,
  'Caso 2: venta con 3 productos distintos genera 3 filas en sale_items (una por producto, no por unidad)'
);

select is(
  (select quantity from sale_items where sale_id = :'sale_multi' and product_id = (select id from products where sku = 'PROD-NIAC')),
  2.00,
  'Caso 3: la cantidad 2 queda en la fila como 2, lista para mostrarse "× 2" (no dos filas separadas)'
);

-- ---------------------------------------------------------------------------
-- Caso 4: venta de un kit -> sale_items tiene el KIT como producto (product_id
-- del kit), nunca sus componentes — aunque el stock haya descontado
-- Vitamina C y Niacinamida por separado.
-- ---------------------------------------------------------------------------
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'KIT-VN'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH')
) ->> 'sale_id')::uuid as sale_kit \gset

select is(
  (select count(*)::int from sale_items where sale_id = :'sale_kit'),
  1,
  'Caso 4a: vender un kit genera 1 sola fila en sale_items (el kit, no sus componentes)'
);

select is(
  (
    select p.product_type::text from sale_items si
    join products p on p.id = si.product_id
    where si.sale_id = :'sale_kit'
  ),
  'kit',
  'Caso 4b: el product_id de esa fila es el del kit — el detalle debe mostrar "Kit Vitamina C + Niacinamida", nunca "Vitamina C" + "Niacinamida" por separado'
);

-- ---------------------------------------------------------------------------
-- Caso 5: producto + kit en la misma venta -> ambos aparecen, cada uno
-- como su propio ítem (2 filas), sin mezclar componentes.
-- ---------------------------------------------------------------------------
select (create_sale(
  jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'PROD-ESP'), 'quantity', 1),
    jsonb_build_object('product_id', (select id from products where sku = 'KIT-VN'), 'quantity', 1)
  ),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH')
) ->> 'sale_id')::uuid as sale_mix \gset

select is(
  (
    select array_agg(p.sku order by p.sku)
    from sale_items si
    join products p on p.id = si.product_id
    where si.sale_id = :'sale_mix'
  ),
  array['KIT-VN', 'PROD-ESP'],
  'Caso 5: producto + kit en la misma venta -> exactamente esos 2 ítems, cada uno con su propio product_id'
);

-- ---------------------------------------------------------------------------
-- Caso 6: el detalle también está disponible para una venta ya marcada
-- como facturada (Facturadas) — mark_sale_invoiced no toca sale_items.
-- ---------------------------------------------------------------------------
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 3)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'TRANSFER'),
  (select id from customers where dni = '30222333'),
  null, null, null, null, now(), false, null, null, false,
  (select id from payment_accounts where code = 'BANCO_GALICIA')
) ->> 'sale_id')::uuid as sale_invoiced \gset

select mark_sale_invoiced(:'sale_invoiced');

select is(
  (
    select quantity from sale_items
    where sale_id = :'sale_invoiced' and product_id = (select id from products where sku = 'PROD-VITC')
  ),
  3.00,
  'Caso 6: después de marcar la venta como facturada, sale_items sigue intacto (mismo detalle en la pestaña Facturadas)'
);

-- ---------------------------------------------------------------------------
-- Precondición: una venta anulada nunca debería llegar a construirse el
-- detalle en esta pantalla (sección 11 del pedido) — no cambia la regla ya
-- existente de que status <> confirmed queda afuera de las 3 pestañas.
-- ---------------------------------------------------------------------------
select cancel_sale(:'sale_single', 'Test detalle — anulación no debe aparecer en facturación');

select is(
  (select status::text from sales where id = :'sale_single'),
  'cancelled',
  'Precondición: la venta anulada queda con status cancelled — la query de facturación (status=confirmed) ya la excluye, sin cambios en esa regla'
);

select * from finish();
rollback;
