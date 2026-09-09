-- pgTAP: Promociones conviven por línea/producto, no por venta completa
-- (migración 66 — corrección de regla de negocio, auditada y aprobada).
-- Casos, en orden (numeración según el pedido original entre paréntesis):
--   1-2)   Producto normal + Efectivo / Transferencia -> recibe la condición
--          de pago correspondiente, sin ninguna promoción activa de por medio.
--   3-4)   Solo 3x2 / solo kit 25% (regresión — sin cambios de fórmula).
--   5-6)   3x2 + normal / kit% + normal -> el normal sigue recibiendo la
--          condición de pago (regresión — esta parte nunca tuvo bug).
--   7)     3x2 (no combinable) + kit% (no combinable) sobre productos
--          DISTINTOS -> ambas conviven en la misma venta (el fix).
--   8)     Ejemplo obligatorio completo del pedido: 3x2 + kit 25% + producto
--          normal, pagado con Transferencia.
--   9)     Dos promociones de otros tipos (duo% + kit%) sobre productos
--          distintos -> también conviven (no es exclusivo de 3x2).
--   10)    Dos promociones candidatas sobre el MISMO producto (bypaseando a
--          propósito el trigger de exclusividad, que estructuralmente hace
--          esto imposible por la vía normal) -> una sola gana, por prioridad.
--   11-13) Mismo escenario del caso 8, sin cambios, en Web / Sede 25 / Sede 37.
--   14)    Medios de pago restringidos por UNA promoción (migración 63) —
--          confirma que el fix de esta migración no la rompe.
--   15)    Intersección de medios con DOS promociones ganadoras simultáneas
--          reales (antes de este fix, esto era estructuralmente imposible de
--          ejercitar con dos promociones no-stackable a la vez).
--   16)    Combinación sin intersección -> rechazo claro.
--   17)    Confirma que las líneas promocionadas usan la condición BASE de su
--          propia promoción, nunca la condición del medio de pago elegido.
--   18)    Confirma que el producto normal usa la condición del medio de pago
--          aunque la venta tenga otras promociones activas simultáneas.
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(18);

