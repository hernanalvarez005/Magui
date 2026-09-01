-- pgTAP: Ajuste — selección múltiple de productos y kits en promociones.
-- Cubre los 10 casos pedidos. No toca DUO_PERCENT (sigue siendo exactamente
-- 2 — mecanismo de pareja, fuera de este ajuste) ni ninguna otra regla de
-- promociones existente (ver 20260201000027_promotion_multiproduct.sql).
-- Correr con: supabase test db  (requiere Supabase CLI + Docker)
begin;
select plan(15);

insert into auth.users (id, email) values
  ('f4000000-0000-0000-0000-000000000001', 'admin.multipromo@test.maguirejuve.com');

update public.profiles set role = 'admin', active = true where id = 'f4000000-0000-0000-0000-000000000001';
insert into public.profile_locations (profile_id, location_id)
  select 'f4000000-0000-0000-0000-000000000001', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Caso 1: crear una promoción kit% con 1 solo producto — sigue funcionando
-- igual que antes del ajuste.
-- ---------------------------------------------------------------------------
insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active)
values ('TEST-MP-1', 'Kit% un producto', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.20, 90, false, false);

select is(
  (select (set_promotion_products(
     (select id from promotions where code = 'TEST-MP-1'),
     array[(select id from products where sku = 'PROD-ESP')]
   ) ->> 'product_count')::int),
  1,
  'Caso 1: alta de una promoción kit% con 1 solo producto'
);

-- ---------------------------------------------------------------------------
-- Caso 2: crear una promoción kit% con 5 productos.
-- ---------------------------------------------------------------------------
insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active)
values ('TEST-MP-5', 'Kit% cinco productos', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.15, 91, false, false);

select is(
  (select (set_promotion_products(
     (select id from promotions where code = 'TEST-MP-5'),
     array[
       (select id from products where sku = 'PROD-VITC'),
       (select id from products where sku = 'PROD-NIAC'),
       (select id from products where sku = 'PROD-OJOS'),
       (select id from products where sku = 'PROD-ANTI'),
       (select id from products where sku = 'PROD-SENS')
     ]
   ) ->> 'product_count')::int),
  5,
  'Caso 2: alta de una promoción kit% con 5 productos'
);

-- ---------------------------------------------------------------------------
-- Caso 3: crear una promoción kit% con varios kits (el ejemplo real del
-- pedido: un 25% OFF cubriendo 4 kits a la vez, en vez de 4 promociones).
-- ---------------------------------------------------------------------------
insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active)
values ('TEST-MP-KITS', '25% OFF en 4 kits', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.25, 92, false, false);

select is(
  (select (set_promotion_products(
     (select id from promotions where code = 'TEST-MP-KITS'),
     array[
       (select id from products where sku = 'KIT-VN'),
       (select id from products where sku = 'KIT-ECN'),
       (select id from products where sku = 'KIT-EVSPC'),
       (select id from products where sku = 'KIT-ESOC')
     ]
   ) ->> 'product_count')::int),
  4,
  'Caso 3: alta de una promoción kit% con varios kits (4)'
);

-- ---------------------------------------------------------------------------
-- Caso 4: combinación producto + kit en la misma promoción.
-- ---------------------------------------------------------------------------
insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active)
values ('TEST-MP-MIX', 'Kit% producto + kit', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.30, 93, false, false);

select is(
  (select (set_promotion_products(
     (select id from promotions where code = 'TEST-MP-MIX'),
     array[(select id from products where sku = 'PROD-ESP'), (select id from products where sku = 'KIT-VN')]
   ) ->> 'product_count')::int),
  2,
  'Caso 4a: alta de una promoción kit% combinando 1 producto + 1 kit'
);

select is(
  (
    select array_agg(p.product_type::text order by p.product_type)
    from public.promotion_products pp
    join public.products p on p.id = pp.product_id
    where pp.promotion_id = (select id from promotions where code = 'TEST-MP-MIX')
  ),
  array['product', 'kit'], -- product_type es un enum (product, accessory, kit) — el order by usa el orden de declaración, no alfabético
  'Caso 4b: la composición queda con un producto Y un kit, visualmente distinguibles por product_type'
);

-- ---------------------------------------------------------------------------
-- Caso 5: editar una promoción existente y AGREGAR un producto.
-- ---------------------------------------------------------------------------
select is(
  (select (set_promotion_products(
     (select id from promotions where code = 'TEST-MP-1'),
     array[(select id from products where sku = 'PROD-ESP'), (select id from products where sku = 'PROD-ANTI')]
   ) ->> 'product_count')::int),
  2,
  'Caso 5a: editar y agregar un producto — queda con 2'
);

select ok(
  exists(
    select 1 from public.promotion_products
    where promotion_id = (select id from promotions where code = 'TEST-MP-1')
      and product_id = (select id from products where sku = 'PROD-ANTI')
  ),
  'Caso 5b: el producto agregado aparece en la composición'
);

