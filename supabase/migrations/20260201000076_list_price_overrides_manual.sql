-- =============================================================================
-- Maguirejuve · 76 · fn_recalculate_auto_prices — Lista también pisa MANUAL
-- =============================================================================
-- Bug reportado en el smoke final del checkpoint anterior: al cambiar el
-- Precio de Lista de un producto, solo se recalculaban las condiciones que
-- ya estaban AUTO (ej. Efectivo, 3 cuotas) — las que seguían MANUAL desde
-- el backfill de 074 (ej. Transferencia, Tarjeta 1 pago, 6 cuotas, 2 cuotas)
-- quedaban congeladas en el precio viejo. Causa: fn_recalculate_auto_prices
-- (075) solo pisaba MANUAL cuando el disparador venía de
-- p_price_condition_ids (% global) — el de p_product_ids (Lista) seguía
-- preservando MANUAL, semántica #1 explícita de la propia 075.
--
-- Semántica definitiva (aprobada, reemplaza a la de la 075):
--   1. Cambiar Precio Lista recalcula TODO el renglón del producto, para
--      cada condición PAYMENT_METHOD activa con % configurado (NULL no
--      participa) — incluidas las que hoy son MANUAL. Quedan AUTO.
--   2. Cambiar el % global de una condición recalcula TODA esa columna,
--      incluidas las MANUAL — sin cambios respecto de la 075.
--   3. Editar una celda individual crea una excepción MANUAL, que dura
--      hasta que ocurra 1 o 2 sobre esa celda.
--
-- No se edita la 074 ni la 075 (ya aplicadas en producción) — esta es una
-- migración incremental, hacia adelante, que solo reemplaza el cuerpo de
-- fn_recalculate_auto_prices. Mismo signature exacto (uuid[], uuid[],
-- timestamptz) -> CREATE OR REPLACE conserva OID/owner/ACL ya endurecido.
--
-- Cambio de cuerpo: se elimina por completo la protección de MANUAL (el
-- bloque "if ... v_existing_mode = 'MANUAL' ... then continue" de la 075) —
-- ya ninguna dirección (Lista o %) la respeta. pricing_mode deja de leerse
-- para decidir si se recalcula: la función queda más simple que la 075, no
-- más compleja (se eliminan v_existing_mode y la columna calculada
-- from_percent_change, que quedaban sin uso). La fila vieja se sigue
-- cerrando con el mismo mecanismo histórico (greatest(...), UPDATE de
-- valid_until/active, nunca UPDATE destructivo de amount) — ninguna fila
-- histórica se muta, se versiona igual que siempre.
--
-- discount_percent NULL sigue sin participar bajo ninguna dirección (sin
-- cambios respecto de 074/075): el filtro pc.discount_percent is not null
-- se mantiene intacto. 0% sí participa (es un % configurado, no "sin
-- configurar") y da como resultado el mismo importe que Precio de Lista.
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
    select pp.id, pp.valid_from into v_existing_id, v_existing_valid_from
    from public.product_prices pp
    where pp.product_id = v_pair.product_id
      and pp.price_condition_id = v_pair.price_condition_id
      and pp.active = true;

    -- Ya no se preserva MANUAL bajo ninguna dirección (Lista o %): la única
    -- forma de que una celda quede MANUAL es una edición individual
    -- posterior (manual_overrides, en save_price_matrix_changes, siempre
    -- aplicada después de esta cascada).

    v_new_amount := round(v_pair.list_amount * (1 - v_pair.discount_percent), 2);
    if v_new_amount is null or v_new_amount <= 0 then
      -- Defensivo: amount > 0 es un CHECK de la tabla de todos modos — nunca
      -- debería dispararse (ya filtramos list_amount/discount_percent no
      -- nulos arriba), pero preferimos omitir en vez de dejar que la
      -- excepción del CHECK aborte toda la cascada por un caso de borde.
      continue;
    end if;

    if v_existing_id is not null then
      -- now()/p_valid_from es constante dentro de la transacción —
      -- greatest(...) garantiza valid_until > valid_from siempre (CHECK
      -- product_prices_valid_range). Cierra la fila existente (sea AUTO o
      -- MANUAL) — nunca un UPDATE destructivo de amount: la fila vieja
      -- queda intacta como historial, solo se le cierra la vigencia.
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
  'afectados por un cambio de Lista o de %. Ninguna dirección preserva MANUAL (migración 076) — la '
  'única forma de que una celda quede MANUAL es una edición individual explícita, que dura hasta el '
  'próximo cambio de Lista de ese producto o de % de esa condición. discount_percent NULL nunca '
  'participa. Invocado desde create_price_condition, update_price_condition y '
  'save_price_matrix_changes.';

-- Reafirmado por claridad (ya estaba vigente desde la 074 y CREATE OR
-- REPLACE con el mismo signature no lo toca) — ningún GRANT se agrega: el
-- helper sigue sin ser invocable directamente por ningún cliente.
revoke execute on function public.fn_recalculate_auto_prices(uuid[], uuid[], timestamptz)
  from public, authenticated, anon;