insert into auth.users (id, email) values
  ('c3000000-0000-0000-0000-000000000001', 'admin.stacking@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'c3000000-0000-0000-0000-000000000001';
insert into public.profile_locations (profile_id, location_id)
  select 'c3000000-0000-0000-0000-000000000001', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'c3000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Catálogo: PLS-NORM (sin ninguna promoción), PLS-A/PLS-B (3x2, group_size=3),
-- PLS-KIT (kit% 25%), PLS-D1/PLS-D2 (duo% 15%), PLS-X (contienda del caso 10).
-- Todos con precio bajo LIST/CASH/TRANSFER — fn_pricing_quote resuelve precio
-- de TODA línea bajo el medio de pago elegido antes de que las promociones
-- tengan oportunidad de pisarlo, así que hace falta precio ahí también, no
-- solo bajo la condición base de cada promoción.
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('PLS-NORM', 'Stacking normal', 'product', 'Test', true, true, true, true),
  ('PLS-A', 'Stacking 3x2 A (barato)', 'product', 'Test', true, true, true, true),
  ('PLS-B', 'Stacking 3x2 B (caro)', 'product', 'Test', true, true, true, true),
  -- product_type='product' (no 'kit') a propósito: lo que se prueba acá es
  -- la promoción KIT_PERCENT, no la composición física de un kit real — mismo
  -- criterio ya usado en promotion_payment_methods.test.sql.
  ('PLS-KIT', 'Stacking kit 25%', 'product', 'Test', true, true, true, true),
  ('PLS-D1', 'Stacking duo 1', 'product', 'Test', true, true, true, true),
  ('PLS-D2', 'Stacking duo 2', 'product', 'Test', true, true, true, true),
  ('PLS-X', 'Stacking contienda', 'product', 'Test', true, true, true, true);

select set_product_price((select id from products where sku = sku_val), (select id from price_conditions where code = pc_code), amount)
from (values
  ('PLS-NORM', 'LIST', 10000), ('PLS-NORM', 'CASH', 9000), ('PLS-NORM', 'TRANSFER', 9500),
  ('PLS-A', 'LIST', 8000), ('PLS-A', 'CASH', 8000), ('PLS-A', 'TRANSFER', 8000),
  ('PLS-B', 'LIST', 9000), ('PLS-B', 'CASH', 9000), ('PLS-B', 'TRANSFER', 9000),
  ('PLS-KIT', 'LIST', 20000), ('PLS-KIT', 'CASH', 20000), ('PLS-KIT', 'TRANSFER', 20000),
  ('PLS-D1', 'LIST', 5000), ('PLS-D1', 'CASH', 5000), ('PLS-D1', 'TRANSFER', 5000),
  ('PLS-D2', 'LIST', 6000), ('PLS-D2', 'CASH', 6000), ('PLS-D2', 'TRANSFER', 6000),
  ('PLS-X', 'LIST', 10000), ('PLS-X', 'CASH', 10000), ('PLS-X', 'TRANSFER', 10000)
) as t(sku_val, pc_code, amount);

select set_stock((select id from stock_locations where code = loc_code), (select id from products where sku = sku_val), 100, 'RECEPTION')
from (values
  ('SED-25', 'PLS-NORM'), ('SED-25', 'PLS-A'), ('SED-25', 'PLS-B'), ('SED-25', 'PLS-KIT'),
  ('SED-25', 'PLS-D1'), ('SED-25', 'PLS-D2'), ('SED-25', 'PLS-X'),
  ('SED-37', 'PLS-NORM'), ('SED-37', 'PLS-A'), ('SED-37', 'PLS-B'), ('SED-37', 'PLS-KIT'),
  ('SED-37', 'PLS-D1'), ('SED-37', 'PLS-D2')
) as t(loc_code, sku_val);

insert into public.customers (full_name, dni) values ('Clienta Stacking (test)', '30999911');

select id as sed25_id from stock_locations where code = 'SED-25' \gset
select id as sed37_id from stock_locations where code = 'SED-37' \gset
select id as branch_channel_id from sales_channels where code <> 'WEB' limit 1 \gset
select id as web_channel_id from sales_channels where code = 'WEB' \gset
select id as cash_id from payment_methods where code = 'CASH' \gset
select id as transfer_id from payment_methods where code = 'TRANSFER' \gset
select id as cash_pc_id from price_conditions where code = 'CASH' \gset
select id as transfer_pc_id from price_conditions where code = 'TRANSFER' \gset
select id as base_pc_id from price_conditions where rule_type = 'BASE' \gset
select id as account_id from payment_accounts where active limit 1 \gset
select id as customer_id from customers where dni = '30999911' \gset

insert into public.promotions (code, name, type, price_condition_id, group_size, priority, stackable) values
  ('PLS-3X2', 'Stacking 3x2', 'THREE_FOR_TWO', :'base_pc_id', 3, 10, false);
select set_promotion_products(
  (select id from promotions where code = 'PLS-3X2'),
  array[(select id from products where sku = 'PLS-A'), (select id from products where sku = 'PLS-B')]
);
select id as promo_3x2_id from promotions where code = 'PLS-3X2' \gset

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable) values
  ('PLS-KITPROMO', 'Stacking kit 25%', 'KIT_PERCENT', :'base_pc_id', 0.25, 20, false);
select set_promotion_products(
  (select id from promotions where code = 'PLS-KITPROMO'),
  array[(select id from products where sku = 'PLS-KIT')]
);
select id as promo_kit_id from promotions where code = 'PLS-KITPROMO' \gset

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable) values
  ('PLS-DUOPROMO', 'Stacking duo 15%', 'DUO_PERCENT', :'base_pc_id', 0.15, 30, false);
select set_promotion_products(
  (select id from promotions where code = 'PLS-DUOPROMO'),
  array[(select id from products where sku = 'PLS-D1'), (select id from products where sku = 'PLS-D2')]
);
select id as promo_duo_id from promotions where code = 'PLS-DUOPROMO' \gset

-- ===========================================================================
-- Casos 1-2: producto normal, sin ninguna promoción de por medio -> recibe
-- exactamente la condición de precio del medio de pago elegido.
-- ===========================================================================
select is(
  (
    select (l ->> 'applied_price_condition_id')::uuid
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PLS-NORM'), 'quantity', 1)),
        :'cash_id'
      ) -> 'lines'
    ) l
  ),
  :'cash_pc_id'::uuid,
  'Caso 1: producto normal + Efectivo -> recibe la condición de precio Efectivo'
);

select is(
  (
    select (l ->> 'applied_price_condition_id')::uuid
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PLS-NORM'), 'quantity', 1)),
        :'transfer_id'
      ) -> 'lines'
    ) l
  ),
  :'transfer_pc_id'::uuid,
  'Caso 2: producto normal + Transferencia -> recibe la condición de precio Transferencia'
);

