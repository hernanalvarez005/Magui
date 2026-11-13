-- =============================================================================
-- Maguirejuve · 77 · transfer_stock — transfer_number sin colisión + idempotencia
-- =============================================================================
-- Bug reportado en producción: "duplicate key value violates unique constraint
-- stock_transfers_transfer_number_key" al confirmar una transferencia de
-- stock entre sucursales (caso real: Depósito -> Clínica 25, Cremas pieles
-- grasas, 10 u.).
--
-- Causa raíz (dos factores -- el primero es la colisión real, el segundo es
-- una fragilidad de fondo del mismo mecanismo):
--
--   1) Desajuste de huso horario entre el conteo y el string formateado.
--      transfer_stock (20260101000009, redefinida sin cambios en este punto
--      por 20260201000061) calculaba:
--        v_transfer_number := format('TRF-%s-%s', to_char(now(), 'YYYYMMDD'), ...)
--      to_char(timestamptz, ...) formatea en el TimeZone de la SESIÓN (UTC
--      por default en este proyecto), mientras el conteo que decide v_seq
--      usaba:
--        where created_at::date = (now() at time zone 'America/Argentina/Buenos_Aires')::date
--      Entre las 21:00 y las 23:59 hora Argentina (00:00-03:00 UTC del día
--      siguiente), el STRING ya muestra la fecha UTC del día siguiente,
--      mientras el conteo todavía agrupa por el día argentino anterior. Una
--      transferencia confirmada en esa ventana y otra confirmada horas
--      después (ya en la madrugada argentina del día nuevo, cuando el
--      conteo sí pasa a agrupar por ese día) pueden terminar calculando el
--      mismo v_seq para el mismo string de fecha -- dos transferencias
--      distintas generan el mismo "TRF-<fecha>-0001".
--
--   2) Aun corrigiendo (1), "select count(*) + 1" bajo un advisory lock es
--      frágil por construcción: no reserva el número atómicamente contra la
--      tabla, depende de que cada caller tome el mismo lock antes de leer.
--      No es el patrón que ya usa el resto del sistema para esto mismo
--      (fn_next_sale_number, migración 006/009): un contador en tabla con
--      INSERT ... ON CONFLICT ... DO UPDATE ... RETURNING, atómico a nivel
--      de fila, sin depender de ningún advisory lock externo.
--
-- Fix: fn_next_transfer_number(), mismo patrón ya probado que
-- fn_next_sale_number -- un contador en tabla por día
-- (stock_transfer_number_counters), incrementado con
-- INSERT ... ON CONFLICT (day) DO UPDATE ... RETURNING last_seq. El día se
-- calcula UNA sola vez, ya convertido a America/Argentina/Buenos_Aires, y
-- se usa igual para la clave del contador y para el string formateado
-- (to_char sobre un `date` ya convertido, nunca sobre un timestamptz crudo)
-- -- elimina el desajuste de (1) de raíz. Formato preservado exactamente:
-- TRF-YYYYMMDD-NNNN.
--
-- Además, idempotencia: nueva columna stock_transfers.idempotency_key
-- (uuid, nullable, unique). transfer_stock admite un nuevo parámetro
-- opcional p_idempotency_key -- si el cliente lo manda y ya existe una
-- transferencia con esa clave, la función devuelve esa transferencia YA
-- CONFIRMADA sin tocar stock ni crear una fila nueva (protege contra doble
-- clic o un reintento de red tras un timeout).
--
-- transfer_stock cambia de signature (se agrega un parámetro) -> DROP
-- FUNCTION + CREATE en vez de CREATE OR REPLACE, para no dejar un segundo
-- overload (mismo patrón ya usado para create_price_condition en la
-- migración 070). Se reafirman los GRANT/REVOKE después, porque DROP
-- FUNCTION borra el ACL del objeto anterior.
--
-- No se editan migraciones ya aplicadas (009/061) -- esta es incremental,
-- hacia adelante. No se borra ni renumera ninguna transferencia existente
-- -- el histórico queda intacto, se corrige solo hacia adelante.
--
-- Transaccionalidad: todo el archivo corre dentro de un único BEGIN/COMMIT
-- explícito. Esto es necesario porque `psql -f` (y por extensión cualquier
-- ejecución statement-por-statement) NO envuelve un archivo multi-statement
-- en una transacción por sí solo -- cada statement hace autocommit salvo que
-- el propio script lo pida. Con el BEGIN/COMMIT explícito, si cualquier
-- statement de acá abajo falla, TODO se revierte (tabla, función, columna,
-- backfill, DROP+CREATE de transfer_stock, grants) -- no queda ningún
-- cambio parcial, sin importar con qué herramienta se corra (psql -f,
-- Supabase CLI, o pegado entero en el SQL Editor).
-- =============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 1) Contador atómico de transfer_number, mismo patrón que sale_number_counters.
-- ---------------------------------------------------------------------------
create table public.stock_transfer_number_counters (
  day date primary key,
  last_seq int not null default 0
);

