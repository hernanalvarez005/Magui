-- =============================================================================
-- Maguirejuve · 73 · visible_in_price_lookup — visibilidad en /precios
-- =============================================================================
-- Nuevo requerimiento: Administración necesita poder elegir qué condiciones
-- aparecen en /precios (consulta de precios para vendedoras) SIN desactivar
-- la condición para ventas — hoy la única forma de sacar algo de /precios es
-- active=false, que también la saca de Nueva Venta, de la Matriz y de
-- disponibilidad. Son dos ejes independientes: "¿se puede vender con esto?"
-- (active) vs. "¿aparece en la pantalla de consulta de precios?"
-- (visible_in_price_lookup, nuevo). No se reutiliza active.
--
-- default true: toda condición existente (CASH, TRANSFER, CARD_1/3/6,
-- "2 cuotas sin interés", y cualquier otra ya creada) sigue viéndose en
-- /precios exactamente igual que antes de esta migración — cambio no
-- disruptivo, sin backfill adicional necesario.
--
-- BASE (Lista) queda deliberadamente afuera de este control: ya estaba
-- excluida de toda edición por update_price_condition (comentario de
-- cabecera de la migración 70 — "no editable desde acá... se administra
-- aparte") porque no tiene payment_method_id. No se agrega aquí ninguna vía
-- para que BASE se oculte: el filtro de /precios (ver cambio de frontend)
-- trata rule_type='BASE' como siempre visible, sin leer esta columna para
-- ese caso — es el precio de referencia que usa todo el sistema de pricing,
-- nunca tiene sentido esconderlo.
-- =============================================================================

alter table public.price_conditions
  add column visible_in_price_lookup boolean not null default true;

comment on column public.price_conditions.visible_in_price_lookup is
  'Si la condición aparece en /precios (consulta de precios de vendedoras). Independiente de '
  'active: una condición puede seguir siendo vendible (active=true) y estar oculta acá. BASE '
  '(Lista) ignora esta columna en la práctica — el frontend siempre la muestra en /precios sin '
  'importar su valor, no tiene sentido ocultar el precio de referencia. Solo admin la cambia, vía '
  'create_price_condition/update_price_condition (nunca escritura directa desde el cliente).';

-- ---------------------------------------------------------------------------
-- create_price_condition: agrega p_visible_in_price_lookup, default true
-- (toda condición nueva nace visible salvo que el admin la oculte al
-- crearla). DROP explícito: agregar un parámetro al final crea un overload
-- nuevo si no se saca la firma vieja (mismo motivo documentado en la
-- migración 70 para p_priority).
-- ---------------------------------------------------------------------------
drop function if exists public.create_price_condition(text, numeric, boolean, text[], boolean, boolean, text, int);

create or replace function public.create_price_condition(
  p_name text,
  p_discount_percent numeric,
  p_requires_billing boolean,
  p_location_codes text[],
  p_available_web boolean,
  p_active boolean default true,
  p_copy_prices_from_code text default 'LIST',
  p_priority int default null,
  p_visible_in_price_lookup boolean default true
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
    v_new_priority := p_priority;
  else
    v_new_priority := coalesce(v_list_priority, 100);
    update public.price_conditions set priority = priority + 1 where code = 'LIST';
  end if;

  insert into public.price_conditions (
    code, name, rule_type, payment_method_id, discount_percent, priority, combinable, active,
    visible_in_price_lookup
  ) values (
    v_price_condition_code, p_name, 'PAYMENT_METHOD', v_payment_method_id,
    coalesce(p_discount_percent, 0), v_new_priority, false, p_active,
    coalesce(p_visible_in_price_lookup, true)
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
      'priority', v_new_priority,
      'visible_in_price_lookup', coalesce(p_visible_in_price_lookup, true)
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

comment on function public.create_price_condition(text, numeric, boolean, text[], boolean, boolean, text, int, boolean) is
  'Crea una condición de precio administrable completa en una sola operación atómica: '
  'payment_method + price_condition + disponibilidad (sedes/Web) + product_prices iniciales '
  '(copiados de la condición de origen, LIST por defecto). p_visible_in_price_lookup (migración 73, '
  'default true): si aparece en /precios — independiente de p_active. Solo admin (is_admin()).';

-- Postgres otorga EXECUTE a PUBLIC automáticamente al crear una función
-- (a diferencia de las tablas) salvo que se revoque explícitamente — mismo
-- diagnóstico que la migración 072 ya hizo para otras 5 funciones. 069/070
-- nunca revocaron PUBLIC en create_price_condition, así que heredaba el
-- default; se corrige acá con el mismo patrón de 072 (revoke de los tres
-- roles, luego grant solo a authenticated) para que esta condición quede
-- en el mismo nivel mínimo que el resto de la suite.
revoke execute on function public.create_price_condition(text, numeric, boolean, text[], boolean, boolean, text, int, boolean) from public, authenticated, anon;
grant execute on function public.create_price_condition(text, numeric, boolean, text[], boolean, boolean, text, int, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- update_price_condition: agrega p_visible_in_price_lookup con SEMÁNTICA
-- PATCH (default null = "no tocar"), a diferencia de todos los demás
-- parámetros de esta función (reemplazo completo). Motivo: el toggle rápido
-- de "Activa" en la tabla admin (price-conditions-table.tsx) llama a esta
-- misma RPC sin saber ni necesitar saber la visibilidad actual — con
-- default true, cada toggle de "Activa" resetearía la visibilidad a true
-- por accidente. coalesce(p_visible_in_price_lookup, visible_in_price_lookup)
-- preserva el valor ya guardado cuando el parámetro no se manda.
-- ---------------------------------------------------------------------------
drop function if exists public.update_price_condition(uuid, text, numeric, boolean, int, boolean, text[], boolean);

create or replace function public.update_price_condition(
  p_price_condition_id uuid,
  p_name text,
  p_discount_percent numeric,
  p_requires_billing boolean,
  p_priority int,
  p_active boolean,
  p_location_codes text[],
  p_available_web boolean,
  p_visible_in_price_lookup boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment_method_id uuid;
  v_invalid_codes text[];
  v_visible_in_price_lookup boolean;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede editar una condición de precio.';
  end if;

  select payment_method_id into v_payment_method_id
  from public.price_conditions
  where id = p_price_condition_id;

  if v_payment_method_id is null then
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
    active = p_active,
    visible_in_price_lookup = coalesce(p_visible_in_price_lookup, visible_in_price_lookup)
  where id = p_price_condition_id
  returning visible_in_price_lookup into v_visible_in_price_lookup;

  update public.payment_methods
  set name = p_name,
    requires_billing = coalesce(p_requires_billing, false),
    active = p_active
  where id = v_payment_method_id;

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
      'available_web', coalesce(p_available_web, false),
      'visible_in_price_lookup', v_visible_in_price_lookup
    )
  );

  return jsonb_build_object(
    'price_condition_id', p_price_condition_id,
    'payment_method_id', v_payment_method_id
  );
end;
$$;

comment on function public.update_price_condition(uuid, text, numeric, boolean, int, boolean, text[], boolean, boolean) is
  'Edita una condición de precio existente en una sola operación atómica: price_conditions '
  '(nombre/%/prioridad/activa/visible_in_price_lookup) + payment_methods (en lockstep) + '
  'disponibilidad (reemplazo completo). p_visible_in_price_lookup (migración 73) es PATCH: default '
  'null preserva el valor ya guardado — nunca lo resetea un toggle de otro campo (ej. "Activa"). '
  'Nunca toca code, rule_type, payment_method_id ni ningún precio en product_prices. No editable '
  'para la condición BASE/LIST. Solo admin (is_admin()).';

-- Mismo motivo que en create_price_condition más arriba: 069/070 nunca
-- revocaron PUBLIC de esta función tampoco, así que heredaba el default de
-- Postgres. Mismo patrón de 072 (revoke de los tres roles, luego grant solo
-- a authenticated).
revoke execute on function public.update_price_condition(uuid, text, numeric, boolean, int, boolean, text[], boolean, boolean) from public, authenticated, anon;
grant execute on function public.update_price_condition(uuid, text, numeric, boolean, int, boolean, text[], boolean, boolean) to authenticated;