-- ===========================================================================
-- Casos 3-4: solo 3x2 / solo kit% (regresión — mismas fórmulas de siempre).
-- ===========================================================================
select is(
  (
    select count(*)::int
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PLS-A'), 'quantity', 3)),
        :'cash_id'
      ) -> 'lines'
    ) l
    where (l ->> 'applied_promotion_id')::uuid = :'promo_3x2_id'::uuid
  ),
  2,
  'Caso 3: solo 3x2 (compra exacta de 3) -> 2 líneas tagueadas (gratis + pagas-en-grupo), regresión sin cambios'
);

select is(
  (
    select (l ->> 'sale_unit_price')::numeric
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PLS-KIT'), 'quantity', 1)),
        :'cash_id'
      ) -> 'lines'
    ) l
  ),
  15000::numeric,
  'Caso 4: solo kit% -> precio reducido 25% sobre la condición base (20000 * 0.75 = 15000), regresión sin cambios'
);

-- ===========================================================================
-- Casos 5-6: promoción + normal -> el normal sigue recibiendo la condición
-- de pago (esta parte nunca tuvo bug, se reconfirma tras el fix).
-- ===========================================================================
select is(
  (
    select (l ->> 'applied_price_condition_id')::uuid
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-A'), 'quantity', 3),
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-NORM'), 'quantity', 1)
        ),
        :'transfer_id'
      ) -> 'lines'
    ) l
    where (l ->> 'product_id')::uuid = (select id from products where sku = 'PLS-NORM')
  ),
  :'transfer_pc_id'::uuid,
  'Caso 5: 3x2 + normal -> el normal recibe la condición Transferencia'
);

select is(
  (
    select (l ->> 'applied_price_condition_id')::uuid
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-KIT'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-NORM'), 'quantity', 1)
        ),
        :'transfer_id'
      ) -> 'lines'
    ) l
    where (l ->> 'product_id')::uuid = (select id from products where sku = 'PLS-NORM')
  ),
  :'transfer_pc_id'::uuid,
  'Caso 6: kit% + normal -> el normal recibe la condición Transferencia'
);

-- ===========================================================================
-- Caso 7 — EL FIX: 3x2 (no combinable) + kit% (no combinable) sobre
-- productos DISTINTOS -> ambas conviven, cada una con su propio precio.
-- Antes de esta migración, la que perdiera el sorteo global caía a la
-- condición de pago en vez de a su propio precio promocional.
-- ===========================================================================
select is(
  (
    select count(*)::int
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-A'), 'quantity', 3),
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-KIT'), 'quantity', 1)
        ),
        :'transfer_id'
      ) -> 'lines'
    ) l
    where l ->> 'applied_promotion_id' is not null
      and (l ->> 'applied_promotion_id')::uuid in (:'promo_3x2_id'::uuid, :'promo_kit_id'::uuid)
  ),
  3,
  'Caso 7: 3x2 + kit% sobre productos distintos CONVIVEN — 3 líneas tagueadas (2 del 3x2 + 1 del kit)'
);

-- ===========================================================================
-- Caso 8 — ejemplo obligatorio completo del pedido: 3 unidades 3x2 + 1 kit
-- 25% + 1 producto normal, pagado con Transferencia.
-- ===========================================================================
select is(
  (
    select jsonb_agg(jsonb_build_object(
      'promo', l ->> 'applied_promotion_id',
      'price_condition', l ->> 'applied_price_condition_id'
    ) order by l ->> 'product_id')
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-A'), 'quantity', 3),
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-KIT'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-NORM'), 'quantity', 1)
        ),
        :'transfer_id'
      ) -> 'lines'
    ) l
    where (l ->> 'product_id')::uuid = (select id from products where sku = 'PLS-NORM')
  ),
  jsonb_build_array(jsonb_build_object('promo', null, 'price_condition', :'transfer_pc_id')),
  'Caso 8: en el ejemplo completo (3x2 + kit 25% + normal, Transferencia), el normal SOLO recibe la condición de pago'
);

-- ===========================================================================
-- Caso 9: dos promociones de OTROS tipos (duo% + kit%) sobre productos
-- distintos -> también conviven, no es un comportamiento exclusivo de 3x2.
-- ===========================================================================
select is(
  (
    select count(*)::int
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-D1'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-D2'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-KIT'), 'quantity', 1)
        ),
        :'cash_id'
      ) -> 'lines'
    ) l
    where l ->> 'applied_promotion_id' is not null
      and (l ->> 'applied_promotion_id')::uuid in (:'promo_duo_id'::uuid, :'promo_kit_id'::uuid)
  ),
  3,
  'Caso 9: duo% + kit% sobre productos distintos CONVIVEN — 3 líneas tagueadas (2 del duo + 1 del kit)'
);