comment on table public.stock_transfer_number_counters is
  'Soporte interno de fn_next_transfer_number(). No se expone a la API pública.';

-- RLS sin policies, mismo patrón ya probado en producción para
-- sale_number_counters (migración 010): en este esquema, TODA tabla nueva en
-- `public` hereda automáticamente privilegios DML amplios para `authenticated`
-- vía `alter default privileges in schema public grant ... to authenticated`
-- (migración 010, ya aplicada) -- sin esto, cualquier cliente autenticado
-- podría leer/insertar/modificar/eliminar filas de este contador DIRECTO por
-- la REST API, sin pasar por fn_next_transfer_number. Habilitar RLS sin
-- ninguna policy bloquea esas 4 operaciones por completo para
-- authenticated/anon (RLS habilitada + cero policies = deniega todo).
-- fn_next_transfer_number sigue funcionando: corre SECURITY DEFINER como el
-- dueño de la función (el rol `postgres`, que en Supabase tiene BYPASSRLS),
-- no como `authenticated` -- RLS nunca lo afecta, exactamente como ya pasa
-- hoy con fn_next_sale_number y sale_number_counters.
alter table public.stock_transfer_number_counters enable row level security;

-- Backfill: esta migración puede aplicarse sobre una base de producción que
-- YA tiene transferencias históricas (generadas con el mecanismo viejo,
-- count(*)+advisory lock). Si el contador arrancara en 0 para cada día, el
-- primer llamado después de la migración recalcularía el mismo
-- transfer_number que una fila ya existente de ESE día (ej. si hoy ya hay
-- 3 transferencias TRF-<hoy>-0001..0003, sin este backfill la primera
-- llamada post-migración devolvería TRF-<hoy>-0001 de nuevo -- exactamente
-- el error que esta migración vino a eliminar, aunque sea una sola vez).
-- Semilla cada día que ya tiene transferencias con su correlativo real más
-- alto, parseado del propio transfer_number (formato TRF-YYYYMMDD-NNNN) --
-- así el próximo llamado para ese día continúa en +1, nunca repite. No
-- toca ninguna fila de stock_transfers, solo puebla el contador.
insert into public.stock_transfer_number_counters (day, last_seq)
select
  to_date(substring(st.transfer_number from 5 for 8), 'YYYYMMDD'),
  max(substring(st.transfer_number from 14 for 4)::int)
from public.stock_transfers st
where st.transfer_number ~ '^TRF-\d{8}-\d{4}$'
group by 1
on conflict (day) do update
  set last_seq = greatest(public.stock_transfer_number_counters.last_seq, excluded.last_seq);

create or replace function public.fn_next_transfer_number(p_at timestamptz)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day date;
  v_seq int;
begin
  v_day := (p_at at time zone 'America/Argentina/Buenos_Aires')::date;

  insert into public.stock_transfer_number_counters (day, last_seq)
  values (v_day, 1)
  on conflict (day)
  do update set last_seq = public.stock_transfer_number_counters.last_seq + 1
  returning last_seq into v_seq;

  return format('TRF-%s-%s', to_char(v_day, 'YYYYMMDD'), lpad(v_seq::text, 4, '0'));
