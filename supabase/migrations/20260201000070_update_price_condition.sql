-- =============================================================================
-- Maguirejuve · 70 · update_price_condition — edición atómica (Checkpoint 2)
-- =============================================================================
-- Checkpoint 1 (migración 69) dejó create_price_condition() pero ninguna
-- operación equivalente para EDITAR una condición ya existente. Editar hoy
-- tocaría 4 tablas por separado desde el frontend (price_conditions,
-- payment_methods, price_condition_locations, price_condition_sales_channels)
-- — una cadena de updates independientes podría dejar una configuración a
-- medio aplicar si algo falla en el medio. Se agrega acá, en una migración
-- nueva (no se toca la 069 ya aprobada, para conservar trazabilidad), la
-- misma estrategia de atomicidad: toda la lógica en una función plpgsql =
-- una sola transacción con la llamada, cualquier excepción revierte todo.
--
-- Sincronía nombre/activo entre payment_methods y price_conditions:
-- create_price_condition() (069) ya crea ambas filas con el MISMO nombre y
-- el MISMO active — deliberado, porque el formulario admin expone "esto"
-- como una única "Condición de precio" (sección 6 del pedido: "no quiero
-- exponer la separación técnica payment_method + price_condition como dos
-- pasos administrativos"). Si la edición solo tocara price_conditions.name/
-- active, quedarían desincronizadas: el Dashboard etiqueta
-- revenue_by_payment_method por payment_methods.name (confirmado en
-- card6_installments.test.sql, Caso 18) y Nueva Venta filtra su dropdown de
-- medios de pago por payment_methods.active (confirmado en
-- app/(app)/ventas/nueva/page.tsx) — una condición desactivada acá pero con
-- payment_methods.active todavía true seguiría apareciendo seleccionable en
-- Nueva Venta y fallaría recién adentro de fn_pricing_quote con un mensaje
-- confuso, en vez de no aparecer directamente. Por eso update_price_condition
-- actualiza SIEMPRE ambas filas en lockstep (nombre y activo), igual que ya
-- hace create_price_condition al crearlas.
--
-- Lo que NUNCA toca (sección 9/12 del pedido): code de payment_methods ni de
-- price_conditions, rule_type, payment_method_id (identidad interna), ni
-- ningún precio en product_prices — los precios se administran
-- exclusivamente desde /admin/precios (matriz), vía set_product_price, ya
-- genérica desde antes de este feature.
--
-- Bloqueo real descubierto al diseñar el formulario "Nueva condición"
-- (Checkpoint 2, sección 6 del pedido): el wireframe pide un campo
-- "Prioridad" editable en el alta, pero create_price_condition() (069) no
-- lo expone — auto-calcula la prioridad (justo arriba de LIST) sin dejar
-- elegir un valor explícito. Se agrega acá p_priority como parámetro
-- OPCIONAL nuevo, al final de la firma (compatible hacia atrás: cualquier
-- llamada existente sin este argumento sigue funcionando igual, con el
-- mismo auto-cálculo de siempre) — CREATE OR REPLACE en esta migración
-- nueva, sin tocar el archivo de la 069. Mismo criterio de "redefinir sin
-- tocar el archivo aprobado" que ya se usa en el resto del proyecto para
-- iterar sobre una función existente entre migraciones (mismo patrón que
-- 20260201000005_free_sale_engine.sql usó para fn_pricing_quote).
--
-- DROP explícito antes del CREATE OR REPLACE: Postgres identifica funciones
-- por firma exacta de parámetros — agregar p_priority al final NO reemplaza
-- la versión de 7 parámetros de la 069, crea un OVERLOAD nuevo (ambigüedad
-- real: con las dos firmas vigentes, una llamada de 7 argumentos podría
-- resolver contra cualquiera de las dos). Sin el DROP, la versión vieja
-- seguiría viva y alcanzable.
-- ---------------------------------------------------------------------------
drop function if exists public.create_price_condition(text, numeric, boolean, text[], boolean, boolean, text);

create or replace function public.create_price_condition(
  p_name text,
  p_discount_percent numeric,
  p_requires_billing boolean,
  p_location_codes text[],
  p_available_web boolean,
  p_active boolean default true,
  p_copy_prices_from_code text default 'LIST',
  p_priority int default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment_method_id uuid;
  v_price_condition_id uuid;
  v_payment_method_code text;
  v_price_condition_code text;
  v_list_priority int;
  v_new_priority int;
  v_source_condition_id uuid;
  v_copied_count int := 0;
  v_skipped_products jsonb := '[]'::jsonb;
  v_invalid_codes text[];
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede crear una condición de precio.';
  end if;

  if p_name is null or trim(p_name) = '' then
    raise exception 'El nombre de la condición es obligatorio.';
  end if;

  if p_discount_percent is not null and (p_discount_percent < 0 or p_discount_percent > 1) then
    raise exception 'El porcentaje informativo tiene que estar entre 0%% y 100%%.';
  end if;

  select array_agg(u.loc_code) into v_invalid_codes
  from unnest(coalesce(p_location_codes, array[]::text[])) as u(loc_code)
  where not exists (
    select 1 from public.stock_locations sl where sl.code = u.loc_code and sl.type = 'branch'
  );
  if v_invalid_codes is not null and array_length(v_invalid_codes, 1) > 0 then
    raise exception 'Sede desconocida: %.', array_to_string(v_invalid_codes, ', ');
  end if;

  select id into v_source_condition_id
  from public.price_conditions
  where code = p_copy_prices_from_code and active;
  if v_source_condition_id is null then
    raise exception 'La condición de origen para copiar precios (%) no existe o está inactiva.', p_copy_prices_from_code;
  end if;

  v_payment_method_code := 'PM-' || replace(gen_random_uuid()::text, '-', '');
  v_price_condition_code := 'PC-' || replace(gen_random_uuid()::text, '-', '');

  insert into public.payment_methods (code, name, active, requires_billing, sort_order)
  values (
    v_payment_method_code, p_name, p_active, coalesce(p_requires_billing, false),
    coalesce((select max(sort_order) + 1 from public.payment_methods), 1)
  )
  returning id into v_payment_method_id;

  select priority into v_list_priority from public.price_conditions where code = 'LIST';
  if p_priority is not null then
    -- Prioridad explícita del formulario: se respeta tal cual, sin tocar la
    -- de LIST ni la de ninguna otra condición (a diferencia del
    -- auto-cálculo de abajo, que sí corre a LIST un lugar para siempre
    -- dejar la condición nueva justo arriba). Puede coincidir con la de
    -- otra fila — price_conditions.priority no tiene unicidad, el desempate
    -- en fn_pricing_quote ya es determinístico por id.
    v_new_priority := p_priority;
  else
    v_new_priority := coalesce(v_list_priority, 100);
    update public.price_conditions set priority = priority + 1 where code = 'LIST';
  end if;

  insert into public.price_conditions (
    code, name, rule_type, payment_method_id, discount_percent, priority, combinable, active
  ) values (
    v_price_condition_code, p_name, 'PAYMENT_METHOD', v_payment_method_id,
    coalesce(p_discount_percent, 0), v_new_priority, false, p_active
  )
  returning id into v_price_condition_id;

  insert into public.price_condition_locations (price_condition_id, location_id)
  select v_price_condition_id, sl.id
  from public.stock_locations sl
  where sl.code = any(coalesce(p_location_codes, array[]::text[])) and sl.type = 'branch';

  if p_available_web then
    insert into public.price_condition_sales_channels (price_condition_id, sales_channel_id)
    select v_price_condition_id, sc.id from public.sales_channels sc where sc.code = 'WEB';
  end if;

  with copied as (
    insert into public.product_prices (product_id, price_condition_id, amount, valid_from)
    select pp.product_id, v_price_condition_id, pp.amount, now()
    from public.product_prices pp
    where pp.price_condition_id = v_source_condition_id
      and pp.active = true
      and (pp.valid_until is null or pp.valid_until > now())
    returning product_id
  )
  select count(*) into v_copied_count from copied;

  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'sku', p.sku, 'name', p.name)), '[]'::jsonb)
  into v_skipped_products
  from public.products p
  where p.active
    and not exists (
      select 1 from public.product_prices pp
      where pp.product_id = p.id
        and pp.price_condition_id = v_source_condition_id
        and pp.active = true
        and (pp.valid_until is null or pp.valid_until > now())
    );

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'PRICE_CONDITION_CREATED', 'price_conditions', v_price_condition_id,
    jsonb_build_object(
      'name', p_name,
      'payment_method_id', v_payment_method_id,
      'requires_billing', coalesce(p_requires_billing, false),
      'location_codes', p_location_codes,
      'available_web', coalesce(p_available_web, false),
      'copied_prices_from', p_copy_prices_from_code,
      'copied_count', v_copied_count,
      'skipped_count', jsonb_array_length(v_skipped_products),
      'priority', v_new_priority
    )
  );

  return jsonb_build_object(
    'price_condition_id', v_price_condition_id,
    'payment_method_id', v_payment_method_id,
    'price_condition_code', v_price_condition_code,
    'payment_method_code', v_payment_method_code,
    'copied_prices_count', v_copied_count,
    'skipped_products', v_skipped_products
  );
