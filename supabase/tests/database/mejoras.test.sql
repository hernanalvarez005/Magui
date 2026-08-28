-- pgTAP: regresión de los bugs reales encontrados y corregidos durante las
-- mejoras (bloques 1, 3 y 6). Correr con: supabase test db (Supabase CLI + Docker).
begin;
select plan(12);

insert into auth.users (id, email) values
  ('e0000000-0000-0000-0000-000000000001', 'admin.mejoras@test.maguirejuve.com'),
  ('e0000000-0000-0000-0000-000000000002', 'sellerA.mejoras@test.maguirejuve.com'),
  ('e0000000-0000-0000-0000-000000000003', 'sellerB.mejoras@test.maguirejuve.com');

update public.profiles set role = 'admin', active = true where id = 'e0000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'e0000000-0000-0000-0000-000000000002';
update public.profiles set role = 'seller', active = true where id = 'e0000000-0000-0000-0000-000000000003';
insert into public.profile_locations (profile_id, location_id) select 'e0000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id) select 'e0000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'SED-25';
insert into public.profile_locations (profile_id, location_id) select 'e0000000-0000-0000-0000-000000000003', id from public.stock_locations where code = 'SED-25';

-- ---------------------------------------------------------------------------
-- Bloque 1: set_stock
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000002', false);

select throws_ok(
  $$select set_stock(
    (select id from stock_locations where code = 'SED-25'),
    (select id from products where sku = 'PROD-VITC'),
    50, 'RECEPTION'
  )$$,
  'Una vendedora no puede usar set_stock (solo admin)'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000001', false);

select is(
  (
    (select set_stock(
      (select id from stock_locations where code = 'SED-25'),
      (select id from products where sku = 'PROD-VITC'),
      77, 'RECEPTION', 'pgTAP'
    ) ->> 'stock_after')::numeric
  ),
  77.00,
  'set_stock deja el stock exactamente en el valor pedido'
);

select is(
  (select quantity from inventory_balances
    where location_id = (select id from stock_locations where code = 'SED-25')
      and product_id = (select id from products where sku = 'PROD-VITC')),
  77.00,
  'set_stock persiste el nuevo balance en inventory_balances'
);

select is(
  (select movement_type from stock_movements
    where product_id = (select id from products where sku = 'PROD-VITC')
      and location_id = (select id from stock_locations where code = 'SED-25')
    order by occurred_at desc limit 1)::text,
  'ADJUSTMENT_SET',
  'set_stock queda registrado como un movimiento auditable (ADJUSTMENT_SET), no un UPDATE ciego'
);

-- ---------------------------------------------------------------------------
-- Bloque 3: clientes — normalización de DNI + fix de edición cruzada
-- ---------------------------------------------------------------------------
insert into public.customers (full_name, dni) values ('Cliente Uno', '32.123.456');

select is(
  (select dni from customers where full_name = 'Cliente Uno'),
  '32123456',
  'El DNI se normaliza a solo dígitos antes de guardar'
);

select throws_ok(
  $$insert into public.customers (full_name, dni) values ('Cliente Duplicado', '32123456')$$,
  'Un DNI ya normalizado detecta el duplicado aunque se escriba distinto'
);

-- Bug real: seller B editaba un cliente creado por seller A y la policy
-- vieja lo bloqueaba en silencio (RLS filtraba el UPDATE a 0 filas sin error).
set role authenticated;
select set_config('request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000003', false);

update public.customers set full_name = 'Cliente Uno Editado por Seller B' where full_name = 'Cliente Uno';

select is(
  (select full_name from customers where dni = '32123456'),
  'Cliente Uno Editado por Seller B',
  'Cualquier vendedora activa puede editar un cliente que no creó ella'
);

select throws_ok(
  $$select deactivate_customer((select id from customers where dni = '32123456'))$$,
  'Una vendedora no puede desactivar (soft-delete) un cliente — exclusivo de admin'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000001', false);

select is(
  (select (deactivate_customer((select id from customers where dni = '32123456')) ->> 'active')::boolean),
  false,
  'Un admin sí puede desactivar (soft-delete) un cliente'
);

select is(
  (select count(*)::int from customers where dni = '32123456'),
  1,
  'deactivate_customer nunca borra la fila — sigue existiendo, solo inactiva'
);

-- ---------------------------------------------------------------------------
-- Bloque 6: profiles — fix de autoescalada de privilegios
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000002', false);

select throws_ok(
  $$update public.profiles set role = 'admin' where id = 'e0000000-0000-0000-0000-000000000002'$$,
  'Una vendedora no puede auto-promoverse a admin aunque llame a profiles directamente'
);

select lives_ok(
  $$update public.profiles set full_name = 'Seller A Renombrada' where id = 'e0000000-0000-0000-0000-000000000002'$$,
  'Pero sí puede seguir editando su propio nombre (columna no restringida)'
);

select * from finish();
rollback;
