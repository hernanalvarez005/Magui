-- pgTAP: Bloque "Precios" — consulta de precios y promociones para
-- vendedores (solo lectura, sin tabla/caché propia — lee directamente
-- products/product_prices/promotions/promotion_products, las mismas
-- fuentes que usa Administración). No hay migración nueva: RLS ya
-- permitía SELECT a cualquier perfil activo en las 5 tablas involucradas
-- (products, price_conditions, product_prices, promotions,
-- promotion_products) y ya no había ninguna policy de escritura para
-- seller en ninguna — este archivo prueba que eso sigue siendo así.
-- Correr con: supabase test db  (requiere Supabase CLI + Docker)
begin;
select plan(12);

insert into auth.users (id, email) values
  ('f5000000-0000-0000-0000-000000000001', 'admin.precios@test.maguirejuve.com'),
  ('f5000000-0000-0000-0000-000000000002', 'seller.precios@test.maguirejuve.com');

update public.profiles set role = 'admin', active = true where id = 'f5000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'f5000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'f5000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'f5000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'SED-25';

set role authenticated;
select set_config('request.jwt.claim.sub', 'f5000000-0000-0000-0000-000000000001', false);

-- Fixtures de promociones (admin), con vigencias controladas explícitamente.
insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active, valid_from, valid_until)
values ('TEST-PC-ACTIVE', 'Kit% vigente', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.25, 80, false, true, now() - interval '1 day', null);
select set_promotion_products(
  (select id from promotions where code = 'TEST-PC-ACTIVE'),
  array[(select id from products where sku = 'PROD-ESP')]
);

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active, valid_from, valid_until)
values ('TEST-PC-EXPIRED', 'Kit% vencida', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.30, 81, false, true, now() - interval '30 days', now() - interval '1 day');
select set_promotion_products(
  (select id from promotions where code = 'TEST-PC-EXPIRED'),
  array[(select id from products where sku = 'PROD-ANTI')]
);

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active, valid_from, valid_until)
values ('TEST-PC-INACTIVE', 'Kit% desactivada', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.35, 82, false, false, now() - interval '1 day', null);
select set_promotion_products(
  (select id from promotions where code = 'TEST-PC-INACTIVE'),
  array[(select id from products where sku = 'PROD-SENS')]
);

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active, valid_from, valid_until)
values ('TEST-PC-MULTI', 'Kit% varios productos', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.20, 83, false, true, now() - interval '1 day', null);
select set_promotion_products(
  (select id from promotions where code = 'TEST-PC-MULTI'),
  array[
    (select id from products where sku = 'PROD-VITC'),
    (select id from products where sku = 'PROD-NIAC'),
    (select id from products where sku = 'PROD-OJOS')
  ]
);

insert into public.promotions (code, name, type, price_condition_id, group_size, priority, stackable, active, valid_from, valid_until)
values ('TEST-PC-3X2', '3x2 vigente', 'THREE_FOR_TWO', (select id from price_conditions where rule_type = 'BASE'), 3, 84, false, true, now() - interval '1 day', null);
select set_promotion_products(
  (select id from promotions where code = 'TEST-PC-3X2'),
  array[(select id from products where sku = 'KIT-VN')]
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'f5000000-0000-0000-0000-000000000002', false);

-- ---------------------------------------------------------------------------
-- Precio 1: la vendedora puede consultar precios (products/product_prices).
-- ---------------------------------------------------------------------------
select ok(
  (select count(*) from products where active = true) > 0,
  'Precio 1: la vendedora puede leer el catálogo de productos activos'
);

-- ---------------------------------------------------------------------------
-- Precio 2: Efectivo muestra el precio final almacenado, sin recalcular.
-- ---------------------------------------------------------------------------
select is(
  (
    select pp.amount from product_prices pp
    join price_conditions pc on pc.id = pp.price_condition_id
    where pp.product_id = (select id from products where sku = 'PROD-ESP')
      and pc.code = 'CASH' and pp.active = true
  ),
  30600.00,
  'Precio 2: Efectivo devuelve el amount final guardado en product_prices, tal cual'
);

-- ---------------------------------------------------------------------------
-- Precio 3: Transferencia muestra el precio final almacenado, sin recalcular.
-- ---------------------------------------------------------------------------
select is(
  (
    select pp.amount from product_prices pp
    join price_conditions pc on pc.id = pp.price_condition_id
    where pp.product_id = (select id from products where sku = 'PROD-ESP')
      and pc.code = 'TRANSFER' and pp.active = true
  ),
  32400.00,
  'Precio 3: Transferencia devuelve el amount final guardado en product_prices, tal cual'
);