end;
$$;

comment on function public.create_price_condition(text, numeric, boolean, text[], boolean, boolean, text, int) is
  'Crea una condición de precio administrable completa en una sola operación atómica: '
  'payment_method + price_condition + disponibilidad (sedes/Web) + product_prices iniciales '
  '(copiados de la condición de origen, LIST por defecto). p_priority opcional (migración 70): si '
  'se pasa, se respeta tal cual; si no, se auto-calcula justo arriba de LIST (comportamiento '
  'original de la migración 69, preservado para compatibilidad). Toda la función corre en la misma '
  'transacción que la llamada — cualquier excepción revierte todo. Códigos técnicos autogenerados '
  '(gen_random_uuid()), nunca a partir del nombre. Solo admin (is_admin()).';

grant execute on function public.create_price_condition(text, numeric, boolean, text[], boolean, boolean, text, int) to authenticated;

create or replace function public.update_price_condition(
  p_price_condition_id uuid,
  p_name text,
  p_discount_percent numeric,
  p_requires_billing boolean,
  p_priority int,
  p_active boolean,
  p_location_codes text[],
  p_available_web boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment_method_id uuid;
  v_invalid_codes text[];
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede editar una condición de precio.';
  end if;

  select payment_method_id into v_payment_method_id
  from public.price_conditions
  where id = p_price_condition_id;

  if v_payment_method_id is null then
    -- Cubre tanto "no existe" como "es la condición BASE (LIST)" —
    -- deliberadamente no editable desde acá: no tiene payment_method_id,
    -- no tiene disponibilidad ni requires_billing en el sentido de este
    -- formulario (es el fallback universal, se administra aparte si hiciera
    -- falta, nunca desde "Nueva condición"/"Editar condición").
    raise exception 'La condición no existe o no es editable desde acá (ej. la condición Lista/BASE).';
  end if;

  if p_name is null or trim(p_name) = '' then
    raise exception 'El nombre de la condición es obligatorio.';
  end if;

  if p_discount_percent is not null and (p_discount_percent < 0 or p_discount_percent > 1) then
    raise exception 'El porcentaje informativo tiene que estar entre 0%% y 100%%.';
  end if;

  select array_agg(u.loc_code) into v_invalid_codes
  from unnest(coalesce(p_location_codes, array[]::text[])) as u(loc_code)
  where not exists (
    select 1 from public.stock_locations sl where sl.code = u.loc_code and sl.type = 'branch'
  );
  if v_invalid_codes is not null and array_length(v_invalid_codes, 1) > 0 then
    raise exception 'Sede desconocida: %.', array_to_string(v_invalid_codes, ', ');
  end if;

  update public.price_conditions
  set name = p_name,
    discount_percent = coalesce(p_discount_percent, 0),
    priority = p_priority,
    active = p_active
  where id = p_price_condition_id;

  -- Lockstep con payment_methods — ver comentario de cabecera.
  update public.payment_methods
  set name = p_name,
    requires_billing = coalesce(p_requires_billing, false),
    active = p_active
  where id = v_payment_method_id;

  -- Disponibilidad: reemplazo completo (delete + insert), mismo patrón que
  -- set_promotion_payment_methods — nunca un diff incremental frágil.
  delete from public.price_condition_locations where price_condition_id = p_price_condition_id;
  insert into public.price_condition_locations (price_condition_id, location_id)
  select p_price_condition_id, sl.id
  from public.stock_locations sl
  where sl.code = any(coalesce(p_location_codes, array[]::text[])) and sl.type = 'branch';

  delete from public.price_condition_sales_channels where price_condition_id = p_price_condition_id;
  if p_available_web then
    insert into public.price_condition_sales_channels (price_condition_id, sales_channel_id)
    select p_price_condition_id, sc.id from public.sales_channels sc where sc.code = 'WEB';
  end if;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'PRICE_CONDITION_UPDATED', 'price_conditions', p_price_condition_id,
    jsonb_build_object(
      'name', p_name,
      'requires_billing', coalesce(p_requires_billing, false),
      'active', p_active,
      'priority', p_priority,
      'location_codes', p_location_codes,
      'available_web', coalesce(p_available_web, false)
    )
  );

  return jsonb_build_object(
    'price_condition_id', p_price_condition_id,
    'payment_method_id', v_payment_method_id
  );
end;
$$;

comment on function public.update_price_condition(uuid, text, numeric, boolean, int, boolean, text[], boolean) is
  'Edita una condición de precio existente en una sola operación atómica: price_conditions '
  '(nombre/%/prioridad/activa) + payment_methods (nombre/requires_billing/activa, en lockstep — '
  'ver comentario de cabecera del archivo) + disponibilidad (reemplazo completo). Nunca toca code, '
  'rule_type, payment_method_id ni ningún precio en product_prices (eso es exclusivo de '
  'set_product_price / la matriz). No editable para la condición BASE/LIST. Solo admin (is_admin()).';

grant execute on function public.update_price_condition(uuid, text, numeric, boolean, int, boolean, text[], boolean) to authenticated;
