-- pgTAP: fix de producción — colisión de transfer_number
-- (20260201000077_transfer_number_concurrency_and_idempotency.sql).
--
-- Causa original: to_char(now(), 'YYYYMMDD') formatea en el TimeZone de la
-- SESIÓN (UTC), mientras el conteo "select count(*)+1" agrupaba por
-- America/Argentina/Buenos_Aires -- entre las 21:00 y 23:59 hora Argentina
-- el string ya mostraba la fecha UTC del día siguiente mientras el conteo
-- seguía agrupando por el día argentino anterior, permitiendo que dos
-- transferencias distintas calcularan el mismo v_seq para el mismo string.
--
-- Fix: fn_next_transfer_number() usa un contador atómico por día
-- (stock_transfer_number_counters, INSERT ... ON CONFLICT ... DO UPDATE ...
-- RETURNING, mismo patrón que fn_next_sale_number) con el día calculado UNA
-- sola vez en America/Argentina/Buenos_Aires -- se usa igual para la clave
-- del contador y para el string formateado, eliminando el desajuste de raíz.
--
-- Casos, en orden:
--   1) Transferencias consecutivas (mismo día) obtienen transfer_number
--      secuencial sin colisión, formato TRF-YYYYMMDD-NNNN preservado.
--   2) fn_next_transfer_number: dos invocaciones con un p_at que cae en la
--      ventana horaria del bug original (23:30 y 00:10 hora Argentina,
--      cruzando medianoche) resuelven días argentinos DISTINTOS y nunca
--      colisionan -- bajo la lógica vieja, ambos strings habrían sido
--      "20260316" (mismo día UTC) pudiendo colisionar en el mismo v_seq.
--   3) fn_next_transfer_number: dos invocaciones con el MISMO p_at (mismo
--      "instante" -- dos transferencias confirmadas en el mismo segundo)
--      resuelven el mismo día y v_seq consecutivos (1, 2) -- nunca el mismo
--      número.
--   4) Idempotencia: la misma p_idempotency_key enviada dos veces devuelve
--      la MISMA transferencia (idempotent_replay=true en el 2do llamado),
--      sin duplicar stock_transfer_items/stock_movements ni mover el
--      inventario una segunda vez.
--   5) Sin idempotency_key (NULL): dos llamados NUNCA se deduplican entre
--      sí -- NULL no colisiona con NULL bajo el unique constraint.
--   6) Transferencia fallida (stock insuficiente) con idempotency_key: no
--      altera inventory_balances/stock_transfers/stock_movements, y la
--      clave queda libre -- un reintento posterior con la MISMA clave y una
--      cantidad válida sí se confirma (la falla no "quema" la idempotencia).
--
-- (El grant hardening de fn_next_transfer_number -- PUBLIC/anon/authenticated
-- sin EXECUTE -- se cubre junto con el resto de los helpers internos en
-- internal_functions_grant_hardening.test.sql, mismo patrón que
-- fn_next_sale_number.)
-- Nota sobre concurrencia real: pgTAP corre en una única transacción/conexión
-- secuencial, así que no puede ejercer la rama `exception when
-- unique_violation` de transfer_stock (dos sesiones insertando con la misma
-- idempotency_key en el mismo instante). Esa rama se verificó por lectura de
-- código (replica el patrón ya usado en el resto del sistema) y queda
-- documentada para un harness externo multi-conexión si se quiere evidencia
-- empírica adicional; los casos 4-6 de este archivo sí verifican, de forma
-- determinística, el comportamiento observable de la idempotencia (la rama
-- del pre-check, que es la que cubre el escenario reportado: doble clic o
-- reintento de red).
--
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(21);

insert into auth.users (id, email) values
  ('aa000000-0000-0000-0000-000000000077', 'admin.setup.stocktr@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'aa000000-0000-0000-0000-000000000077';
insert into public.profile_locations (profile_id, location_id)
  select 'aa000000-0000-0000-0000-000000000077', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'aa000000-0000-0000-0000-000000000077', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('STKTR-A', 'Producto Transfer Concurrencia A', 'product', 'Test', true, true, false, true),
  ('STKTR-B', 'Producto Transfer Concurrencia B', 'product', 'Test', true, true, false, true);

select set_product_price((select id from products where sku = 'STKTR-A'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'STKTR-A'), (select id from price_conditions where code = 'CASH'), 4500);
select set_product_price((select id from products where sku = 'STKTR-B'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'STKTR-B'), (select id from price_conditions where code = 'CASH'), 4500);

select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'STKTR-A'), 50, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'STKTR-B'), 5, 'RECEPTION');