-- ---------------------------------------------------------------------------
-- Precio 4: condición sin precio configurado -> 0 filas (nunca "$0"); el
-- frontend interpreta 0 filas como "Sin configurar" (sección 7 del pedido).
-- ACC-NEC no tiene precio de Lista cargado (dato real del seed original).
-- ---------------------------------------------------------------------------
select is(
  (
    select count(*)::int from product_prices pp
    join price_conditions pc on pc.id = pp.price_condition_id
    where pp.product_id = (select id from products where sku = 'ACC-NEC')
      and pc.code = 'LIST' and pp.active = true
  ),
  0,
  'Precio 4: sin precio cargado para esa condición -> 0 filas, nunca un $0 engañoso'
);

-- ---------------------------------------------------------------------------
-- Promo 5: una promoción activa y vigente aparece en el filtro de "vigente"
-- (mismo criterio que fn_apply_promotions: active AND valid_from <= now AND
-- (valid_until is null OR valid_until > now)).
-- ---------------------------------------------------------------------------
select ok(
  exists(
    select 1 from promotions
    where code = 'TEST-PC-ACTIVE' and active = true and valid_from <= now()
      and (valid_until is null or valid_until > now())
  ),
  'Promo 5: una promoción activa y vigente pasa el filtro de vigencia'
);

-- ---------------------------------------------------------------------------
-- Promo 6: una promoción vencida (valid_until en el pasado) NO pasa el
-- filtro de vigencia, aunque siga con active = true.
-- ---------------------------------------------------------------------------
select ok(
  not exists(
    select 1 from promotions
    where code = 'TEST-PC-EXPIRED' and active = true and valid_from <= now()
      and (valid_until is null or valid_until > now())
  ),
  'Promo 6: una promoción vencida no pasa el filtro de vigencia'
);

-- ---------------------------------------------------------------------------
-- Promo 7: una promoción desactivada (active = false) NO pasa el filtro,
-- aunque sus fechas sigan siendo válidas.
-- ---------------------------------------------------------------------------
select ok(
  not exists(
    select 1 from promotions
    where code = 'TEST-PC-INACTIVE' and active = true and valid_from <= now()
      and (valid_until is null or valid_until > now())
  ),
  'Promo 7: una promoción desactivada no pasa el filtro de vigencia'
);

-- ---------------------------------------------------------------------------
-- Promo 8: un producto que participa de una promoción vigente se resuelve
-- correctamente vía promotion_products (esto es lo que dispara "EN PROMO").
-- ---------------------------------------------------------------------------
select is(
  (
    select pr.code from promotion_products pp
    join promotions pr on pr.id = pp.promotion_id
    where pp.product_id = (select id from products where sku = 'PROD-ESP')
      and pr.active = true
  ),
  'TEST-PC-ACTIVE',
  'Promo 8: el producto asociado a una promoción vigente resuelve esa promoción (EN PROMO)'
);

-- ---------------------------------------------------------------------------
-- Promo 9: una promoción con varios productos asociados devuelve TODOS los
-- participantes (selección múltiple, ajuste anterior).
-- ---------------------------------------------------------------------------
select is(
  (
    select count(*)::int from promotion_products
    where promotion_id = (select id from promotions where code = 'TEST-PC-MULTI')
  ),
  3,
  'Promo 9: una promoción con varios productos devuelve los 3 participantes'
);

-- ---------------------------------------------------------------------------
-- Promo 10: 3x2 nunca tiene discount_percent (constraint de la propia
-- tabla) — no hay % con qué inventar un precio unitario; el frontend debe
-- mostrarla como "3x2", nunca como "33% OFF" o similar.
-- ---------------------------------------------------------------------------
select is(
  (select discount_percent from promotions where code = 'TEST-PC-3X2'),
  null,
  'Promo 10: una promoción 3x2 no tiene discount_percent — nada de qué inventar un precio único'
);

-- ---------------------------------------------------------------------------
-- Permisos 11: la vendedora NO puede modificar precios directamente
-- (product_prices no tiene ninguna policy de insert/update — la única vía
-- de escritura es la RPC set_product_price(), admin-only).
-- ---------------------------------------------------------------------------
select throws_like(
  $$insert into public.product_prices (product_id, price_condition_id, amount)
    values (
      (select id from products where sku = 'PROD-ESP'),
      (select id from price_conditions where code = 'CASH'),
      1.00
    )$$,
  '%row-level security%',
  'Permisos 11: la vendedora no puede insertar en product_prices directamente (RLS)'
);

-- ---------------------------------------------------------------------------
-- Permisos 12: la vendedora NO puede modificar promociones (crear, editar
-- ni cambiar su composición). El UPDATE de una fila que la policy RLS no
-- deja ver como "propia" no tira excepción — queda en 0 filas afectadas
-- (mismo criterio ya usado para "un viewer no puede editar un cliente",
-- ver viewer_role.test.sql).
-- ---------------------------------------------------------------------------
update public.promotions set discount_percent = 0.99 where code = 'TEST-PC-ACTIVE';

select is(
  (select discount_percent from promotions where code = 'TEST-PC-ACTIVE'),
  0.25,
  'Permisos 12: la vendedora no puede modificar una promoción existente — el UPDATE queda en 0 filas por RLS'
);

select * from finish();
rollback;
