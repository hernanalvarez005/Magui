-- pgTAP: Bloque D — anulación segura de ventas con devolución automática de
-- stock. Casos 1-9 de la sección 31 del pedido "Stock, promociones y
-- anulación de ventas". Correr con: supabase test db (Supabase CLI + Docker).
begin;
select plan(15);

insert into auth.users (id, email) values
  ('e1000000-0000-0000-0000-000000000001', 'admin.cancelsale@test.maguirejuve.com'),
  ('e1000000-0000-0000-0000-000000000002', 'seller.cancelsale@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'e1000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'e1000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'e1000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'e1000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'DEP';

set role authenticated;
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Caso 1: anular producto individual devuelve stock.
-- ---------------------------------------------------------------------------
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'PROD-VITC'), 10, 'RECEPTION');

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 2)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH')
) ->> 'sale_id')::uuid as simple_sale_id \gset

select is(
  (select quantity from inventory_balances
    where product_id = (select id from products where sku = 'PROD-VITC')
      and location_id = (select id from stock_locations where code = 'DEP')),
  8.00,
  'Precondición: la venta de 2 unidades descontó stock (10 -> 8)'
);

-- Sección 25: el stock total general también refleja el descuento (en
-- delta, no en valor absoluto — el seed ya trae stock de PROD-VITC en otras
-- sedes además de la que este test toca).
select sum(quantity) as total_before_cancel from product_stock_status
  where product_id = (select id from products where sku = 'PROD-VITC') \gset

-- Vendedora (no admin) anula — sección 16: admin y vendedor pueden anular.
set role authenticated;
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-000000000002', false);

select lives_ok(
  format($$select cancel_sale('%s'::uuid, 'Cliente se arrepintió')$$, :'simple_sale_id'),
  'Una vendedora (no admin) puede anular una venta — sección 16'
);

-- Vuelve a admin para leer el total general: la vendedora solo tiene acceso
-- (RLS) a la sede DEP, así que product_stock_status desde su sesión muestra
-- únicamente esa sede — comportamiento correcto (igual que /stock), pero no
-- sirve para comparar el total de TODAS las sedes.
set role authenticated;
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-000000000001', false);

select is(
  (select quantity from inventory_balances
    where product_id = (select id from products where sku = 'PROD-VITC')
      and location_id = (select id from stock_locations where code = 'DEP')),
  10.00,
  'Caso 1: anular un producto individual devuelve exactamente el stock descontado'
);

select is(
  (select sum(quantity) from product_stock_status where product_id = (select id from products where sku = 'PROD-VITC')),
  (:total_before_cancel + 2)::numeric,
  'Caso 9: el stock total general refleja la reposición inmediatamente (+2 respecto de antes de anular)'
);

-- ---------------------------------------------------------------------------
-- Caso 2: anular un kit devuelve los componentes — usando el ledger real de
-- la venta (stock_movements), no la composición ACTUAL del kit (que en este
-- test se modifica después de vender, a propósito).
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-000000000001', false);

insert into public.products (sku, name, product_type, track_stock, commissionable, promo_eligible)
values ('TEST-CANCEL-KIT', 'Kit anulación test', 'kit', false, true, true);
insert into public.kit_components (kit_product_id, component_product_id, quantity)
values
  ((select id from products where sku = 'TEST-CANCEL-KIT'), (select id from products where sku = 'PROD-VITC'), 1),
  ((select id from products where sku = 'TEST-CANCEL-KIT'), (select id from products where sku = 'PROD-NIAC'), 1);
select set_product_price((select id from products where sku = 'TEST-CANCEL-KIT'), (select id from price_conditions where rule_type = 'BASE'), 50000);
select set_product_price((select id from products where sku = 'TEST-CANCEL-KIT'), (select id from price_conditions where code = 'CASH'), 45000);
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'PROD-NIAC'), 10, 'RECEPTION');

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-CANCEL-KIT'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH')
) ->> 'sale_id')::uuid as kit_sale_id \gset

-- Se agrega un tercer componente al kit DESPUÉS de la venta — la reversión
-- tiene que ignorarlo (nunca formó parte de esta venta).
insert into public.products (sku, name, product_type, track_stock, commissionable, promo_eligible)
values ('PROD-EXTRA-CANCEL', 'Agregado después de vender', 'product', true, true, true);
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'PROD-EXTRA-CANCEL'), 5, 'RECEPTION');
insert into public.kit_components (kit_product_id, component_product_id, quantity)
values ((select id from products where sku = 'TEST-CANCEL-KIT'), (select id from products where sku = 'PROD-EXTRA-CANCEL'), 1);