select id as sed25_id from stock_locations where code = 'SED-25' \gset
select id as sed37_id from stock_locations where code = 'SED-37' \gset
select id as a_id from products where sku = 'STKTR-A' \gset
select id as b_id from products where sku = 'STKTR-B' \gset

-- ===========================================================================
-- Caso 1: transferencias consecutivas, mismo día, secuenciales, sin colisión.
-- ===========================================================================
select (transfer_stock(:'sed25_id'::uuid, :'sed37_id'::uuid, jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1))) ->> 'transfer_number') as tn1 \gset
select (transfer_stock(:'sed25_id'::uuid, :'sed37_id'::uuid, jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1))) ->> 'transfer_number') as tn2 \gset
select (transfer_stock(:'sed25_id'::uuid, :'sed37_id'::uuid, jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1))) ->> 'transfer_number') as tn3 \gset

select isnt(:'tn1'::text, :'tn2'::text, 'Caso 1a: dos transferencias consecutivas nunca comparten transfer_number');
select isnt(:'tn2'::text, :'tn3'::text, 'Caso 1b: tres transferencias consecutivas nunca comparten transfer_number (par 2-3)');
select isnt(:'tn1'::text, :'tn3'::text, 'Caso 1c: tres transferencias consecutivas nunca comparten transfer_number (par 1-3)');
select ok(:'tn1'::text ~ '^TRF-\d{8}-\d{4}$', 'Caso 1d: formato TRF-YYYYMMDD-NNNN preservado');
select is(
  (regexp_replace(:'tn2', '^TRF-\d{8}-', ''))::int - (regexp_replace(:'tn1', '^TRF-\d{8}-', ''))::int,
  1,
  'Caso 1e: el correlativo avanza de a 1 entre transferencias consecutivas del mismo día'
);

-- ===========================================================================
-- Caso 2: fn_next_transfer_number -- ventana horaria del bug original
-- (23:30 y 00:10 hora Argentina, cruzando medianoche) resuelve días
-- argentinos distintos -- bajo el bug viejo, ambos to_char(now(), ...)
-- habrían sido "20260316" (mismo día UTC) pudiendo colisionar.
--
-- fn_next_transfer_number es un helper interno (revocado de authenticated)
-- -- se invoca directo acá con `reset role` (vuelve al superusuario de la
-- sesión), tal como lo haría transfer_stock al correr como SECURITY DEFINER.
-- ===========================================================================
reset role;
select is(
  fn_next_transfer_number('2026-03-15 23:30:00-03'::timestamptz),
  'TRF-20260315-0001',
  'Caso 2a: 23:30 hora Argentina del 15/03 resuelve día argentino 15/03 (no el 16/03 en UTC)'
);
select is(
  fn_next_transfer_number('2026-03-16 00:10:00-03'::timestamptz),
  'TRF-20260316-0001',
  'Caso 2b: 00:10 hora Argentina del 16/03 (40 min después) resuelve día argentino 16/03 -- '
  'contador propio, nunca colisiona con el de 2a aunque el bug viejo los hubiera impreso igual'
);

-- ===========================================================================
-- Caso 3: dos invocaciones con el MISMO instante (dos transferencias
-- confirmadas en el mismo segundo) -- mismo día, v_seq consecutivos.
-- ===========================================================================
select is(
  fn_next_transfer_number('2026-05-01 10:00:00-03'::timestamptz),
  'TRF-20260501-0001',
  'Caso 3a: primera invocación con un instante nuevo arranca en 0001'
);
select is(
  fn_next_transfer_number('2026-05-01 10:00:00-03'::timestamptz),
  'TRF-20260501-0002',
  'Caso 3b: segunda invocación con el MISMO instante nunca repite -- el contador por día avanza igual'
);
set role authenticated;

-- ===========================================================================
-- Caso 4: idempotencia -- misma clave, mismo resultado, sin duplicar stock.
-- ===========================================================================
select gen_random_uuid() as idem_key_ok \gset

select quantity as before_a from inventory_balances where location_id = :'sed25_id'::uuid and product_id = :'a_id'::uuid \gset
select (transfer_stock(:'sed25_id'::uuid, :'sed37_id'::uuid, jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)), null, :'idem_key_ok'::uuid)) as r1 \gset