end;
$$;

comment on function public.fn_next_transfer_number(timestamptz) is
  'Helper interno -- NUNCA otorgado a PUBLIC/authenticated/anon. Genera transfer_number de '
  'forma atómica (INSERT ... ON CONFLICT ... DO UPDATE ... RETURNING sobre '
  'stock_transfer_number_counters, mismo patrón que fn_next_sale_number) -- nunca colisiona '
  'bajo transacciones concurrentes. El día se calcula una sola vez en '
  'America/Argentina/Buenos_Aires y se usa igual para la clave del contador y para el '
  'string (nunca to_char sobre un timestamptz crudo, que formatearía en el TimeZone de '
  'sesión -- esa era la causa real del duplicado). Formato: TRF-YYYYMMDD-NNNN, igual que '
  'antes. Invocada desde transfer_stock.';

revoke execute on function public.fn_next_transfer_number(timestamptz)
  from public, authenticated, anon;

-- ---------------------------------------------------------------------------
-- 2) Idempotencia -- columna + unique constraint. Nullable: no afecta ninguna
--    fila existente ni ningún caller que no la use (NULL nunca colisiona con
--    NULL bajo UNIQUE).
-- ---------------------------------------------------------------------------
alter table public.stock_transfers
  add column idempotency_key uuid;

alter table public.stock_transfers
  add constraint stock_transfers_idempotency_key_key unique (idempotency_key);

comment on column public.stock_transfers.idempotency_key is
  'Clave opcional generada por el cliente (ej. crypto.randomUUID() por intento de envío). '
  'Si se repite (doble clic, reintento de red tras timeout), transfer_stock devuelve la '
  'transferencia ya confirmada sin duplicar movimientos de stock. NULL para transferencias '
  'sin clave.';

-- ---------------------------------------------------------------------------
-- 3) transfer_stock -- mismo cuerpo de negocio, transfer_number vía el nuevo
--    helper, p_idempotency_key nuevo al final (default null, no rompe
--    callers existentes).
-- ---------------------------------------------------------------------------
drop function if exists public.transfer_stock(uuid, uuid, jsonb, text);

