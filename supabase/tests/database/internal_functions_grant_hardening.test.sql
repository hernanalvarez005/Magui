-- pgTAP: Checkpoint reproducibilidad — grants de las 5 funciones "internas"
-- (create_web_order + fn_create_sale_core/fn_apply_stock_movement/
-- fn_next_sale_number/fn_pricing_quote) tras la migración 072.
--
-- No valida que 072 CONTENGA ciertos REVOKE (eso es leer el archivo) — valida
-- el estado EFECTIVO de PostgreSQL vía has_function_privilege(), sobre una
-- base reconstruida desde cero con TODO el historial de migraciones
-- (001..072), tal como haría cualquier instalación nueva o `supabase db push`
-- contra un proyecto vacío.
--
-- Contexto: ninguna de las 5 tenía, antes de 072, una combinación de REVOKE
-- que garantizara este estado de forma reproducible desde el repo — ver el
-- comentario en la propia migración 072 para el detalle de por qué.
--
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.

begin;
select plan(16);

-- ---------------------------------------------------------------------------
-- create_web_order: única de las 5 que SÍ debe quedar ejecutable — pero
-- exclusivamente por service_role (la llama app/api/integrations/web-orders,
-- que corre con la service role key, nunca con la sesión del usuario final).
-- ---------------------------------------------------------------------------
select is(
  has_function_privilege('public', 'public.create_web_order(jsonb, uuid, uuid, text, text, uuid, uuid, text, timestamptz, public.sale_payment_status, uuid, public.sale_fulfillment_type)', 'execute'),
  false,
  'create_web_order: PUBLIC sin EXECUTE'
);
select is(
  has_function_privilege('anon', 'public.create_web_order(jsonb, uuid, uuid, text, text, uuid, uuid, text, timestamptz, public.sale_payment_status, uuid, public.sale_fulfillment_type)', 'execute'),
  false,
  'create_web_order: anon sin EXECUTE'
);
select is(
  has_function_privilege('authenticated', 'public.create_web_order(jsonb, uuid, uuid, text, text, uuid, uuid, text, timestamptz, public.sale_payment_status, uuid, public.sale_fulfillment_type)', 'execute'),
  false,
  'create_web_order: authenticated sin EXECUTE'
);
select is(
  has_function_privilege('service_role', 'public.create_web_order(jsonb, uuid, uuid, text, text, uuid, uuid, text, timestamptz, public.sale_payment_status, uuid, public.sale_fulfillment_type)', 'execute'),
  true,
  'create_web_order: service_role SÍ tiene EXECUTE'
);

-- ---------------------------------------------------------------------------
-- fn_create_sale_core: helper interno — solo se llama desde otras funciones
-- SECURITY DEFINER (create_sale, create_web_order, create_sale_exchange),
-- nunca directo por RPC HTTP.
-- ---------------------------------------------------------------------------
select is(
  has_function_privilege('public', 'public.fn_create_sale_core(uuid, jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz, boolean, public.free_sale_reason, text, boolean, uuid, public.sale_fulfillment_type, public.sale_payment_status)', 'execute'),
  false,
  'fn_create_sale_core: PUBLIC sin EXECUTE'
);
select is(
  has_function_privilege('anon', 'public.fn_create_sale_core(uuid, jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz, boolean, public.free_sale_reason, text, boolean, uuid, public.sale_fulfillment_type, public.sale_payment_status)', 'execute'),
  false,
  'fn_create_sale_core: anon sin EXECUTE'
);
select is(
  has_function_privilege('authenticated', 'public.fn_create_sale_core(uuid, jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz, boolean, public.free_sale_reason, text, boolean, uuid, public.sale_fulfillment_type, public.sale_payment_status)', 'execute'),
  false,
  'fn_create_sale_core: authenticated sin EXECUTE'
);

-- ---------------------------------------------------------------------------
-- fn_apply_stock_movement: helper interno de inventario.
-- ---------------------------------------------------------------------------
select is(
  has_function_privilege('public', 'public.fn_apply_stock_movement(uuid, uuid, public.stock_movement_type, numeric, uuid, uuid, text, public.stock_adjustment_reason, text, uuid, boolean, uuid)', 'execute'),
  false,
  'fn_apply_stock_movement: PUBLIC sin EXECUTE'
);
select is(
  has_function_privilege('anon', 'public.fn_apply_stock_movement(uuid, uuid, public.stock_movement_type, numeric, uuid, uuid, text, public.stock_adjustment_reason, text, uuid, boolean, uuid)', 'execute'),
  false,
  'fn_apply_stock_movement: anon sin EXECUTE'
);
select is(
  has_function_privilege('authenticated', 'public.fn_apply_stock_movement(uuid, uuid, public.stock_movement_type, numeric, uuid, uuid, text, public.stock_adjustment_reason, text, uuid, boolean, uuid)', 'execute'),
  false,
  'fn_apply_stock_movement: authenticated sin EXECUTE'
);

-- ---------------------------------------------------------------------------
-- fn_next_sale_number: helper interno de numeración de ventas.
-- ---------------------------------------------------------------------------
select is(
  has_function_privilege('public', 'public.fn_next_sale_number(uuid, timestamptz)', 'execute'),
  false,
  'fn_next_sale_number: PUBLIC sin EXECUTE'
);
select is(
  has_function_privilege('anon', 'public.fn_next_sale_number(uuid, timestamptz)', 'execute'),
  false,
  'fn_next_sale_number: anon sin EXECUTE'
);
select is(
  has_function_privilege('authenticated', 'public.fn_next_sale_number(uuid, timestamptz)', 'execute'),
  false,
  'fn_next_sale_number: authenticated sin EXECUTE'
);

-- ---------------------------------------------------------------------------
-- fn_pricing_quote: helper interno de cotización de precios.
-- ---------------------------------------------------------------------------
select is(
  has_function_privilege('public', 'public.fn_pricing_quote(jsonb, uuid, timestamptz, boolean)', 'execute'),
  false,
  'fn_pricing_quote: PUBLIC sin EXECUTE'
);
select is(
  has_function_privilege('anon', 'public.fn_pricing_quote(jsonb, uuid, timestamptz, boolean)', 'execute'),
  false,
  'fn_pricing_quote: anon sin EXECUTE'
);
select is(
  has_function_privilege('authenticated', 'public.fn_pricing_quote(jsonb, uuid, timestamptz, boolean)', 'execute'),
  false,
  'fn_pricing_quote: authenticated sin EXECUTE'
);

select * from finish();
rollback;
