-- pgTAP: Precio de Lista maestro — recálculo automático AUTO/MANUAL
-- (migración 74). Casos:
--   A. Backfill — todo lo preexistente nace MANUAL, sin cambiar amounts.
--   B. Cascada básica: Lista cambia (AUTO recalcula, MANUAL conserva).
--   C. Cascada básica: % cambia (AUTO recalcula, MANUAL conserva).
--   D. save_price_matrix_changes: overrides manuales y "volver a automático".
--   E. % NULL no participa / producto sin Lista no participa.
--   F. Condición inactiva no participa / oculta pero activa sí participa.
--   G. Condición futura PAYMENT_METHOD, 0 product_prices previos.
--   H. Atomicidad de save_price_matrix_changes.
--   I. Permisos (no-admin).
--   J. create_price_condition genera/no genera AUTO según % y active.
--   K. Transición % no-nulo -> NULL (cierra AUTO, preserva MANUAL) y NULL -> %.
--   L. Reactivación (active false->true) sincroniza AUTO.
--   M. QUANTITY nunca participa.
--   N. Helper interno fn_recalculate_auto_prices no ejecutable por PUBLIC/anon/authenticated.
-- Correr con: rebuild local (preamble + seed_026_skus) + pg_prove.
begin;
select plan(37);

-- ---------------------------------------------------------------------------
-- A. Backfill: todo lo que ya existía (seed_data + cualquier fixture de
-- otros tests que haya corrido antes en la misma DB, aunque cada archivo
-- hace rollback de lo propio) nace MANUAL. Se verifica ANTES de insertar
-- nada nuevo en este archivo.
-- ---------------------------------------------------------------------------
select is(
  (select count(*)::int from product_prices where pricing_mode is distinct from 'MANUAL'),
  0,
  'A1: ningún product_prices preexistente (seed + migraciones previas) quedó con pricing_mode distinto de MANUAL'
);

-- ---------------------------------------------------------------------------
-- Fixtures propios.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('aae00000-0000-0000-0000-000000000001', 'admin.apr@test.maguirejuve.com'),
  ('aae00000-0000-0000-0000-000000000002', 'seller.apr@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'aae00000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'aae00000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'aae00000-0000-0000-0000-000000000001', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'aae00000-0000-0000-0000-000000000001', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('APR-A', 'Auto precio A', 'product', 'Test', true, true, true, true),
  ('APR-B', 'Auto precio B', 'product', 'Test', true, true, true, true),
  ('APR-NOLIST', 'Auto precio sin Lista', 'product', 'Test', true, true, true, true);

select set_product_price((select id from products where sku = 'APR-A'), (select id from price_conditions where code = 'LIST'), 100000);
select set_product_price((select id from products where sku = 'APR-B'), (select id from price_conditions where code = 'LIST'), 50000);
-- APR-NOLIST deliberadamente sin Lista.

-- Condición de prueba PAYMENT_METHOD propia, con 15% ya configurado, para no
-- interferir con CASH/TRANSFER reales de otros tests.
insert into public.payment_methods (code, name, active, requires_billing, sort_order)
values ('APR-PM15', 'Medio de prueba 15%', true, false, 999);
insert into public.price_conditions (code, name, rule_type, payment_method_id, discount_percent, priority, combinable, active)
values (
  'APR-PC15', 'Condición de prueba 15%', 'PAYMENT_METHOD',
  (select id from payment_methods where code = 'APR-PM15'), 0.15, 50, false, true
);

-- ---------------------------------------------------------------------------
-- B. Cascada básica — Lista cambia.
-- ---------------------------------------------------------------------------
-- APR-A no tiene todavía ninguna fila bajo APR-PC15 -> el primer cambio de
-- Lista debe CREARLA en AUTO (caso "no existe + Lista + condición activa +
-- % no nulo -> crear").
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-A'),
    'amount', 100000
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  85000::numeric,
  'B1: Lista $100.000 sin fila previa bajo APR-PC15 (15%) -> se CREA en AUTO, $85.000'
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  'AUTO',
  'B2: la fila recién creada es AUTO'
);

-- Cambiar Lista de nuevo -> recalcula la fila AUTO existente.
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-A'),
    'amount', 120000
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  102000::numeric,
  'B3: Lista $100.000 -> $120.000, AUTO recalcula a $102.000 (15% off)'
);

