-- =============================================================================
-- Maguirejuve · 26 · Motor de promociones: esquema (bloque 7)
-- =============================================================================
-- Tres tipos de promoción, centralizadas y administrables desde /admin/promociones
-- (no confundir con price_conditions, que resuelve el PRECIO BASE por medio de
-- pago/cantidad — las promociones se evalúan DESPUÉS, sobre el precio ya
-- resuelto):
--   THREE_FOR_TWO — "3x2": cada N unidades elegibles (group_size, default 3)
--     compradas entre los productos de la promoción, la más barata sale gratis.
--     Generalizado para qty > group_size (7 unidades con group_size=3 -> 2 gratis).
--   DUO_PERCENT    — % de descuento cuando aparecen JUNTOS en el carrito los 2
--     productos configurados (ej. "llevate la crema + el sérum con 15% off").
--   KIT_PERCENT    — % de descuento fijo sobre un kit puntual.
--
-- Decisión de diseño (ambigüedad resuelta a favor de la opción más segura,
-- documentada acá en vez de preguntar — ver sección 51 del prompt): un
-- producto pertenece A LO SUMO A UNA promoción ACTIVA a la vez. Esto evita
-- todo el espacio de combinaciones "qué se combina con qué unidad" y hace que
-- `stackable` tenga una semántica simple y verificable: si alguna promoción
-- que matchea el carrito es NO stackable, gana ella sola (la de mayor
-- prioridad, igual que price_conditions) y se ignoran todas las demás; si
-- ninguna no-stackable matchea, se aplican TODAS las stackable que matcheen
-- (nunca se pisan entre sí porque cada producto es de una sola promoción).
create type public.promotion_type as enum ('THREE_FOR_TWO', 'DUO_PERCENT', 'KIT_PERCENT');

create table public.promotions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  type public.promotion_type not null,
  -- Null para THREE_FOR_TWO (la unidad más barata sale 100% gratis, no hay
  -- porcentaje que configurar). Requerido para DUO_PERCENT/KIT_PERCENT.
  -- Tope de 90%: un descuento del 100% sería indistinguible de una entrega
  -- sin costo pero sin pasar por el flujo de "venta sin costo" (motivo
  -- obligatorio, auditoría, comisión forzada a 0) — se evita ese atajo.
  discount_percent numeric(5, 4),
  group_size int not null default 3 check (group_size >= 2),
  priority int not null default 100,
  stackable boolean not null default false,
  active boolean not null default true,
  valid_from timestamptz not null default now(),
  valid_until timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  constraint promotions_valid_range check (valid_until is null or valid_until > valid_from),
  constraint promotions_discount_percent_shape check (
    (type = 'THREE_FOR_TWO' and discount_percent is null)
    or (type in ('DUO_PERCENT', 'KIT_PERCENT') and discount_percent is not null
        and discount_percent > 0 and discount_percent <= 0.9)
  )
);

comment on table public.promotions is
  'Promociones centralizadas (3x2 / duo% / kit%). Nunca se borra una fila: '
  'sale_items.applied_promotion_id de ventas históricas depende de que el id '
  'siga existiendo — se desactiva (active=false) en su lugar.';

