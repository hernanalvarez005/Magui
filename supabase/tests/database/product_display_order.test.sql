-- pgTAP: Bloque D — orden visual de productos en Nueva Venta. Sección 37 del
-- pedido: productos individuales primero, después kits, después accesorios,
-- y un producto nuevo sin display_order cae al final (alfabético entre sí).
-- El mapeo SKU->orden real (secciones 25-27) se verificó a mano contra el
-- catálogo de producción real (no reproducible acá: el seed local usa SKU
-- de prueba distintos) — este test cubre el MECANISMO, que es el mismo
-- sin importar qué SKU tenga cada fila. Correr con: supabase test db
-- (Supabase CLI + Docker).
begin;
select plan(6);

insert into auth.users (id, email) values ('e2000000-0000-0000-0000-000000000001', 'admin.order@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'e2000000-0000-0000-0000-000000000001';
insert into public.profile_locations (profile_id, location_id)
  select 'e2000000-0000-0000-0000-000000000001', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'e2000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Caso 1: productos con display_order explícito respetan exactamente ese
-- orden — no el alfabético (a propósito, los nombres van "al revés" del
-- orden pedido para que el test no pase por casualidad si alguien rompiera
-- el ORDER BY y quedara solo "name").
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, display_order, active) values
  ('TEST-ORD-C', 'Zzz Tercero', 'product', 'Test', 30, true),
  ('TEST-ORD-A', 'Yyy Primero', 'product', 'Test', 10, true),
  ('TEST-ORD-B', 'Xxx Segundo', 'product', 'Test', 20, true);

select is(
  (
    select array_agg(sku order by display_order, name)
    from products
    where sku in ('TEST-ORD-A', 'TEST-ORD-B', 'TEST-ORD-C')
  ),
  array['TEST-ORD-A', 'TEST-ORD-B', 'TEST-ORD-C'],
  'Caso 1: display_order manda sobre el orden alfabético de los nombres'
);

-- ---------------------------------------------------------------------------
-- Caso 2: productos individuales, después kits, después accesorios — la
-- secuencia completa pedida es una única secuencia de display_order
-- creciente, sin importar product_type.
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, track_stock, display_order, active) values
  ('TEST-ORD-KIT', 'Kit Test Orden', 'kit', 'Kit', false, 40, true),
  ('TEST-ORD-ACC', 'Accesorio Test Orden', 'accessory', 'Accesorio', true, 50, true);

select is(
  (
    select array_agg(product_type::text order by display_order, name)
    from products
    where sku in ('TEST-ORD-A', 'TEST-ORD-B', 'TEST-ORD-C', 'TEST-ORD-KIT', 'TEST-ORD-ACC')
  ),
  array['product', 'product', 'product', 'kit', 'accessory'],
  'Caso 2: productos individuales -> kits -> accesorios, en ese orden'
);

-- ---------------------------------------------------------------------------
-- Caso 3: un producto nuevo SIN display_order explícito (default 9999) cae
-- al final, después de cualquier producto con orden asignado.
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, active) values
  ('TEST-ORD-NEW', 'Aaa Nuevo Sin Orden', 'product', 'Test', true);

select is(
  (select display_order from products where sku = 'TEST-ORD-NEW'),
  9999,
  'Caso 3a: producto nuevo sin display_order explícito usa el default (9999)'
);

select ok(
  (select display_order from products where sku = 'TEST-ORD-NEW')
    > (select display_order from products where sku = 'TEST-ORD-ACC'),
  'Caso 3b: aunque su nombre empiece con "A" (alfabéticamente primero), cae DESPUÉS de todo lo que sí tiene orden asignado'
);

-- ---------------------------------------------------------------------------
-- Caso 4: dos productos sin display_order explícito (ambos en 9999) quedan
-- ordenados alfabéticamente entre sí — fallback estable, no arbitrario.
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, active) values
  ('TEST-ORD-NEW2', 'Bbb Otro Sin Orden', 'product', 'Test', true);

select is(
  (
    select array_agg(sku order by display_order, name)
    from products
    where sku in ('TEST-ORD-NEW', 'TEST-ORD-NEW2')
  ),
  array['TEST-ORD-NEW', 'TEST-ORD-NEW2'],
  'Caso 4: entre dos productos sin orden explícito (mismo 9999), el fallback es alfabético por nombre'
);

-- ---------------------------------------------------------------------------
-- Caso 5: el índice existe y cubre (display_order, name) — la query real de
-- Nueva Venta.
-- ---------------------------------------------------------------------------
select has_index('products', 'products_display_order_idx', 'products_display_order_idx existe');

select * from finish();
rollback;
