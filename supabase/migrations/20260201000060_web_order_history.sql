-- =============================================================================
-- Maguirejuve · 60 · Circuito Ventas Web — BLOQUE E: Historial de pedidos Web
-- =============================================================================
-- Misma fuente de verdad que BLOQUE D: NO se crea ninguna tabla de historial
-- paralela. Se deriva de sales/sale_items/products/profiles/customers, con
-- una única RPC nueva (web_order_history), mismo patrón exacto que
-- web_pending_pickups (059) — security definer, filtro de sede/rol resuelto
-- DENTRO de la función (no en RLS, por el mismo motivo estructural: admin
-- sin Sede 25/37/Depósito en profile_locations necesita ver TODO igual).
--
-- Auditoría previa (antes de escribir una sola línea de código, tal como se
-- pidió) sobre qué existe hoy para cubrir cada estado del historial:
--
--   - DELIVERED (pickup): delivered_at/delivered_by YA existen en sales
--     (20260201000054) con su propio CHECK de consistencia
--     (sales_delivered_consistency) — se usan tal cual, no se agrega nada.
--   - SHIPPED: el modelo actual NO tiene una columna shipped_at ni un actor
--     separado de "quién despachó". fn_create_sale_core (055) marca
--     fulfillment_status='SHIPPED' en el mismo instante de crear el pedido
--     (comentario textual del enum en 054: "SHIPPED se asigna una única vez,
--     en el momento de crear un pedido SHIPPING — el envío ya salió de
--     Depósito de inmediato"). No hay ninguna fecha de envío distinta de
--     sold_at, ni ningún registro de un "shipped_by" distinto del vendedor
--     que cargó la venta (seller_id). Conclusión de la auditoría: NO se
--     inventa una columna nueva. sold_at ES la fecha de envío (coinciden
--     por diseño); delivered_at/delivered_by quedan NULL siempre para
--     SHIPPING (lo exige sales_delivered_consistency) — el frontend decide
--     qué mostrar según fulfillment_type, esta RPC solo expone las
--     columnas reales, nunca fabrica un valor.
--   - CANCELLED: sales.status='cancelled' + cancelled_at/cancelled_by/
--     cancellation_reason YA existen de forma genérica desde el primer
--     schema de ventas (20260101000006) — cancel_sale (055) los llena
--     igual para un pedido Web que para uno presencial, y NUNCA toca
--     fulfillment_status al cancelar (puede quedar en cualquier estado
--     previo: PENDING_PICKUP, DELIVERED o SHIPPED). Por eso el filtro de
--     Historial usa status='cancelled' como eje independiente de
--     fulfillment_status — cubre un pickup cancelado antes de retirar, uno
--     cancelado después de entregado, y un envío cancelado.
--
-- display_status (columna calculada, nunca persistida): 'CANCELLED' si
-- status='cancelled' (sin importar fulfillment_status), si no
-- fulfillment_status tal cual ('DELIVERED' o 'SHIPPED'). Nunca aparece acá
-- 'PENDING_PICKUP' confirmado — esos pedidos siguen exclusivamente en
-- Notificaciones (BLOQUE D); un pickup PENDING_PICKUP cancelado sí entra acá
-- como CANCELLED (dejó de estar pendiente).
--
-- Filtros: sede (location_id — cubre pickup_location_id para PICKUP y
-- Depósito para SHIPPING, ambos caben en location_id), estado
-- (display_status), rango de fecha (sold_at, mismo criterio que el filtro
-- from/to de /ventas), búsqueda libre (número de venta / cliente / DNI).
-- Paginación: limit/offset con total_count vía count(*) over() en la misma
-- query (un solo round-trip, nunca un segundo select count(*) aparte).
-- limit se clampea a 100 como tope duro contra un límite mal pasado desde
-- el cliente.
-- =============================================================================

create or replace function public.web_order_history(
  p_location_id uuid default null,
  p_status text default null,
  p_date_from timestamptz default null,
  p_date_to timestamptz default null,
  p_search text default null,
  p_limit int default 30,
  p_offset int default 0
)
returns table (
  sale_id uuid,
  sale_number text,
  sold_at timestamptz,
  customer_name text,
  customer_dni text,
  items jsonb,
  total numeric,
  payment_method_name text,
  payment_status public.sale_payment_status,
  fulfillment_type public.sale_fulfillment_type,
  display_status text,
  location_id uuid,
  location_code text,
  location_name text,
  delivered_at timestamptz,
  delivered_by_name text,
  cancelled_at timestamptz,
  cancelled_by_name text,
  cancellation_reason text,
  seller_name text,
  total_count bigint
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_profile public.profiles;
  v_see_all boolean;
  v_limit int;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if p_status is not null and p_status not in ('DELIVERED', 'SHIPPED', 'CANCELLED') then
    raise exception 'Estado de historial inválido: %.', p_status;
  end if;

  v_see_all := v_profile.role = 'admin';
  v_limit := least(greatest(coalesce(p_limit, 30), 1), 100);

  return query
  select
    s.id,
    s.sale_number,
    s.sold_at,
    c.full_name,
    c.dni,
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'product_name', p.name,
            'quantity', si.quantity,
            'is_kit', p.product_type = 'kit'
          )
          order by p.name
        )
        from public.sale_items si
        join public.products p on p.id = si.product_id
        where si.sale_id = s.id
      ),
      '[]'::jsonb
    ) as items,
    s.total,
    pm.name,
    s.payment_status,
    s.fulfillment_type,
    case when s.status = 'cancelled' then 'CANCELLED' else s.fulfillment_status::text end as display_status,
    s.location_id,
    sl.code,
    sl.name,
    s.delivered_at,
    delivered_by_profile.full_name,
    s.cancelled_at,
    cancelled_by_profile.full_name,
    s.cancellation_reason,
    seller.full_name,
    count(*) over ()
  from public.sales s
  join public.sales_channels ch on ch.id = s.sales_channel_id and ch.code = 'WEB'
  join public.payment_methods pm on pm.id = s.payment_method_id
  join public.stock_locations sl on sl.id = s.location_id
  join public.profiles seller on seller.id = s.seller_id
  left join public.customers c on c.id = s.customer_id
  left join public.profiles delivered_by_profile on delivered_by_profile.id = s.delivered_by
  left join public.profiles cancelled_by_profile on cancelled_by_profile.id = s.cancelled_by
  where s.fulfillment_type is not null
    and (s.status = 'cancelled' or s.fulfillment_status in ('DELIVERED', 'SHIPPED'))
    and (v_see_all or public.has_location_access(s.location_id))
    and (p_location_id is null or s.location_id = p_location_id)
    and (
      p_status is null
      or (p_status = 'CANCELLED' and s.status = 'cancelled')
      or (p_status <> 'CANCELLED' and s.status <> 'cancelled' and s.fulfillment_status::text = p_status)
    )
    and (p_date_from is null or s.sold_at >= p_date_from)
    and (p_date_to is null or s.sold_at <= p_date_to)
    and (
      p_search is null or trim(p_search) = ''
      or s.sale_number ilike '%' || p_search || '%'
      or c.full_name ilike '%' || p_search || '%'
      or c.dni ilike '%' || p_search || '%'
    )
  order by s.sold_at desc
  limit v_limit offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