-- Convertir esa misma celda a MANUAL con un valor explícito, y volver a
-- cambiar Lista: no debe tocarse.
select save_price_matrix_changes(
  p_manual_overrides := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-A'),
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15'),
    'amount', 99999
  ))
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  'MANUAL',
  'B4: override manual explícito pasa la celda a MANUAL'
);
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-A'),
    'amount', 140000
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  99999::numeric,
  'B5: Lista cambia de nuevo ($120.000 -> $140.000) pero la celda es MANUAL -> conserva $99.999'
);

-- ---------------------------------------------------------------------------
-- C. Cascada básica — % cambia (afecta a TODOS los productos AUTO bajo esa condición).
-- ---------------------------------------------------------------------------
-- APR-B: primero generamos su fila AUTO bajo APR-PC15 cambiando Lista.
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-B'), 'amount', 50000
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  42500::numeric,
  'C1: APR-B Lista $50.000, 15% -> AUTO $42.500'
);

-- Cambiar el % de APR-PC15 de 15% a 20% -> recalcula APR-B (AUTO), pero NO
-- toca APR-A (MANUAL desde B4/B5).
select save_price_matrix_changes(
  p_percent_changes := jsonb_build_array(jsonb_build_object(
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15'), 'discount_percent', 0.20
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  40000::numeric,
  'C2: % 15%->20% recalcula APR-B (AUTO) a $40.000 (Lista $50.000 vigente)'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  99999::numeric,
  'C3: el mismo cambio de % NO toca APR-A, que sigue MANUAL en $99.999'
);

-- ---------------------------------------------------------------------------
-- D. "Volver a automático" — recalcula con Lista/% vigentes y pasa a AUTO.
-- ---------------------------------------------------------------------------
select save_price_matrix_changes(
  p_reset_to_auto := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-A'),
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15')
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  112000::numeric,
  'D1: "Volver a automático" recalcula APR-A con Lista $140.000 (B5) y % 20% (C2) vigentes -> $112.000'
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  'AUTO',
  'D2: y queda marcada AUTO de nuevo'
);

-- ---------------------------------------------------------------------------
-- E. % NULL no participa / producto sin Lista no participa.
-- ---------------------------------------------------------------------------
select save_price_matrix_changes(
  p_percent_changes := jsonb_build_array(jsonb_build_object(
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15'), 'discount_percent', null
  ))
);
select is(
  (select discount_percent from price_conditions where code = 'APR-PC15'),
  null,
  'E1: % puede quedar explícitamente NULL (ya no se fuerza a 0)'
);
-- (el cierre de AUTO por esta transición se prueba en detalle en la sección K)

-- Volver a poner 15% para seguir probando "producto sin Lista".
select save_price_matrix_changes(
  p_percent_changes := jsonb_build_array(jsonb_build_object(
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15'), 'discount_percent', 0.15
  ))
);
select is(
  (select count(*)::int from product_prices
     where product_id = (select id from products where sku = 'APR-NOLIST')
       and price_condition_id = (select id from price_conditions where code = 'APR-PC15')
       and active = true),
  0,
  'E2: APR-NOLIST (sin Lista vigente) no recibe ninguna fila AUTO aunque la condición esté activa y con %'
);

-- ---------------------------------------------------------------------------
-- F. Condición inactiva no participa / oculta pero activa sí participa.
-- ---------------------------------------------------------------------------
update public.price_conditions set active = false where code = 'APR-PC15';
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-B'), 'amount', 60000
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  -- $42.500: recalculado por el round-trip NULL->15% de la sección E
  -- (Lista $50.000 vigente en ese momento x 15%), no por este bloque.
  42500::numeric,
  'F1: con APR-PC15 inactiva, cambiar Lista de APR-B NO recalcula esa condición (sigue $42.500, stale a propósito)'
);
update public.price_conditions set active = true, visible_in_price_lookup = false where code = 'APR-PC15';
-- (la reactivación en sí se prueba en detalle en la sección L; acá solo
-- confirmamos que "oculta pero activa" participa normalmente.)
select save_price_matrix_changes(
  p_percent_changes := jsonb_build_array(jsonb_build_object(
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15'), 'discount_percent', 0.25
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  45000::numeric,
  'F2: APR-PC15 oculta (visible_in_price_lookup=false) pero activa SÍ recalcula normalmente (Lista $60.000, 25% -> $45.000)'
);
update public.price_conditions set visible_in_price_lookup = true where code = 'APR-PC15';

-- ---------------------------------------------------------------------------
-- G. Condición futura PAYMENT_METHOD con 0 product_prices previos.
-- ---------------------------------------------------------------------------
insert into public.payment_methods (code, name, active, requires_billing, sort_order)
values ('APR-FUTURA', 'Condición futura de prueba', true, false, 998);
insert into public.price_conditions (code, name, rule_type, payment_method_id, discount_percent, priority, combinable, active)
values (
  'APR-PCFUTURA', '9 cuotas futura (sin % al crear)', 'PAYMENT_METHOD',
  (select id from payment_methods where code = 'APR-FUTURA'), null, 49, false, true
);
select is(
  (select count(*)::int from product_prices where price_condition_id = (select id from price_conditions where code = 'APR-PCFUTURA')),
  0,
  'G1: condición futura recién creada sin % -> 0 product_prices (nada que calcular, nada que copiar: origen LIST default no aplica porque no se pasó copy explícito con % — ver J para el camino de creación con %)'
);
-- Asignarle %: debe generar AUTO para los productos CON Lista (APR-A, APR-B), ninguno para APR-NOLIST.
select save_price_matrix_changes(
  p_percent_changes := jsonb_build_array(jsonb_build_object(
    'price_condition_id', (select id from price_conditions where code = 'APR-PCFUTURA'), 'discount_percent', 0.05
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCFUTURA') and active = true),
  133000::numeric,
  'G2: asignar % por primera vez a una condición futura (0 filas previas) genera AUTO para APR-A (Lista $140.000, 5% -> $133.000)'
);
select is(
  (select count(*)::int from product_prices
     where product_id = (select id from products where sku = 'APR-NOLIST')
       and price_condition_id = (select id from price_conditions where code = 'APR-PCFUTURA')),
  0,
  'G3: y ninguna fila para APR-NOLIST (sin Lista vigente)'
);

-- ---------------------------------------------------------------------------
-- H. Atomicidad: un ítem inválido aborta TODO el guardado.
-- ---------------------------------------------------------------------------
select throws_ok(
  format(
    $$select save_price_matrix_changes(
        p_list_price_changes := jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'amount', 999)),
        p_manual_overrides := jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'price_condition_id', '%s'::uuid, 'amount', -5))
      )$$,
    (select id from products where sku = 'APR-B'),
    (select id from products where sku = 'APR-B'),
    (select id from price_conditions where code = 'APR-PC15')
  ),
  'H1: un override inválido (monto negativo) aborta toda la llamada'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where rule_type = 'BASE') and active = true),
  60000::numeric,
  'H2: la Lista de APR-B NO cambió a 999 — el item válido del mismo payload tampoco se guardó (todo o nada)'
);

