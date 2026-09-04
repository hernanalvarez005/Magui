-- =============================================================================
-- Maguirejuve · 59 · Circuito Ventas Web — BLOQUE D: bandeja de Notificaciones
-- (pedidos Web pendientes de retiro) + contador
-- =============================================================================
-- Definición acordada: NO se crea una tabla `notifications` — la bandeja se
-- deriva directo de `sales` (canal WEB + fulfillment_type=PICKUP +
-- fulfillment_status=PENDING_PICKUP), exactamente como sale_stock_
-- reservations se decidió como la única fuente de verdad para reservas en
-- BLOQUE A. Una única RPC (`web_pending_pickups`) sirve TANTO al contador
-- de navegación (el layout toma length(resultado)) COMO a la pantalla de
-- Notificaciones (mismo resultado, sin volver a filtrar) — una sola fuente
-- de verdad, cero lógica duplicada entre "contar" y "listar".
--
-- Por qué es una RPC (security definer) y no un select directo con RLS:
-- sales_select ya exige has_location_access(location_id) inclusive para
-- admin (mismo motivo estructural que obligó a web_admin_stock_availability
-- en 20260201000058) — un admin sin Sede 25/37 en profile_locations vería
-- la bandeja vacía aunque el pedido exista y sea perfectamente válido. Acá
-- la regla de visibilidad se decide DENTRO de la función:
--   - admin: ve TODOS los pendientes de retiro (Sede 25 + Sede 37), sin
--     depender de profile_locations — igual que ya puede crear/entregar
--     cualquiera de los dos (057/058).
--   - vendedor/viewer: solo ve los de la(s) sede(s) donde tiene acceso real
--     (has_location_access(pickup_location_id)) — Sede 25 ve solo Sede 25,
--     Sede 37 ve solo Sede 37. Viewer se deja pasar (rol de solo lectura,
--     puede consultar la bandeja igual que consulta todo lo demás) — la
--     acción de cobrar/entregar la sigue rechazando mark_web_order_paid/
--     deliver_web_pickup, esta RPC no escribe nada.
--
-- Filtro (los 3 ejes pedidos, ninguno opcional):
--   - status = 'confirmed' (excluye canceladas — un pickup pendiente SE
--     PUEDE cancelar con cancel_sale, que libera la reserva pero nunca
--     mueve fulfillment_status; sin este filtro una venta cancelada
--     seguiría apareciendo en la bandeja).
--   - fulfillment_type = 'PICKUP' (nunca SHIPPING — un envío queda
--     fulfillment_status=SHIPPED desde el instante en que se crea, jamás
--     pasa por PENDING_PICKUP, así que este filtro es redundante con el
--     siguiente pero se deja explícito por legibilidad).
--   - fulfillment_status = 'PENDING_PICKUP' (nunca DELIVERED — un pedido ya
--     entregado desaparece de acá; queda para el historial de BLOQUE
--     siguiente, ver comentario al final).
--
-- Datos devueltos: los 10 campos pedidos (número de venta, fecha, cliente,
-- DNI, productos/kits y cantidades, total, forma de pago, payment_status,
-- sede de retiro, quién cargó la venta) en una ÚNICA query — sale_items +
-- products se agregan con jsonb_agg en un subselect correlacionado por
-- sale_id (no es un loop del lado de la aplicación: es una sola sentencia
-- SQL que Postgres resuelve con un solo plan, sin N+1 real). seller_id es
-- NOT NULL en sales (create_web_order, el único camino con seller_id NULL,
-- nunca pasa fulfillment_type — 20260101000016 — así que un inner join
-- contra profiles para "quién cargó la venta" es seguro acá).
--
-- Historial de entregados (siguiente bloque): a propósito esta función NO
-- recibe un parámetro de status — mantenerla fija a PENDING_PICKUP es lo
-- que pidió el usuario para este bloque. Cuando se implemente el historial,
-- la forma más simple de reusar esto es una función hermana con el mismo
-- SELECT y fulfillment_status IN ('DELIVERED') en vez de duplicar toda la
-- lógica de joins/agregación a mano — no se hace ahora para no adelantar
-- alcance sin pedido explícito, pero la estructura (mismo shape de fila,
-- mismos joins) queda lista para eso.
-- =============================================================================

create or replace function public.web_pending_pickups()
returns table (
  sale_id uuid,
  sale_number text,
  sold_at timestamptz,
  customer_name text,
  customer_dni text,
  items jsonb,
  total numeric,
  payment_method_id uuid,
  payment_method_name text,
  payment_account_id uuid,
  payment_status public.sale_payment_status,
  pickup_location_id uuid,
  pickup_location_code text,
  pickup_location_name text,
  seller_name text
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_profile public.profiles;
  v_see_all boolean;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  v_see_all := v_profile.role = 'admin';

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
    s.payment_method_id,
    pm.name,
    s.payment_account_id,
    s.payment_status,
    s.pickup_location_id,
    sl.code,
    sl.name,
    seller.full_name
  from public.sales s
  join public.sales_channels ch on ch.id = s.sales_channel_id and ch.code = 'WEB'
  join public.payment_methods pm on pm.id = s.payment_method_id
  join public.stock_locations sl on sl.id = s.pickup_location_id
  join public.profiles seller on seller.id = s.seller_id
  left join public.customers c on c.id = s.customer_id
  where s.status = 'confirmed'
    and s.fulfillment_type = 'PICKUP'
    and s.fulfillment_status = 'PENDING_PICKUP'
    and (v_see_all or public.has_location_access(s.pickup_location_id))
  order by s.sold_at asc;
end;
$$;

comment on function public.web_pending_pickups() is
  'Bandeja de Notificaciones (BLOQUE D): pedidos Web PICKUP pendientes de retiro. Nunca crea una '
  'tabla notifications — se deriva de sales/sale_items/products, agregados en una sola query (sin '
  'N+1). admin ve todos (Sede 25 + Sede 37) sin depender de profile_locations, igual que ya puede '
  'crear/entregar cualquiera (057/058); vendedor/viewer solo ve su(s) sede(s) reales '
  '(has_location_access). Misma fuente para el contador de navegación (length del resultado) y para '
  'el listado completo — nunca se duplica el filtro en dos lugares.';