comment on function public.web_order_history(uuid, text, timestamptz, timestamptz, text, int, int) is
  'Historial de pedidos Web (BLOQUE E): DELIVERED, SHIPPED y CANCELLED — nunca PENDING_PICKUP '
  'confirmado (eso sigue en Notificaciones/web_pending_pickups). admin ve todas las sedes sin '
  'depender de profile_locations; vendedor/viewer solo su(s) sede(s) real(es) '
  '(has_location_access). Sin tabla paralela: se deriva de sales/sale_items/products/profiles/'
  'customers. Paginado (limit clampeado a 100, offset) con total_count vía count(*) over() en la '
  'misma query — un solo round-trip. SHIPPED nunca tiene delivered_at/delivered_by (no existe una '
  'fecha/actor de envío separados en el modelo — sold_at coincide con el envío por diseño, ver '
  'comentario de la migración); el frontend decide qué mostrar según fulfillment_type, esta RPC '
  'nunca fabrica un valor que no esté en la base.';

-- ---------------------------------------------------------------------------
-- Índice de soporte: mismo criterio que sales_pickup_pending_idx (054) pero
-- para el conjunto de Historial (delivered/shipped/cancelled), filtrado por
-- sede y ordenado por fecha — cubre el WHERE + ORDER BY de arriba sin
-- escanear toda la tabla sales a medida que crece.
-- ---------------------------------------------------------------------------
create index sales_web_history_idx
  on public.sales (location_id, sold_at desc)
  where fulfillment_type is not null;

comment on index public.sales_web_history_idx is
  'Cubre web_order_history(): fulfillment_type is not null, filtrado por location_id y ordenado '
  'por sold_at. No filtra por status/fulfillment_status en la definición del índice (cambian con '
  'el tiempo — DELIVERED/CANCELLED se alcanzan después de creado el pedido) para que un único '
  'índice sirva tanto a Notificaciones (fulfillment_status=PENDING_PICKUP) como a Historial.';