-- ---------------------------------------------------------------------------
-- I. Permisos — no-admin rechazado.
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'aae00000-0000-0000-0000-000000000002', false);
select throws_ok(
  $$select save_price_matrix_changes(p_list_price_changes := jsonb_build_array(jsonb_build_object('product_id', gen_random_uuid(), 'amount', 100)))$$,
  'I1: un vendedor (no-admin) no puede llamar a save_price_matrix_changes'
);
set role authenticated;
select set_config('request.jwt.claim.sub', 'aae00000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- J. create_price_condition — genera/no genera AUTO según % y active.
-- ---------------------------------------------------------------------------
select create_price_condition(
  p_name := 'APR 9 cuotas -20%',
  p_discount_percent := 0.20,
  p_requires_billing := false,
  p_location_codes := array[]::text[],
  p_available_web := true,
  p_active := true,
  p_copy_prices_from_code := 'LIST',
  p_priority := 10
);
select is(
  (select amount from product_prices
     where product_id = (select id from products where sku = 'APR-A')
       and price_condition_id = (select id from price_conditions where name = 'APR 9 cuotas -20%')
       and active = true),
  112000::numeric,
  'J1: create_price_condition con 20% genera AUTO inmediatamente (Lista APR-A $140.000 -> $112.000), sin segunda edición'
);
select is(
  (select pricing_mode from product_prices
     where product_id = (select id from products where sku = 'APR-A')
       and price_condition_id = (select id from price_conditions where name = 'APR 9 cuotas -20%')
       and active = true),
  'AUTO',
  'J2: y esa fila nace AUTO'
);

select create_price_condition(
  p_name := 'APR sin porcentaje',
  p_discount_percent := null,
  p_requires_billing := false,
  p_location_codes := array[]::text[],
  p_available_web := true,
  p_active := true,
  p_copy_prices_from_code := 'LIST',
  p_priority := 11
);
select is(
  (select discount_percent from price_conditions where name = 'APR sin porcentaje'),
  null,
  'J3: create_price_condition sin % (NULL explícito) crea la condición con discount_percent NULL de verdad'
);
select is(
  (select pricing_mode from product_prices
     where product_id = (select id from products where sku = 'APR-A')
       and price_condition_id = (select id from price_conditions where name = 'APR sin porcentaje')
       and active = true),
  'MANUAL',
  'J4: y SIN % usa el camino preexistente — copia el precio de Lista tal cual, como MANUAL (nunca genera AUTO sin %)'
);

-- ---------------------------------------------------------------------------
-- K. Transición % no-nulo -> NULL (cierra AUTO, preserva MANUAL) y NULL -> %.
-- ---------------------------------------------------------------------------
-- Estado antes de este bloque: APR-PC15 (15%, activa). APR-A es AUTO ($112.000
-- por la reactivación/recalc de D1 y F/G de arriba — recalculamos explícito
-- para dejar el escenario limpio) y le agregamos un segundo producto MANUAL.
select update_price_condition(
  p_price_condition_id := (select id from price_conditions where code = 'APR-PC15'),
  p_name := 'Condición de prueba 15%',
  p_discount_percent := 0.15,
  p_requires_billing := false,
  p_priority := 50,
  p_active := true,
  p_location_codes := array[]::text[],
  p_available_web := true
);
select save_price_matrix_changes(
  p_manual_overrides := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-B'),
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15'),
    'amount', 77777
  ))
);
select ok(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true) = 'AUTO',
  'K0: setup — APR-A sigue AUTO bajo APR-PC15'
);