select is(
  (:'r1'::jsonb ->> 'idempotent_replay')::boolean,
  null::boolean,
  'Caso 4a: el primer llamado con una clave nueva NO es un replay (no trae la propiedad)'
);

select (transfer_stock(:'sed25_id'::uuid, :'sed37_id'::uuid, jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)), null, :'idem_key_ok'::uuid)) as r2 \gset

select is(
  (:'r2'::jsonb ->> 'transfer_id'),
  (:'r1'::jsonb ->> 'transfer_id'),
  'Caso 4b: reenviar la MISMA idempotency_key devuelve el mismo transfer_id (no crea una fila nueva)'
);
select is(
  (:'r2'::jsonb ->> 'transfer_number'),
  (:'r1'::jsonb ->> 'transfer_number'),
  'Caso 4c: reenviar la MISMA idempotency_key devuelve el mismo transfer_number'
);
select is(
  (:'r2'::jsonb ->> 'idempotent_replay')::boolean,
  true,
  'Caso 4d: el reenvío se marca explícitamente como idempotent_replay=true'
);
select is(
  (select count(*) from stock_transfers where idempotency_key = :'idem_key_ok'::uuid),
  1::bigint,
  'Caso 4e: la clave de idempotencia solo generó UNA fila en stock_transfers, nunca dos'
);
select is(
  (select quantity from inventory_balances where location_id = :'sed25_id'::uuid and product_id = :'a_id'::uuid),
  :'before_a'::numeric - 1,
  'Caso 4f: el stock de origen se descontó una sola vez (1 unidad), no dos, a pesar del reenvío'
);

-- ===========================================================================
-- Caso 5: sin idempotency_key (NULL) -- nunca se deduplican entre sí.
-- ===========================================================================
select (transfer_stock(:'sed25_id'::uuid, :'sed37_id'::uuid, jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1))) ->> 'transfer_id') as null_tid1 \gset
select (transfer_stock(:'sed25_id'::uuid, :'sed37_id'::uuid, jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1))) ->> 'transfer_id') as null_tid2 \gset

select isnt(
  :'null_tid1'::text, :'null_tid2'::text,
  'Caso 5: sin idempotency_key, dos transferencias idénticas en contenido generan transfer_id distintos (NULL nunca colisiona con NULL)'
);

-- ===========================================================================
-- Caso 6: transferencia fallida (stock insuficiente) con idempotency_key --
-- no toca stock ni consume la clave; un reintento válido con la MISMA clave
-- después sí se confirma.
-- ===========================================================================
select gen_random_uuid() as idem_key_fail \gset
select quantity as before_b from inventory_balances where location_id = :'sed25_id'::uuid and product_id = :'b_id'::uuid \gset
select count(*) as transfers_before from stock_transfers \gset
select count(*) as movements_before from stock_movements \gset

select throws_ok(
  format(
    $$select transfer_stock('%s'::uuid, '%s'::uuid, jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 999)), null, '%s'::uuid)$$,
    :'sed25_id', :'sed37_id', :'b_id', :'idem_key_fail'
  ),
  'Caso 6a: transferir más que el disponible (999 contra 5) se rechaza, aunque lleve idempotency_key'
);

select is(
  (select quantity from inventory_balances where location_id = :'sed25_id'::uuid and product_id = :'b_id'::uuid),
  :'before_b'::numeric,
  'Caso 6b: la transferencia fallida no altera inventory_balances de origen'
);
select is(
  (select count(*) from stock_transfers),
  :'transfers_before'::bigint,
  'Caso 6c: la transferencia fallida no deja ninguna fila nueva en stock_transfers'
);
select is(
  (select count(*) from stock_movements),
  :'movements_before'::bigint,
  'Caso 6d: la transferencia fallida no deja ningún movimiento nuevo en stock_movements'
);

select lives_ok(
  format(
    $$select transfer_stock('%s'::uuid, '%s'::uuid, jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 2)), null, '%s'::uuid)$$,
    :'sed25_id', :'sed37_id', :'b_id', :'idem_key_fail'
  ),
  'Caso 6e: la MISMA idempotency_key de un intento fallido queda libre -- un reintento válido después se confirma normalmente'
);

select * from finish();
rollback;