-- ===========================================================================
-- Caso 10: dos promociones candidatas sobre el MISMO producto. Esto es
-- estructuralmente imposible por la vía normal (fn_check_promotion_product_exclusive
-- / fn_check_promotion_activation_exclusive, 20260201000010) — se bypasea acá
-- a propósito para probar que fn_apply_promotions tiene su propio desempate
-- defensivo por prioridad, y NUNCA aplica dos promociones a la vez sobre la
-- misma unidad aunque esa garantía de escritura alguna vez se rompa.
-- ===========================================================================
insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable) values
  ('PLS-X1', 'Stacking contienda X1 (prioridad alta, gana)', 'KIT_PERCENT', :'base_pc_id', 0.30, 5, false),
  ('PLS-X2', 'Stacking contienda X2 (prioridad baja, pierde)', 'KIT_PERCENT', :'base_pc_id', 0.10, 50, false);
select set_promotion_products(
  (select id from promotions where code = 'PLS-X1'),
  array[(select id from products where sku = 'PLS-X')]
);
select id as promo_x1_id from promotions where code = 'PLS-X1' \gset
select id as promo_x2_id from promotions where code = 'PLS-X2' \gset

-- session_replication_role='replica' desactiva TODOS los triggers de la
-- sesión (no solo el de exclusividad) sin tocar la definición de la tabla
-- (un ALTER TABLE ... DISABLE TRIGGER falla acá con "pending trigger
-- events" porque set_promotion_products, arriba, ya dejó encolado el
-- trigger deferred de conteo por tipo) — alcanza y sobra para este insert
-- puntual, restaurado inmediatamente después.
reset role;
set session_replication_role = replica;
insert into public.promotion_products (promotion_id, product_id)
  values (:'promo_x2_id'::uuid, (select id from products where sku = 'PLS-X'));
set session_replication_role = origin;
set role authenticated;
select set_config('request.jwt.claim.sub', 'c3000000-0000-0000-0000-000000000001', false);

select is(
  (
    select jsonb_agg(jsonb_build_object('promo', l ->> 'applied_promotion_id', 'qty', l ->> 'quantity') order by l ->> 'applied_promotion_id')
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PLS-X'), 'quantity', 1)),
        :'cash_id'
      ) -> 'lines'
    ) l
    where (l ->> 'product_id')::uuid = (select id from products where sku = 'PLS-X')
  ),
  jsonb_build_array(jsonb_build_object('promo', :'promo_x1_id', 'qty', '1')),
  'Caso 10: dos candidatas sobre el mismo producto -> una sola línea, gana la de mayor prioridad (X1, nunca X2, nunca las dos)'
);

-- ===========================================================================
-- Casos 11-13: el mismo escenario del caso 8, sin cambios, en Web / Sede 25 /
-- Sede 37 — confirma que no hay ninguna excepción de pricing por canal/sede.
-- ===========================================================================
select is(
  (
    select jsonb_agg(jsonb_build_object(
      'promo', l ->> 'applied_promotion_id',
      'price_condition', l ->> 'applied_price_condition_id'
    ) order by l ->> 'product_id')
    from jsonb_array_elements(
      (create_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-A'), 'quantity', 3),
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-KIT'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-NORM'), 'quantity', 1)
        ),
        :'sed25_id', :'web_channel_id', :'transfer_id', :'customer_id', null, null, null, null, now(),
        false, null, null, false, :'account_id', 'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
      ) -> 'lines')
    ) l
    where (l ->> 'product_id')::uuid = (select id from products where sku = 'PLS-NORM')
  ),
  jsonb_build_array(jsonb_build_object('promo', null, 'price_condition', :'transfer_pc_id')),
  'Caso 11: mismo escenario en Web (PICKUP) -> el normal sigue recibiendo la condición de pago, idéntico a Sede'
);

select is(
  (
    select jsonb_agg(jsonb_build_object(
      'promo', l ->> 'applied_promotion_id',
      'price_condition', l ->> 'applied_price_condition_id'
    ) order by l ->> 'product_id')
    from jsonb_array_elements(
      (create_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-A'), 'quantity', 3),
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-KIT'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-NORM'), 'quantity', 1)
        ),
        :'sed25_id', :'branch_channel_id', :'transfer_id', :'customer_id', null, null, null, null, now(),
        false, null, null, false, :'account_id'
      ) -> 'lines')
    ) l
    where (l ->> 'product_id')::uuid = (select id from products where sku = 'PLS-NORM')
  ),
  jsonb_build_array(jsonb_build_object('promo', null, 'price_condition', :'transfer_pc_id')),
  'Caso 12: mismo escenario en Sede 25 -> idéntico resultado'
);