select update_price_condition(
  p_price_condition_id := (select id from price_conditions where code = 'APR-PC15'),
  p_name := 'Condición de prueba 15%',
  p_discount_percent := null,
  p_requires_billing := false,
  p_priority := 50,
  p_active := true,
  p_location_codes := array[]::text[],
  p_available_web := true
);
select is(
  (select count(*)::int from product_prices
     where price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true and pricing_mode = 'AUTO'),
  0,
  'K1: % 15%->NULL vía update_price_condition cierra TODAS las filas AUTO vigentes de la condición'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  77777::numeric,
  'K2: la fila MANUAL de APR-B se preserva intacta ante la misma transición'
);
select is(
  (select count(*)::int from product_prices
     where product_id = (select id from products where sku = 'APR-A')
       and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  0,
  'K3: y no se crea ningún AUTO nuevo para APR-A — queda sin precio vigente bajo esa condición hasta que vuelva a tener %'
);

select update_price_condition(
  p_price_condition_id := (select id from price_conditions where code = 'APR-PC15'),
  p_name := 'Condición de prueba 15%',
  p_discount_percent := 0.30,
  p_requires_billing := false,
  p_priority := 50,
  p_active := true,
  p_location_codes := array[]::text[],
  p_available_web := true
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  98000::numeric,
  'K4: NULL->30% vía update_price_condition vuelve a generar AUTO para APR-A (Lista $140.000 -> $98.000), sin tocar el MANUAL de APR-B'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  77777::numeric,
  'K5: APR-B sigue MANUAL en $77.777 — update_price_condition nunca lo tocó'
);

-- ---------------------------------------------------------------------------
-- L. Reactivación (active false->true) sincroniza AUTO sin tocar MANUAL.
-- ---------------------------------------------------------------------------
select update_price_condition(
  p_price_condition_id := (select id from price_conditions where code = 'APR-PC15'),
  p_name := 'Condición de prueba 15%', p_discount_percent := 0.30, p_requires_billing := false,
  p_priority := 50, p_active := false, p_location_codes := array[]::text[], p_available_web := true
);
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-A'), 'amount', 200000
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  98000::numeric,
  'L1: con APR-PC15 inactiva, cambiar Lista de APR-A no la recalcula (sigue $98.000, stale)'
);
select update_price_condition(
  p_price_condition_id := (select id from price_conditions where code = 'APR-PC15'),
  p_name := 'Condición de prueba 15%', p_discount_percent := 0.30, p_requires_billing := false,
  p_priority := 50, p_active := true, p_location_codes := array[]::text[], p_available_web := true
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  140000::numeric,
  'L2: reactivar (false->true) sincroniza AUTO con la Lista vigente ($200.000, 30% -> $140.000), aunque el % no cambió'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  77777::numeric,
  'L3: y el MANUAL de APR-B sigue intacto tras la reactivación'
);