-- ---------------------------------------------------------------------------
-- Caso 6: editar y QUITAR un producto — sin duplicar filas.
-- ---------------------------------------------------------------------------
select is(
  (select (set_promotion_products(
     (select id from promotions where code = 'TEST-MP-1'),
     array[(select id from products where sku = 'PROD-ANTI')]
   ) ->> 'product_count')::int),
  1,
  'Caso 6a: editar y quitar un producto — queda con 1'
);

select ok(
  not exists(
    select 1 from public.promotion_products
    where promotion_id = (select id from promotions where code = 'TEST-MP-1')
      and product_id = (select id from products where sku = 'PROD-ESP')
  ),
  'Caso 6b: el producto quitado ya no aparece en la composición'
);

-- ---------------------------------------------------------------------------
-- Caso 7: evitar duplicados — el mismo producto dos veces en el array.
-- ---------------------------------------------------------------------------
select throws_like(
  $$select set_promotion_products(
    (select id from promotions where code = 'TEST-MP-1'),
    array[(select id from products where sku = 'PROD-ANTI'), (select id from products where sku = 'PROD-ANTI')]
  )$$,
  '%No repitas el mismo producto%',
  'Caso 7: no se puede repetir el mismo producto en la composición'
);

-- ---------------------------------------------------------------------------
-- Caso 8: el % se aplica de forma independiente a CUALQUIER producto/kit
-- asociado presente en el carrito (no solo al primero — el bug real que
-- corrige este ajuste).
-- ---------------------------------------------------------------------------
update public.promotions set active = true where code = 'TEST-MP-KITS';

select is(
  (
    select count(*)::int
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'KIT-VN'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'KIT-ECN'), 'quantity', 1)
        ),
        (select id from payment_methods where code = 'CASH')
      ) -> 'lines'
    ) l
    where l ->> 'applied_promotion_id' = (select id from promotions where code = 'TEST-MP-KITS')::text
  ),
  2,
  'Caso 8: el % de la promoción se aplica a CADA kit asociado presente en el carrito, no solo al primero'
);

-- ---------------------------------------------------------------------------
-- Caso 9: 3x2 sigue funcionando con selección múltiple (más de 3 productos
-- asociados) — regresión, ya era N-ario antes de este ajuste.
-- ---------------------------------------------------------------------------
insert into public.promotions (code, name, type, price_condition_id, group_size, priority, stackable, active)
values ('TEST-MP-3X2', '3x2 multiproducto', 'THREE_FOR_TWO', (select id from price_conditions where rule_type = 'BASE'), 3, 94, false, true);

select lives_ok(
  $$select set_promotion_products(
    (select id from promotions where code = 'TEST-MP-3X2'),
    array[
      (select id from products where sku = 'PROD-VITC'),
      (select id from products where sku = 'PROD-NIAC'),
      (select id from products where sku = 'PROD-OJOS'),
      (select id from products where sku = 'PROD-ANTI')
    ]
  )$$,
  'Caso 9a: 3x2 con 4 productos asociados (no limitado a exactamente 3 IDs)'
);

select is(
  (
    select count(*)::int
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'PROD-NIAC'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'PROD-OJOS'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'PROD-ANTI'), 'quantity', 1)
        ),
        (select id from payment_methods where code = 'CASH')
      ) -> 'lines'
    ) l
    where (l ->> 'sale_unit_price')::numeric = 0
  ),
  1,
  'Caso 9b: con 4 productos participantes, sigue siendo exactamente 1 unidad gratis (la más barata)'
);

-- ---------------------------------------------------------------------------
-- Caso 10: modificar qué productos participan HOY de una promoción NO
-- modifica ventas históricas — sale_items es un snapshot inmutable.
-- ---------------------------------------------------------------------------
insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active)
values ('TEST-MP-HIST', 'Kit% snapshot histórico', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.20, 95, false, true);
select set_promotion_products(
  (select id from promotions where code = 'TEST-MP-HIST'),
  array[(select id from products where sku = 'ACC-PADS2')]
);

-- ACC-PADS2 no trackea stock propio (track_stock = false) pero es un combo
-- de 2× ACC-PADS1 (kit_components) — la venta sí descuenta stock del
-- componente, hace falta cargarlo.
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'ACC-PADS1'), 10, 'RECEPTION');

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'ACC-PADS2'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH')
) ->> 'sale_id')::uuid as new_sale_id \gset

select is(
  (select sale_unit_price from sale_items where sale_id = :'new_sale_id'),
  12800.00,
  'Caso 10a: la venta confirmada queda con el precio promocional (16000 × 0.8) vigente al momento de la venta'
);

-- Se edita la composición: ACC-PADS2 deja de participar, entra ACC-PADS1 en
-- su lugar. La venta ya confirmada no debe cambiar.
select set_promotion_products(
  (select id from promotions where code = 'TEST-MP-HIST'),
  array[(select id from products where sku = 'ACC-PADS1')]
);

select is(
  (select sale_unit_price from sale_items where sale_id = :'new_sale_id'),
  12800.00,
  'Caso 10b: editar qué productos participan HOY de la promoción NO recalcula sale_items de la venta histórica'
);

select * from finish();
rollback;
