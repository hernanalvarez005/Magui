-- =============================================================================
-- Maguirejuve · 46 · Condiciones QUANTITY -> Promociones — excepción de
-- exclusividad para QUANTITY_DISCOUNT (paso 6/6)
-- =============================================================================
-- Descubierto al validar empíricamente (sección 12/13 del pedido, batería de
-- tests): la regla ya existente "un producto pertenece A LO SUMO A UNA
-- promoción ACTIVA a la vez" (20260201000010_promotions_schema.sql) bloquea
-- exactamente el escenario que este ajuste pide como requisito explícito —
-- "2 productos -> 20%" y "3 productos -> 25%" vigentes SIMULTÁNEAMENTE sobre
-- los MISMOS productos, resolviendo cuál gana por prioridad administrativa
-- cuando ambas matchean.
--
-- La resolución "cuál gana" YA existe y funciona para este caso exacto:
-- fn_apply_promotions arma `matches` (todas las promociones que matchean el
-- carrito) y `exclusive_winner` (la de menor priority entre las no-
-- combinables) sin ningún supuesto de que un producto solo pueda estar en
-- una fila de promotion_products — el motor de cálculo ya está preparado
-- para esto. Lo único demasiado estricto es el TRIGGER de escritura, que
-- nunca dejaba llegar a esa situación.
--
-- Se relaja la exclusividad SOLO entre dos promociones QUANTITY_DISCOUNT —
-- 3x2/duo%/kit% mantienen la regla exacta de siempre (un producto en 3x2 y
-- en kit% al mismo tiempo seguiría siendo ambiguo/no soportado por el motor,
-- eso no cambió). Mismas firmas — CREATE OR REPLACE sin necesidad de DROP.
create or replace function public.fn_check_promotion_product_exclusive()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_type public.promotion_type;
  v_conflict text;
begin
  select p.type into v_new_type from public.promotions p where p.id = new.promotion_id;

  if exists (select 1 from public.promotions p where p.id = new.promotion_id and p.active = true) then
    select pr.name into v_conflict
    from public.promotion_products pp
    join public.promotions pr on pr.id = pp.promotion_id
    where pp.product_id = new.product_id
      and pp.promotion_id <> new.promotion_id
      and pr.active = true
      -- Excepción: dos QUANTITY_DISCOUNT SÍ pueden compartir productos.
      and not (pr.type = 'QUANTITY_DISCOUNT' and v_new_type = 'QUANTITY_DISCOUNT')
    limit 1;

    if v_conflict is not null then
      raise exception
        'Este producto ya está en la promoción activa "%". No puede estar en dos promociones activas a la vez.',
        v_conflict;
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.fn_check_promotion_activation_exclusive()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conflict text;
begin
  if new.active = true and coalesce(old.active, false) = false then
    select pr.name into v_conflict
    from public.promotion_products pp
    join public.promotions pr on pr.id = pp.promotion_id
    where pp.promotion_id <> new.id
      and pr.active = true
      and pp.product_id in (select product_id from public.promotion_products where promotion_id = new.id)
      -- Misma excepción que fn_check_promotion_product_exclusive.
      and not (pr.type = 'QUANTITY_DISCOUNT' and new.type = 'QUANTITY_DISCOUNT')
    limit 1;

    if v_conflict is not null then
      raise exception 'No se puede activar: algún producto ya está en la promoción activa "%".', v_conflict;
    end if;
  end if;
  return new;
end;
$$;

comment on table public.promotion_products is
  'Productos elegibles de cada promoción. THREE_FOR_TWO: 1 o más. '
  'DUO_PERCENT: exactamente 2. KIT_PERCENT: exactamente 1. QUANTITY_DISCOUNT: 1 o más. '
  'Un producto pertenece a lo sumo a UNA promoción activa a la vez, EXCEPTO entre dos '
  'QUANTITY_DISCOUNT (para poder tener "2+ -> 20%" y "3+ -> 25%" vigentes simultáneamente '
  'sobre los mismos productos — fn_apply_promotions ya resuelve cuál gana por prioridad).';
