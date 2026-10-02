-- =============================================================================
-- Maguirejuve · 74 · Precio de Lista maestro — recálculo automático AUTO/MANUAL
-- =============================================================================
-- Nuevo requerimiento: Precio de Lista pasa a ser el precio maestro de cada
-- producto. Al cargar/cambiar Lista, o al cambiar el % de una condición
-- PAYMENT_METHOD, los precios de esa condición se recalculan solos
-- (precio = round(lista * (1 - %), 2)) — SIN pisar nunca un precio editado a
-- mano. Para eso cada fila de product_prices ahora declara su origen:
--   AUTO   -> la escribió el recálculo automático, sigue a Lista/% para siempre.
--   MANUAL -> la escribió un admin a mano (directo, o por "Volver a automático"
--             corrido a la inversa no existe — MANUAL nunca se genera solo).
--
-- Todo lo ya cargado en product_prices ANTES de esta migración nace MANUAL
-- (default de columna, ver más abajo) — nadie conoce el origen real de esos
-- precios, así que no hay forma segura de asumir que "seguían" a Lista/%.
-- Ningún amount/valid_from/valid_until/active existente cambia.
--
-- Alcance: nunca toca promociones, ventas históricas, disponibilidad por
-- sede/canal, visible_in_price_lookup, medios de pago, stock, facturación.
-- No modifica ninguna migración ya aplicada (continúa después de la 073).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) pricing_mode — text + CHECK (no enum de Postgres, pedido explícito).
--    ALTER TABLE ... ADD COLUMN ... DEFAULT 'MANUAL' con un default constante
--    es metadata-only en Postgres moderno: no reescribe ninguna fila, no
--    toca amount/valid_from/valid_until/active de nada ya existente. Es el
--    backfill completo — no hace falta ningún UPDATE aparte.
-- ---------------------------------------------------------------------------
alter table public.product_prices
  add column pricing_mode text not null default 'MANUAL'
  check (pricing_mode in ('AUTO', 'MANUAL'));

comment on column public.product_prices.pricing_mode is
  'AUTO: generada/actualizada por el recálculo automático (sigue a Lista y al % de la condición '
  'mientras siga AUTO). MANUAL: la escribió un admin a mano (directo, o preexistente a esta '
  'migración) — el recálculo automático nunca la toca. Pasar de MANUAL a AUTO es exclusivamente '
  '"Volver a automático" (acción explícita, por celda o en lote con preview, nunca silenciosa).';