create table public.promotion_products (
  id uuid primary key default gen_random_uuid(),
  promotion_id uuid not null references public.promotions (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint promotion_products_unique unique (promotion_id, product_id)
);

comment on table public.promotion_products is
  'Productos elegibles de cada promoción. THREE_FOR_TWO: 1 o más. '
  'DUO_PERCENT: exactamente 2. KIT_PERCENT: exactamente 1 (el kit).';

-- ---------------------------------------------------------------------------
-- Un producto no puede estar en dos promociones ACTIVAS a la vez (ver
-- justificación arriba). Se valida en dos puntos: al agregar/mover un
-- producto a una promoción activa, y al activar una promoción cuyos
-- productos ya están en otra promoción activa.
-- ---------------------------------------------------------------------------
create or replace function public.fn_check_promotion_product_exclusive()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conflict text;
begin
  if exists (select 1 from public.promotions p where p.id = new.promotion_id and p.active = true) then
    select pr.name into v_conflict
    from public.promotion_products pp
    join public.promotions pr on pr.id = pp.promotion_id
    where pp.product_id = new.product_id
      and pp.promotion_id <> new.promotion_id
      and pr.active = true
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

create trigger trg_promotion_products_exclusive
  before insert or update on public.promotion_products
  for each row execute function public.fn_check_promotion_product_exclusive();

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
    limit 1;

    if v_conflict is not null then
      raise exception 'No se puede activar: algún producto ya está en la promoción activa "%".', v_conflict;
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_promotions_activation_exclusive
  before update on public.promotions
  for each row execute function public.fn_check_promotion_activation_exclusive();

-- ---------------------------------------------------------------------------
-- Cantidad de productos requerida por tipo. Se valida al final de la
-- transacción (deferred): dar de alta una promoción DUO_PERCENT necesita 2
-- inserts en promotion_products, que no pueden validarse fila por fila.
-- ---------------------------------------------------------------------------
create or replace function public.fn_check_promotion_product_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_promo record;
  v_count int;
begin
  select id, type, name into v_promo from public.promotions where id = coalesce(new.promotion_id, old.promotion_id);
  if v_promo is null then
    return null; -- la promoción se borró en la misma transacción (cascade) — nada que validar
  end if;

  select count(*) into v_count from public.promotion_products where promotion_id = v_promo.id;

  if v_promo.type = 'DUO_PERCENT' and v_count <> 2 then
    raise exception 'La promoción "duo" "%" necesita exactamente 2 productos (tiene %).', v_promo.name, v_count;
  end if;
  if v_promo.type = 'KIT_PERCENT' and v_count <> 1 then
    raise exception 'La promoción de kit "%" necesita exactamente 1 producto (tiene %).', v_promo.name, v_count;
  end if;
  if v_promo.type = 'THREE_FOR_TWO' and v_count < 1 then
    raise exception 'La promoción 3x2 "%" necesita al menos 1 producto elegible.', v_promo.name;
  end if;

  return null;
end;
$$;

create constraint trigger trg_promotion_products_count_check
  after insert or update or delete on public.promotion_products
  deferrable initially deferred
  for each row execute function public.fn_check_promotion_product_count();

-- ---------------------------------------------------------------------------
-- RLS: lectura para cualquier usuario activo (para que el motor de precios y
-- el carrito de Nueva Venta puedan mostrar promos aplicadas); escritura
-- exclusiva de admin. Nunca hay policy de DELETE en promotions (soft-delete
-- únicamente, ver comentario de la tabla); promotion_products sí permite
-- DELETE porque borrar una fila de composición no toca ventas históricas
-- (sale_items apunta a promotions.id, no a promotion_products.id) — mismo
-- principio que kit_components.
-- ---------------------------------------------------------------------------
alter table public.promotions enable row level security;
alter table public.promotion_products enable row level security;

create policy promotions_select on public.promotions
  for select using (public.is_active_profile());
create policy promotions_admin_write on public.promotions
  for insert with check (public.is_admin());
create policy promotions_admin_update on public.promotions
  for update using (public.is_admin()) with check (public.is_admin());

create policy promotion_products_select on public.promotion_products
  for select using (public.is_active_profile());
create policy promotion_products_admin_write on public.promotion_products
  for insert with check (public.is_admin());
create policy promotion_products_admin_update on public.promotion_products
  for update using (public.is_admin()) with check (public.is_admin());
create policy promotion_products_admin_delete on public.promotion_products
  for delete using (public.is_admin());

-- ---------------------------------------------------------------------------
-- set_promotion_products: reemplaza toda la composición de una promoción en
-- una sola transacción. IMPORTANTE: el trigger de conteo por tipo
-- (fn_check_promotion_product_count) es DEFERRED, pero eso solo ayuda dentro
-- de una misma transacción — cada llamada de supabase-js a .insert()/.delete()
-- es su propia transacción autocommit. Borrar y volver a insertar en dos
-- llamadas separadas del cliente rompería una promoción DUO_PERCENT/
-- KIT_PERCENT a mitad de camino (el conteo temporal no cumple la regla del
-- tipo). Esta RPC hace el delete+insert dentro de una única función, así el
-- chequeo deferred recién corre sobre el estado final. La UI de admin SIEMPRE
-- pasa por acá para editar composición, nunca por inserts/deletes sueltos.
create or replace function public.set_promotion_products(p_promotion_id uuid, p_product_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede editar la composición de una promoción.';
  end if;

  if not exists (select 1 from public.promotions where id = p_promotion_id) then
    raise exception 'La promoción no existe.';
  end if;

  if p_product_ids is null or array_length(p_product_ids, 1) is null then
    raise exception 'Una promoción necesita al menos un producto.';
  end if;

  if array_length(p_product_ids, 1) <> (select count(distinct x) from unnest(p_product_ids) x) then
    raise exception 'No repitas el mismo producto.';
  end if;

  delete from public.promotion_products where promotion_id = p_promotion_id;

  insert into public.promotion_products (promotion_id, product_id)
  select p_promotion_id, x from unnest(p_product_ids) x;

  -- El trigger de conteo (trg_promotion_products_count_check) es DEFERRED
  -- por diseño (necesita ver el estado final de varias filas). Se fuerza acá
  -- a que corra YA, en vez de esperar al commit de quien llamó a esta RPC —
  -- así el error sale de esta función, no en un punto sorpresivo más tarde.
  -- IMPORTANTE: "SET CONSTRAINTS ... IMMEDIATE" no es un flush de una sola
  -- vez — cambia el modo de chequeo para el RESTO de la transacción. Sin el
  -- DEFERRED de acá abajo, una segunda llamada a esta misma función dentro
  -- de la MISMA transacción (ej. un test que encadena varias) haría que su
  -- propio DELETE interno se chequee de inmediato, con 0 filas, ANTES de
  -- llegar al INSERT que las repone — un falso "necesita al menos 1
  -- producto". Se vuelve a DEFERRED explícitamente para no dejar ese modo
  -- filtrado hacia adelante.
  set constraints public.trg_promotion_products_count_check immediate;
  set constraints public.trg_promotion_products_count_check deferred;

  return jsonb_build_object('promotion_id', p_promotion_id, 'product_count', array_length(p_product_ids, 1));
end;
$$;

grant execute on function public.set_promotion_products(uuid, uuid[]) to authenticated;