create or replace function public.transfer_stock(
  p_from_location_id uuid,
  p_to_location_id uuid,
  p_items jsonb, -- [{"product_id": uuid, "quantity": number}]
  p_notes text default null,
  p_idempotency_key uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings public.app_settings;
  v_transfer_id uuid;
  v_transfer_number text;
  v_item record;
  v_existing_id uuid;
  v_existing_number text;
begin
  if not public.is_admin() then
    raise exception 'Tu usuario no tiene permiso para transferir stock.';
  end if;

  if p_from_location_id = p_to_location_id then
    raise exception 'La sede de origen y destino no pueden ser la misma.';
  end if;

  if not (public.has_location_access(p_from_location_id) and public.has_location_access(p_to_location_id)) then
    raise exception 'Tu usuario no tiene acceso a alguna de las sedes involucradas.';
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'La transferencia no tiene productos.';
  end if;

  -- Idempotencia: un reintento (doble clic, timeout de red) con la MISMA
  -- clave nunca duplica la transferencia ni vuelve a tocar stock -- devuelve
  -- la transferencia ya confirmada tal cual quedó la primera vez.
  if p_idempotency_key is not null then
    select id, transfer_number into v_existing_id, v_existing_number
    from public.stock_transfers
    where idempotency_key = p_idempotency_key;

    if v_existing_id is not null then
      return jsonb_build_object(
        'transfer_id', v_existing_id, 'transfer_number', v_existing_number, 'idempotent_replay', true
      );
    end if;
  end if;

  select * into v_settings from public.app_settings where id = 1;

  v_transfer_number := public.fn_next_transfer_number(now());

  begin
    insert into public.stock_transfers
      (transfer_number, from_location_id, to_location_id, notes, created_by, idempotency_key)
    values
      (v_transfer_number, p_from_location_id, p_to_location_id, p_notes, auth.uid(), p_idempotency_key)
    returning id into v_transfer_id;
  exception when unique_violation then
    -- Carrera genuina: dos requests concurrentes con la MISMA
    -- idempotency_key (doble clic que el cliente no alcanzó a deshabilitar
    -- a tiempo). Nunca duplica: la que pierde la carrera devuelve la fila
    -- que sí se insertó. Si el conflicto no fue por idempotency_key (no
    -- debería pasar más, ver fn_next_transfer_number), se re-lanza tal cual.
    if p_idempotency_key is null then
      raise;
    end if;

    select id, transfer_number into v_transfer_id, v_transfer_number
    from public.stock_transfers
    where idempotency_key = p_idempotency_key;

    if v_transfer_id is null then
      raise;
    end if;

    return jsonb_build_object(
      'transfer_id', v_transfer_id, 'transfer_number', v_transfer_number, 'idempotent_replay', true
    );
  end;

  for v_item in
    select (elem ->> 'product_id')::uuid as product_id, (elem ->> 'quantity')::numeric as quantity
    from jsonb_array_elements(p_items) elem
    order by (elem ->> 'product_id')::uuid
  loop
    if v_item.quantity is null or v_item.quantity <= 0 then
      raise exception 'Cantidad inválida en la transferencia.';
    end if;

    if not exists (select 1 from public.products where id = v_item.product_id and track_stock = true) then
      raise exception 'Solo se pueden transferir productos con stock propio (no kits).';
    end if;

    -- Guard duro (migración 061): nunca se puede dejar la sede de origen con
    -- disponible negativo, sin importar allow_transfer_overdraft.
    perform public.fn_check_available_stock(p_from_location_id, v_item.product_id, v_item.quantity, false);

    insert into public.stock_transfer_items (transfer_id, product_id, quantity)
    values (v_transfer_id, v_item.product_id, v_item.quantity);

    perform public.fn_apply_stock_movement(
      p_location_id => p_from_location_id,
      p_product_id => v_item.product_id,
      p_movement_type => 'TRANSFER_OUT',
      p_quantity_delta => -v_item.quantity,
      p_transfer_id => v_transfer_id,
      p_reference => v_transfer_number,
      p_created_by => auth.uid(),
      p_allow_negative => coalesce(v_settings.allow_transfer_overdraft, false)
    );

    perform public.fn_apply_stock_movement(
      p_location_id => p_to_location_id,
      p_product_id => v_item.product_id,
      p_movement_type => 'TRANSFER_IN',
      p_quantity_delta => v_item.quantity,
      p_transfer_id => v_transfer_id,
      p_reference => v_transfer_number,
      p_created_by => auth.uid(),
      p_allow_negative => true
    );
  end loop;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (auth.uid(), 'transfer_stock', 'stock_transfers', v_transfer_id,
          jsonb_build_object('from', p_from_location_id, 'to', p_to_location_id, 'items', p_items));

  return jsonb_build_object('transfer_id', v_transfer_id, 'transfer_number', v_transfer_number);
end;
$$;

comment on function public.transfer_stock(uuid, uuid, jsonb, text, uuid) is
  'Transferencia de stock entre sedes (admin), atómica: descuenta en origen '
  '(fn_check_available_stock siempre valida contra el disponible real) y suma en destino en '
  'la misma transacción -- cualquier excepción (producto inválido, cantidad inválida, stock '
  'insuficiente) revierte todo, nunca deja un movimiento a medias. transfer_number se genera '
  'con fn_next_transfer_number (contador atómico por día, sin colisión bajo concurrencia -- '
  'migración 077). p_idempotency_key opcional: un reintento con la misma clave devuelve la '
  'transferencia ya confirmada en vez de duplicarla.';

revoke execute on function public.transfer_stock(uuid, uuid, jsonb, text, uuid)
  from public, anon;
grant execute on function public.transfer_stock(uuid, uuid, jsonb, text, uuid)
  to authenticated;

commit;