-- ---------------------------------------------------------------------------
-- 2) fn_recalculate_auto_prices — helper interno, ÚNICA implementación del
--    algoritmo de cascada. Lo invocan create_price_condition,
--    update_price_condition y save_price_matrix_changes — ninguna de las
--    tres vuelve a escribir esta lógica por su cuenta.
--
--    p_product_ids: productos cuya Lista cambió (o null/[] si no aplica).
--    p_price_condition_ids: condiciones cuyo % cambió (o null/[] si no aplica).
--    Candidatos = UNIÓN (no cruce) de las dos direcciones: si en el mismo
--    llamado cambia la Lista del producto A Y el % de la condición X, hay que
--    recalcular A×todas-las-condiciones-elegibles Y todos-los-productos×X —
--    no solo el par (A, X).
--
--    rule_type = 'PAYMENT_METHOD' exacto (nunca <> 'BASE'): no asumimos
--    comportamiento de ningún rule_type futuro. QUANTITY (hoy desactivado,
--    migración 046) nunca participa, aunque se reactivara.
--
--    Por cada par candidato: si existe fila activa y es MANUAL -> se omite
--    (nunca se pisa). Si es AUTO, o no existe ninguna fila -> se (re)calcula
--    e inserta una fila nueva AUTO, cerrando la anterior si había.
-- ---------------------------------------------------------------------------
create or replace function public.fn_recalculate_auto_prices(
  p_product_ids uuid[],
  p_price_condition_ids uuid[],
  p_valid_from timestamptz default now()
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int := 0;
  v_pair record;
  v_existing_id uuid;
  v_existing_mode text;
  v_existing_valid_from timestamptz;
  v_effective_valid_from timestamptz;
  v_new_amount numeric(14, 2);
begin
  for v_pair in
    select distinct
      pc.id as price_condition_id,
      pc.discount_percent,
      base.product_id,
      base.list_amount
    from public.price_conditions pc
    cross join (
      select pp.product_id, pp.amount as list_amount
      from public.product_prices pp
      join public.price_conditions basepc
        on basepc.id = pp.price_condition_id and basepc.rule_type = 'BASE'
      where pp.active = true
    ) base
    where pc.rule_type = 'PAYMENT_METHOD'
      and pc.active = true
      and pc.discount_percent is not null
      and (
        base.product_id = any(coalesce(p_product_ids, array[]::uuid[]))
        or pc.id = any(coalesce(p_price_condition_ids, array[]::uuid[]))
      )
  loop
    select pp.id, pp.pricing_mode, pp.valid_from into v_existing_id, v_existing_mode, v_existing_valid_from
    from public.product_prices pp
    where pp.product_id = v_pair.product_id
      and pp.price_condition_id = v_pair.price_condition_id
      and pp.active = true;

    if v_existing_id is not null and v_existing_mode = 'MANUAL' then
      continue;
    end if;

    v_new_amount := round(v_pair.list_amount * (1 - v_pair.discount_percent), 2);
    if v_new_amount is null or v_new_amount <= 0 then
      -- Defensivo: amount > 0 es un CHECK de la tabla de todos modos — nunca
      -- debería dispararse (ya filtramos list_amount/discount_percent no
      -- nulos arriba), pero preferimos omitir en vez de dejar que la
      -- excepción del CHECK aborte toda la cascada por un caso de borde.
      continue;
    end if;

    if v_existing_id is not null then
      -- now()/p_valid_from es constante dentro de la transacción — si el
      -- mismo par ya fue tocado antes en este mismo llamado (o en la misma
      -- transacción, como puede pasar en un test), valid_from de la fila
      -- vieja puede coincidir exactamente con p_valid_from. greatest(...)
      -- garantiza valid_until > valid_from siempre (CHECK
      -- product_prices_valid_range), sin depender del reloj de pared.
      v_effective_valid_from := greatest(p_valid_from, v_existing_valid_from + interval '1 microsecond');
      update public.product_prices
        set valid_until = v_effective_valid_from, active = false
        where id = v_existing_id;
    else
      v_effective_valid_from := p_valid_from;
    end if;

    insert into public.product_prices
      (product_id, price_condition_id, amount, valid_from, pricing_mode, created_by)
    values
      (v_pair.product_id, v_pair.price_condition_id, v_new_amount, v_effective_valid_from, 'AUTO', auth.uid());

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function public.fn_recalculate_auto_prices(uuid[], uuid[], timestamptz) is
  'Helper interno — NUNCA otorgado a PUBLIC/authenticated/anon (ver revoke más abajo). Única '
  'implementación de la cascada AUTO: recalcula o crea precios AUTO para los pares producto×condición '
  'afectados por un cambio de Lista o de %, sin pisar nunca pricing_mode=MANUAL. Invocado desde '
  'create_price_condition, update_price_condition y save_price_matrix_changes.';

-- Postgres otorga EXECUTE a PUBLIC automáticamente al crear una función
-- (mismo diagnóstico que 072 y que el propio fix de la 073). Para un helper
-- que NUNCA debe ser invocable directamente por ningún cliente, no alcanza
-- con simplemente no escribir un GRANT — hay que revocar los tres roles
-- explícitamente.
revoke execute on function public.fn_recalculate_auto_prices(uuid[], uuid[], timestamptz)
  from public, authenticated, anon;

-- ---------------------------------------------------------------------------
-- 3) create_price_condition — mismo signature (9 args), CREATE OR REPLACE
--    conserva el ACL ya endurecido (grant solo a authenticated) sin volver
--    a tocarlo. Dos cambios de cuerpo:
--
--    a) discount_percent ya NO se fuerza a 0 con coalesce: una condición
--       puede nacer con % NULL de verdad (antes era imposible — coalesce(...,
--       0) lo pisaba siempre). NULL sigue significando "no participa del
--       recálculo automático", nunca "0% de descuento".
--
--    b) Si nace con % configurado (not null) Y activa: en vez de copiar los
--       precios de "Lista" tal cual (el comportamiento de siempre, pensado
--       para una condición SIN % conectado al pricing), genera directamente
--       precios AUTO con la fórmula — es el caso que pide el cliente: crear
--       "9 cuotas -20%" tiene que generar los precios ya mismo, sin una
--       segunda edición. Si nace sin % (NULL), se mantiene EXACTAMENTE el
--       comportamiento preexistente (copia desde "Lista", como MANUAL).
-- ---------------------------------------------------------------------------
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
    p_discount_percent, v_new_priority, false, p_active,
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

  if p_discount_percent is null then
    -- Sin % conectado al pricing: comportamiento preexistente, copia única
    -- desde la condición de origen (MANUAL, por default de columna).
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
  elsif p_active then
    -- % configurado y activa: genera precios AUTO directamente, sin copiar
    -- nada de "Lista" — es el caso "crear '9 cuotas -20%%' ya con precios".
    v_copied_count := public.fn_recalculate_auto_prices(
      array[]::uuid[], array[v_price_condition_id], now()
    );
  end if;
  -- % configurado pero inactiva: ni copia ni genera — nace sin precios,
  -- coherente con "condición inactiva no participa".

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
      'visible_in_price_lookup', coalesce(p_visible_in_price_lookup, true),
      'discount_percent', p_discount_percent
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
  'payment_method + price_condition + disponibilidad (sedes/Web). Si p_discount_percent es NULL, '
  'copia los precios iniciales de "Lista" (MANUAL, comportamiento preexistente). Si no es NULL y '
  'p_active=true, genera directamente precios AUTO vía fn_recalculate_auto_prices — nunca copia en '
  'ese caso. Solo admin (is_admin()).';