select lives_ok(
  format($$select cancel_sale('%s'::uuid, 'Prueba de anulación con kit modificado')$$, :'kit_sale_id'),
  'Anular un kit no revienta aunque su composición haya cambiado después de la venta'
);

select is(
  (select quantity from inventory_balances
    where product_id = (select id from products where sku = 'PROD-VITC')
      and location_id = (select id from stock_locations where code = 'DEP')),
  10.00,
  'Caso 2a: componente VITC del kit repuesto (volvió a 10)'
);
select is(
  (select quantity from inventory_balances
    where product_id = (select id from products where sku = 'PROD-NIAC')
      and location_id = (select id from stock_locations where code = 'DEP')),
  10.00,
  'Caso 2b: componente NIAC del kit repuesto (volvió a 10)'
);
select is(
  (select quantity from inventory_balances
    where product_id = (select id from products where sku = 'PROD-EXTRA-CANCEL')
      and location_id = (select id from stock_locations where code = 'DEP')),
  5.00,
  'Caso 2c: el componente agregado DESPUÉS de la venta queda intacto (nunca se tocó, ni al vender ni al anular)'
);

-- ---------------------------------------------------------------------------
-- Casos 3, 4, 5: usuario, motivo y fecha quedan registrados.
-- ---------------------------------------------------------------------------
select is(
  (select cancelled_by from sales where id = :'simple_sale_id'),
  'e1000000-0000-0000-0000-000000000002'::uuid,
  'Caso 3: el usuario que anuló queda registrado en cancelled_by'
);

select is(
  (select cancellation_reason from sales where id = :'simple_sale_id'),
  'Cliente se arrepintió',
  'Caso 4: el motivo queda registrado en cancellation_reason'
);

select ok(
  (select cancelled_at from sales where id = :'simple_sale_id') is not null,
  'Caso 5: la fecha de anulación queda registrada en cancelled_at'
);

-- ---------------------------------------------------------------------------
-- Caso 6: doble anulación falla y es idempotente (nunca duplica la reposición).
-- ---------------------------------------------------------------------------
select throws_like(
  format($$select cancel_sale('%s'::uuid, 'Segundo intento')$$, :'simple_sale_id'),
  '%ya se encuentra anulada%',
  'Caso 6: anular una venta ya anulada rechaza con el mensaje exacto del pedido'
);

-- ---------------------------------------------------------------------------
-- Caso 7: venta cancelada no entra en facturación (product_revenue_report).
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-000000000001', false);

select is(
  (
    select coalesce(sum((r ->> 'units')::numeric), 0)
    from jsonb_array_elements(
      product_revenue_report(current_date - 1, current_date + 1) -> 'rows'
    ) r
    where r ->> 'sku' = 'PROD-VITC'
  ),
  0::numeric,
  'Caso 7: product_revenue_report no cuenta unidades de una venta cancelada'
);

-- ---------------------------------------------------------------------------
-- Caso 8: venta cancelada no genera comisión activa.
-- ---------------------------------------------------------------------------
insert into public.doctors (code, full_name, commission_percent, active)
values ('DOC-CANCEL-TEST', 'Doctora Test Anulación', 0.10, true);
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'PROD-NIAC'), 5, 'RECEPTION');

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-NIAC'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  null, (select id from doctors where code = 'DOC-CANCEL-TEST')
) ->> 'sale_id')::uuid as commission_sale_id \gset

select ok(
  (select commission_total from sales where id = :'commission_sale_id') > 0,
  'Precondición: la venta con doctora generó comisión > 0'
);

select cancel_sale(:'commission_sale_id'::uuid, 'Anulada para validar exclusión de comisión');

select is(
  (
    select coalesce(sum(commission_total), 0)
    from sales
    where doctor_id = (select id from doctors where code = 'DOC-CANCEL-TEST')
      and status = 'confirmed'
  ),
  0::numeric,
  'Caso 8: una venta cancelada no aporta comisión a la agregación activa (status != cancelled)'
);

select * from finish();
rollback;