-- ---------------------------------------------------------------------------
-- M. QUANTITY nunca participa (ni aunque tuviera % y estuviera activa).
-- ---------------------------------------------------------------------------
insert into public.price_conditions (code, name, rule_type, min_units, discount_percent, priority, combinable, active)
values ('APR-QTY', 'Cantidad de prueba', 'QUANTITY', 5, 0.50, 60, false, true);
-- Dispara la cascada por el camino público (el helper nunca es invocable
-- directamente, ver sección N) cambiando la Lista de APR-A — toca a TODAS
-- las condiciones PAYMENT_METHOD elegibles, así que si el filtro de
-- rule_type fuera laxo (ej. <> 'BASE'), APR-QTY recibiría una fila acá.
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-A'), 'amount', 210000
  ))
);
select is(
  (select count(*)::int from product_prices where price_condition_id = (select id from price_conditions where code = 'APR-QTY')),
  0,
  'M1: una condición QUANTITY activa con % configurado NUNCA recibe filas de product_prices vía el helper (rule_type exacto PAYMENT_METHOD, nunca <> BASE)'
);

-- ---------------------------------------------------------------------------
-- O. Borrado de precios (p_clears) — mismo mecanismo que clear_product_price,
-- nunca inserta una fila nueva, nunca $0.
-- ---------------------------------------------------------------------------
select save_price_matrix_changes(
  p_clears := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-B'),
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15')
  ))
);
select is(
  (select count(*)::int from product_prices
     where product_id = (select id from products where sku = 'APR-B')
       and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  0,
  'O1: p_clears cierra la vigencia activa sin insertar ninguna fila nueva (nunca $0)'
);

-- ---------------------------------------------------------------------------
-- N. Helper interno — no ejecutable por PUBLIC/anon/authenticated directamente.
-- ---------------------------------------------------------------------------
select throws_ok(
  $$select fn_recalculate_auto_prices(array[]::uuid[], array[]::uuid[], now())$$,
  'N1: fn_recalculate_auto_prices no es ejecutable directamente por un admin autenticado (sin grant explícito) — solo invocable desde otra función de este esquema'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'aae00000-0000-0000-0000-000000000001', false);

select * from finish();
rollback;