-- ---------------------------------------------------------------------------
-- 4) update_price_condition — mismo signature (9 args), CREATE OR REPLACE
--    conserva el ACL ya endurecido. Cambios de cuerpo:
--
--    a) discount_percent ya no se fuerza a 0 con coalesce (mismo motivo que
--       create_price_condition) — puede pasar a NULL de verdad.
--
--    b) Al final, compara el % y el active ANTES vs DESPUÉS del update:
--       - % pasó a NULL (antes no lo era) -> cierra (valid_until=now,
--         active=false) todas las filas AUTO vigentes de esta condición.
--         Nunca toca MANUAL. Nunca llama al helper (el helper solo crea/
--         recalcula, nunca cierra).
--       - % cambió a un valor no nulo (venga de otro valor o de NULL), O la
--         condición se reactivó (false->true) y ya tiene un % no nulo ->
--         fn_recalculate_auto_prices para esta condición. Reactivar sin %
--         configurado no dispara nada (no hay nada para calcular).
--       - Desactivar (true->false) nunca dispara nada — las filas AUTO
--         existentes quedan como están (ya inválidas para vender mientras
--         esté inactiva; se resincronizan solas al reactivar).
--       - rule_type se vuelve a verificar explícitamente ('PAYMENT_METHOD')
--         antes de cualquiera de estos dos casos, aunque hoy esta función ya
--         excluye estructuralmente a BASE (sin payment_method_id).
-- ---------------------------------------------------------------------------
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
  v_rule_type public.price_rule_type;
  v_old_active boolean;
  v_old_discount_percent numeric;
  v_new_discount_percent numeric;
  v_recalculated_count int := 0;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede editar una condición de precio.';
  end if;

  select payment_method_id, rule_type, active, discount_percent
  into v_payment_method_id, v_rule_type, v_old_active, v_old_discount_percent
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
    discount_percent = p_discount_percent,
    priority = p_priority,
    active = p_active,
    visible_in_price_lookup = coalesce(p_visible_in_price_lookup, visible_in_price_lookup)
  where id = p_price_condition_id
  returning visible_in_price_lookup, discount_percent
  into v_visible_in_price_lookup, v_new_discount_percent;

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

  if v_rule_type = 'PAYMENT_METHOD' then
    if v_new_discount_percent is distinct from v_old_discount_percent and v_new_discount_percent is null then
      -- % != NULL -> NULL: no puede dejar precios AUTO viejos vigentes.
      -- greatest(...) correlacionado por fila: now() es constante dentro de
      -- la transacción, así que no alcanza como valid_until fijo si alguna
      -- de estas filas se creó en el mismo instante (mismo now()) más
      -- temprano en esta misma transacción.
      update public.product_prices
      set valid_until = greatest(now(), valid_from + interval '1 microsecond'), active = false
      where price_condition_id = p_price_condition_id
        and active = true
        and pricing_mode = 'AUTO';
    elsif
      (v_new_discount_percent is distinct from v_old_discount_percent and v_new_discount_percent is not null)
      or (v_old_active = false and p_active = true and v_new_discount_percent is not null)
    then
      -- % cambió a un valor real (incluye NULL -> valor), o se reactivó con
      -- un % ya configurado: recalcula/crea, sin pisar ningún MANUAL.
      v_recalculated_count := public.fn_recalculate_auto_prices(
        array[]::uuid[], array[p_price_condition_id], now()
      );
    end if;
    -- active true->false, o cualquier otro cambio que no toque % ni
    -- reactive: no dispara nada (las filas AUTO quedan como están).
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
      'visible_in_price_lookup', v_visible_in_price_lookup,
      'discount_percent', v_new_discount_percent,
      'auto_recalculated_count', v_recalculated_count
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
  'disponibilidad (reemplazo completo). discount_percent admite NULL real (ya no se fuerza a 0): '
  'si pasa de no-nulo a NULL, cierra todas las filas AUTO vigentes de la condición (preserva MANUAL, '
  'nunca crea). Si cambia a un valor no nulo, o si la condición se reactiva (active false->true) ya '
  'con % configurado, invoca fn_recalculate_auto_prices — misma cascada que usa '
  'save_price_matrix_changes, una sola implementación. p_visible_in_price_lookup es PATCH: default '
  'null preserva el valor ya guardado. No editable para la condición BASE/LIST. Solo admin.';