select is(
  (
    select jsonb_agg(jsonb_build_object(
      'promo', l ->> 'applied_promotion_id',
      'price_condition', l ->> 'applied_price_condition_id'
    ) order by l ->> 'product_id')
    from jsonb_array_elements(
      (create_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-A'), 'quantity', 3),
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-KIT'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-NORM'), 'quantity', 1)
        ),
        :'sed37_id', :'branch_channel_id', :'transfer_id', :'customer_id', null, null, null, null, now(),
        false, null, null, false, :'account_id'
      ) -> 'lines')
    ) l
    where (l ->> 'product_id')::uuid = (select id from products where sku = 'PLS-NORM')
  ),
  jsonb_build_array(jsonb_build_object('promo', null, 'price_condition', :'transfer_pc_id')),
  'Caso 13: mismo escenario en Sede 37 -> idéntico resultado'
);

-- ===========================================================================
-- Casos 14-16: medios de pago permitidos por promoción (migración 63) — el
-- fix de esta migración no la rompe, y ahora se ejercita con dos ganadoras
-- REALES simultáneas (antes, estructuralmente, nunca podía haber dos
-- promociones no-stackable ganando a la vez).
-- ===========================================================================
select set_promotion_payment_methods(:'promo_kit_id', array[:'transfer_id'::uuid]);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'PLS-KIT'), :'sed25_id', :'branch_channel_id', :'cash_id', :'customer_id', :'account_id'
  ),
  'Caso 14: kit% restringido a Transferencia -> venta en Efectivo rechazada (regresión de la migración 63)'
);

select set_promotion_payment_methods(:'promo_3x2_id', array[:'cash_id'::uuid, :'transfer_id'::uuid]);

select lives_ok(
  format(
    $$select create_sale(
      jsonb_build_array(
        jsonb_build_object('product_id', '%s'::uuid, 'quantity', 3),
        jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)
      ),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'PLS-A'), (select id from products where sku = 'PLS-KIT'),
    :'sed25_id', :'branch_channel_id', :'transfer_id', :'customer_id', :'account_id'
  ),
  'Caso 15: 3x2 (CASH+TRANSFER) + kit% (TRANSFER) ganando A LA VEZ -> Transferencia está en la intersección, permitida'
);

select set_promotion_payment_methods(:'promo_3x2_id', array[:'cash_id'::uuid]);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(
        jsonb_build_object('product_id', '%s'::uuid, 'quantity', 3),
        jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)
      ),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'PLS-A'), (select id from products where sku = 'PLS-KIT'),
    :'sed25_id', :'branch_channel_id', :'transfer_id', :'customer_id', :'account_id'
  ),
  'Caso 16: 3x2 reconfigurado a solo Efectivo (kit sigue en solo Transferencia) -> intersección vacía, Transferencia rechazada'
);

-- ===========================================================================
-- Caso 17: las líneas promocionadas usan la condición BASE de su propia
-- promoción, nunca la condición del medio de pago elegido.
-- ===========================================================================
select is(
  (
    select bool_and((l ->> 'applied_price_condition_id')::uuid = :'base_pc_id'::uuid)
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-A'), 'quantity', 3),
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-KIT'), 'quantity', 1)
        ),
        :'transfer_id'
      ) -> 'lines'
    ) l
    where l ->> 'applied_promotion_id' is not null
  ),
  true,
  'Caso 17: toda línea promocionada usa la condición BASE de su propia promoción, nunca Transferencia'
);

-- ===========================================================================
-- Caso 18: el producto normal usa la condición del medio de pago aunque la
-- venta tenga OTRAS promociones activas simultáneas (multi-promoción real).
-- ===========================================================================
select is(
  (
    select (l ->> 'applied_price_condition_id')::uuid
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-A'), 'quantity', 3),
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-KIT'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'PLS-NORM'), 'quantity', 1)
        ),
        :'cash_id'
      ) -> 'lines'
    ) l
    where (l ->> 'product_id')::uuid = (select id from products where sku = 'PLS-NORM')
  ),
  :'cash_pc_id'::uuid,
  'Caso 18: el normal recibe la condición Efectivo aunque 3x2 Y kit% estén activos y ganando a la vez'
);

select * from finish();
rollback;
