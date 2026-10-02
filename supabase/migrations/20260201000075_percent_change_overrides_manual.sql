-- =============================================================================
-- Maguirejuve · 75 · fn_recalculate_auto_prices — % global pisa MANUAL
-- =============================================================================
-- Bug reportado en producción/Preview: tras la 074, todo lo preexistente
-- quedó MANUAL (backfill esperado). Pero al tipear un nuevo % en el
-- encabezado de una condición (ej. Efectivo 10%), el sistema calculaba el
-- valor correcto pero no lo aplicaba — obligaba a "Volver a automático" fila
-- por fila. Causa: fn_recalculate_auto_prices tenía una única regla "si es
-- MANUAL, se omite", sin distinguir desde qué dirección llegó el par
-- producto×condición (Lista cambiada vs % cambiado).
--
-- Semántica definitiva (aprobada):
--   1. Cambiar Precio Lista solo recalcula AUTO; preserva MANUAL.
--   2. Editar una celda individual la vuelve MANUAL (sin cambios, ya existía).
--   3. Cambiar el % global de una condición recalcula TODOS los productos
--      elegibles de esa condición, incluidos los que hoy son MANUAL, y los
--      deja AUTO.
--   4. "Volver a automático" individual se mantiene intacta.
--   5. Si Lista y % cambian en el mismo guardado, gana el %: nueva Lista +
--      nuevo %, resultado AUTO.
--
-- No se edita la migración 074 (ya aplicada en producción) — esta es una
-- migración incremental, hacia adelante, que solo reemplaza el cuerpo de
-- fn_recalculate_auto_prices. Mismo signature exacto (uuid[], uuid[],
-- timestamptz) -> CREATE OR REPLACE conserva OID/owner/ACL ya endurecido
-- (ver revoke más abajo, reafirmado por claridad, sin agregar ningún grant).
--
-- Único cambio de cuerpo: cada fila candidata ahora sabe si llegó porque su
-- condición está en p_price_condition_ids (from_percent_change). La
-- protección de MANUAL aplica solo cuando NO vino por esa vía. Si
-- from_percent_change=true y existía una fila MANUAL vigente, se cierra con
-- el mismo mecanismo histórico de siempre (greatest(...), UPDATE de
-- valid_until/active, nunca UPDATE destructivo de amount) y se inserta la
-- nueva versión en AUTO — ninguna fila histórica se muta.
--
-- Efecto esperado sobre datos existentes (consecuencia explícitamente
-- aceptada): un MANUAL nacido del backfill de 074 que esté bajo una
-- condición PAYMENT_METHOD cuyo % se vuelva a tocar pasa a AUTO. Cambiar
-- solo Precio Lista sigue sin tocar ningún MANUAL.
--
-- Alcance: no toca promociones, ventas históricas, disponibilidad por
-- sede/canal, visible_in_price_lookup, medios de pago, stock, facturación.
-- No agrega ningún GRANT nuevo — el helper sigue sin ser invocable
-- directamente por ningún cliente.
-- =============================================================================
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
      base.list_amount,
      pc.id = any(coalesce(p_price_condition_ids, array[]::uuid[])) as from_percent_change
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

    -- La protección de MANUAL aplica únicamente cuando el par NO llegó por
    -- un cambio global de %: un cambio de Precio Lista nunca pisa una
    -- excepción manual, pero un cambio de % en la condición sí la resetea a
    -- AUTO (semántica #3 de arriba) — es la única diferencia con la 074.
    if v_existing_id is not null and v_existing_mode = 'MANUAL' and not v_pair.from_percent_change then
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
      -- product_prices_valid_range), sin depender del reloj de pared. Esto
      -- cierra la fila existente (sea AUTO o MANUAL) — nunca un UPDATE
      -- destructivo de amount: la fila vieja queda intacta como historial,
      -- solo se le cierra la vigencia.
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
  'afectados por un cambio de Lista o de %. Un cambio de Lista preserva MANUAL; un cambio de % global '
  'de la condición (p_price_condition_ids) resetea a AUTO incluso filas MANUAL vigentes de esa misma '
  'condición (migración 075 — antes de esto, un % nuevo nunca pisaba MANUAL, sin importar la '
  'dirección). Invocado desde create_price_condition, update_price_condition y '
  'save_price_matrix_changes.';

-- Reafirmado por claridad (ya estaba vigente desde la 074 y CREATE OR
-- REPLACE con el mismo signature no lo toca) — ningún GRANT se agrega: el
-- helper sigue sin ser invocable directamente por ningún cliente.
revoke execute on function public.fn_recalculate_auto_prices(uuid[], uuid[], timestamptz)
  from public, authenticated, anon;