-- ---------------------------------------------------------------------------
-- 5) save_price_matrix_changes — RPC única y atómica para el guardado de
--    /admin/precios: Lista, %, overrides manuales y resets conviven en un
--    solo request, nunca N llamadas independientes. Orden de aplicación
--    (importa: la cascada del paso 3 tiene que ver ya aplicados los pasos
--    1 y 2; los overrides/resets explícitos del admin, pasos 4 y 5, ganan
--    sobre cualquier cosa que la cascada haya tocado en el mismo guardado).
-- ---------------------------------------------------------------------------
create or replace function public.save_price_matrix_changes(
  p_list_price_changes jsonb default '[]'::jsonb,
  p_percent_changes jsonb default '[]'::jsonb,
  p_manual_overrides jsonb default '[]'::jsonb,
  p_reset_to_auto jsonb default '[]'::jsonb,
  p_clears jsonb default '[]'::jsonb,
  p_valid_from timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb;
  v_product_id uuid;
  v_condition_id uuid;
  v_amount numeric;
  v_pct numeric;
  v_prev_pct numeric;
  v_list_condition_id uuid;
  v_list_changed_products uuid[] := array[]::uuid[];
  v_percent_changed_conditions uuid[] := array[]::uuid[];
  v_list_count int := 0;
  v_percent_count int := 0;
  v_manual_count int := 0;
  v_reset_count int := 0;
  v_clear_count int := 0;
  v_recalculated_count int := 0;
  v_list_amount numeric;
  v_condition_pct numeric;
  v_new_amount numeric;
  v_existing_valid_from timestamptz;
  v_effective_valid_from timestamptz;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede modificar precios.';
  end if;

  select id into v_list_condition_id from public.price_conditions where rule_type = 'BASE';

  -- 1) Precio de Lista.
  for v_item in select * from jsonb_array_elements(coalesce(p_list_price_changes, '[]'::jsonb))
  loop
    v_product_id := (v_item ->> 'product_id')::uuid;
    v_amount := (v_item ->> 'amount')::numeric;
    if v_amount is null or v_amount <= 0 then
      raise exception 'El Precio de Lista debe ser mayor a cero (producto %).', v_product_id;
    end if;

    select pp.valid_from into v_existing_valid_from
    from public.product_prices pp
    where pp.product_id = v_product_id and pp.price_condition_id = v_list_condition_id and pp.active = true;
    -- greatest(...): now()/p_valid_from es constante dentro de la
    -- transacción — si el mismo producto ya fue tocado antes en este mismo
    -- guardado (o en la misma transacción, como en un test), garantiza
    -- valid_until > valid_from siempre (CHECK product_prices_valid_range).
    v_effective_valid_from := case when v_existing_valid_from is null then p_valid_from
      else greatest(p_valid_from, v_existing_valid_from + interval '1 microsecond') end;

    update public.product_prices
      set valid_until = v_effective_valid_from, active = false
      where product_id = v_product_id and price_condition_id = v_list_condition_id and active = true;

    insert into public.product_prices (product_id, price_condition_id, amount, valid_from, pricing_mode, created_by)
    values (v_product_id, v_list_condition_id, v_amount, v_effective_valid_from, 'MANUAL', auth.uid());

    v_list_changed_products := v_list_changed_products || v_product_id;
    v_list_count := v_list_count + 1;
  end loop;

  -- 2) Porcentaje de condiciones.
  for v_item in select * from jsonb_array_elements(coalesce(p_percent_changes, '[]'::jsonb))
  loop
    v_condition_id := (v_item ->> 'price_condition_id')::uuid;
    v_pct := nullif(v_item ->> 'discount_percent', '')::numeric;
    if v_pct is not null and (v_pct < 0 or v_pct > 1) then
      raise exception 'El porcentaje tiene que estar entre 0%% y 100%% (condición %).', v_condition_id;
    end if;

    select discount_percent into v_prev_pct from public.price_conditions where id = v_condition_id;
    update public.price_conditions set discount_percent = v_pct where id = v_condition_id;

    if v_pct is distinct from v_prev_pct and v_pct is null then
      -- Bulk: greatest(...) correlacionado por fila, no un escalar — puede
      -- cerrar varias filas (un producto por cada AUTO vigente de la
      -- condición) con valid_from distintos entre sí.
      update public.product_prices
        set valid_until = greatest(p_valid_from, valid_from + interval '1 microsecond'), active = false
        where price_condition_id = v_condition_id and active = true and pricing_mode = 'AUTO';
    elsif v_pct is distinct from v_prev_pct and v_pct is not null then
      v_percent_changed_conditions := v_percent_changed_conditions || v_condition_id;
    end if;

    v_percent_count := v_percent_count + 1;
  end loop;

  -- 3) Cascada AUTO — una sola pasada, unión de ambas direcciones.
  if array_length(v_list_changed_products, 1) > 0 or array_length(v_percent_changed_conditions, 1) > 0 then
    v_recalculated_count := public.fn_recalculate_auto_prices(
      v_list_changed_products, v_percent_changed_conditions, p_valid_from
    );
  end if;

  -- 4) Overrides manuales — pisan lo que haya hecho la cascada en este mismo guardado.
  for v_item in select * from jsonb_array_elements(coalesce(p_manual_overrides, '[]'::jsonb))
  loop
    v_product_id := (v_item ->> 'product_id')::uuid;
    v_condition_id := (v_item ->> 'price_condition_id')::uuid;
    v_amount := (v_item ->> 'amount')::numeric;
    if v_amount is null or v_amount <= 0 then
      raise exception 'El precio debe ser mayor a cero (producto %, condición %).', v_product_id, v_condition_id;
    end if;

    select pp.valid_from into v_existing_valid_from
    from public.product_prices pp
    where pp.product_id = v_product_id and pp.price_condition_id = v_condition_id and pp.active = true;
    v_effective_valid_from := case when v_existing_valid_from is null then p_valid_from
      else greatest(p_valid_from, v_existing_valid_from + interval '1 microsecond') end;

    update public.product_prices
      set valid_until = v_effective_valid_from, active = false
      where product_id = v_product_id and price_condition_id = v_condition_id and active = true;

    insert into public.product_prices (product_id, price_condition_id, amount, valid_from, pricing_mode, created_by)
    values (v_product_id, v_condition_id, v_amount, v_effective_valid_from, 'MANUAL', auth.uid());

    v_manual_count := v_manual_count + 1;
  end loop;

  -- 5) Volver a automático — recalcula con Lista/% vigentes EN ESTE MOMENTO
  --    (ya reflejan los pasos 1 y 2), nunca confía en lo que el cliente
  --    tenía previsualizado.
  for v_item in select * from jsonb_array_elements(coalesce(p_reset_to_auto, '[]'::jsonb))
  loop
    v_product_id := (v_item ->> 'product_id')::uuid;
    v_condition_id := (v_item ->> 'price_condition_id')::uuid;

    select pp.amount into v_list_amount
    from public.product_prices pp
    where pp.product_id = v_product_id and pp.price_condition_id = v_list_condition_id and pp.active = true;

    select pc.discount_percent into v_condition_pct
    from public.price_conditions pc
    where pc.id = v_condition_id and pc.active = true and pc.rule_type = 'PAYMENT_METHOD';

    if v_list_amount is null then
      raise exception 'El producto no tiene Precio de Lista vigente — no se puede volver a automático.';
    end if;
    if v_condition_pct is null then
      raise exception 'La condición no tiene un porcentaje configurado (o no está activa) — no se puede volver a automático.';
    end if;

    v_new_amount := round(v_list_amount * (1 - v_condition_pct), 2);

    select pp.valid_from into v_existing_valid_from
    from public.product_prices pp
    where pp.product_id = v_product_id and pp.price_condition_id = v_condition_id and pp.active = true;
    v_effective_valid_from := case when v_existing_valid_from is null then p_valid_from
      else greatest(p_valid_from, v_existing_valid_from + interval '1 microsecond') end;

    update public.product_prices
      set valid_until = v_effective_valid_from, active = false
      where product_id = v_product_id and price_condition_id = v_condition_id and active = true;

    insert into public.product_prices (product_id, price_condition_id, amount, valid_from, pricing_mode, created_by)
    values (v_product_id, v_condition_id, v_new_amount, v_effective_valid_from, 'AUTO', auth.uid());

    v_reset_count := v_reset_count + 1;
  end loop;

  -- 6) Borrar precios — mismo mecanismo que clear_product_price (cierra
  --    vigencia, nunca inserta $0 ni ninguna fila nueva). "Sin configurar",
  --    nunca $0.
  for v_item in select * from jsonb_array_elements(coalesce(p_clears, '[]'::jsonb))
  loop
    v_product_id := (v_item ->> 'product_id')::uuid;
    v_condition_id := (v_item ->> 'price_condition_id')::uuid;

    update public.product_prices
      set valid_until = greatest(p_valid_from, valid_from + interval '1 microsecond'), active = false
      where product_id = v_product_id and price_condition_id = v_condition_id and active = true;

    v_clear_count := v_clear_count + 1;
  end loop;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'save_price_matrix_changes', 'product_prices', null,
    jsonb_build_object(
      'list_price_changes', v_list_count,
      'clears', v_clear_count,
      'percent_changes', v_percent_count,
      'auto_recalculated', v_recalculated_count,
      'manual_overrides', v_manual_count,
      'reset_to_auto', v_reset_count
    )
  );

  return jsonb_build_object(
    'list_price_changes', v_list_count,
    'clears', v_clear_count,
    'percent_changes', v_percent_count,
    'auto_recalculated', v_recalculated_count,
    'manual_overrides', v_manual_count,
    'reset_to_auto', v_reset_count
  );
end;
$$;

comment on function public.save_price_matrix_changes(jsonb, jsonb, jsonb, jsonb, jsonb, timestamptz) is
  'RPC única y atómica para /admin/precios: Lista, % de condiciones, overrides manuales, "volver a '
  'automático" y borrados en un solo request — nunca N llamadas independientes. Internamente usa el '
  'mismo fn_recalculate_auto_prices que create_price_condition/update_price_condition. Solo admin.';

revoke execute on function public.save_price_matrix_changes(jsonb, jsonb, jsonb, jsonb, jsonb, timestamptz)
  from public, authenticated, anon;
grant execute on function public.save_price_matrix_changes(jsonb, jsonb, jsonb, jsonb, jsonb, timestamptz)
  to authenticated;
