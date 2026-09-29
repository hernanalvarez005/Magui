-- =============================================================================
-- Maguirejuve · 71 · create_web_order — circuito de pago/facturación (Checkpoint 2.1)
-- =============================================================================
-- Diagnóstico entregado al usuario (ver informe completo en la conversación):
-- create_web_order() (20260101000016) nunca se conectó al circuito de
-- fulfillment/payment_status que se construyó después (BLOQUES B/C/D,
-- migraciones 054-060) para Ventas Web administradas desde Nueva Venta. No
-- era solo que faltara payment_account_id: la tabla sales tiene un CHECK real
-- (sales_fulfillment_consistency, 20260201000054) que acopla payment_status a
-- fulfillment_type — payment_status NO PUEDE ser no-nulo sin fulfillment_type
-- también no-nulo. Por eso ninguna condición con requires_billing=true podía
-- venderse nunca por create_web_order, sin importar qué otro parámetro se le
-- agregara: faltaba fulfillment_type, no solo la cuenta.
--
-- Decisión de producto V1 (aprobada por el usuario): solo SHIPPING.
--   - SHIPPING reutiliza fn_apply_stock_movement (descuento inmediato) —
--     CERO cambio al comportamiento de stock que create_web_order ya tiene
--     hoy (a diferencia de PICKUP, que reserva vía fn_reserve_stock).
--   - SHIPPING exige location_id = Depósito (ya validado dentro de
--     fn_create_sale_core, sin cambios acá) — nunca se transforma/corrige el
--     location_id recibido; si el productor externo manda otra sede, la
--     validación existente lo rechaza tal cual.
--   - Una vez con fulfillment_type='SHIPPING', el pedido entra al mismo
--     circuito ya construido y probado que usa Nueva Venta (admin, canal
--     Web): billing_status/payment_account_id resueltos por
--     fn_create_sale_core sin ningún cambio ahí, reconciliable después por
--     mark_web_order_paid (que solo exige fulfillment_type is not null — no
--     exige específicamente PICKUP), visible en "Historial de pedidos Web"
--     (web_order_history filtra fulfillment_type is not null, sin
--     distinguir PICKUP/SHIPPING).
--   - PICKUP queda explícitamente FUERA de alcance de este checkpoint (no se
--     agrega pickup_location_id, no se expone fulfillment_type en la API
--     pública, no se diseña ninguna UI de retiro para pedidos externos).
--
-- fulfillment_type se conserva como parámetro INTERNO de la RPC (con
-- default null) para no hardcodear 'SHIPPING' dentro de PL/pgSQL y mantener
-- la función genérica — pero el contrato público de
-- POST /api/integrations/web-orders (lib/validation/web-order.ts) NUNCA lo
-- expone: el route handler es quien decide pasar 'SHIPPING' cuando el
-- payload declara payment_status, y null cuando no lo declara (comportamiento
-- histórico exacto).
--
-- fn_create_sale_core NO se toca — ya acepta p_payment_account_id/
-- p_fulfillment_type/p_payment_status desde la migración 55/57, y ya
-- implementa exactamente la semántica de negocio necesaria (PENDING no exige
-- cuenta todavía, se completa después vía mark_web_order_paid; PAID sí la
-- exige de inmediato). Cero lógica de negocio nueva en este archivo.
--
-- DROP explícito antes del CREATE OR REPLACE: mismo criterio que 069/070 —
-- Postgres identifica funciones por firma exacta, agregar parámetros al
-- final de una firma ya existente crea un overload ambiguo en vez de
-- reemplazarla.
-- ---------------------------------------------------------------------------
drop function if exists public.create_web_order(
  jsonb, uuid, uuid, text, text, uuid, uuid, text, timestamptz
);

create or replace function public.create_web_order(
  p_items jsonb,
  p_location_id uuid,
  p_payment_method_id uuid,
  p_external_source text,
  p_external_order_id text,
  p_customer_id uuid default null,
  p_doctor_id uuid default null,
  p_notes text default null,
  p_sold_at timestamptz default now(),
  p_payment_status public.sale_payment_status default null,
  p_payment_account_id uuid default null,
  p_fulfillment_type public.sale_fulfillment_type default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_web_channel_id uuid;
begin
  if p_external_source is null or trim(p_external_source) = '' then
    raise exception 'external_source es obligatorio para pedidos del canal Web.';
  end if;
  if p_external_order_id is null or trim(p_external_order_id) = '' then
    raise exception 'external_order_id es obligatorio para pedidos del canal Web.';
  end if;

  select id into v_web_channel_id from public.sales_channels where code = 'WEB';
  if v_web_channel_id is null then
    raise exception 'El canal Web no está configurado.';
  end if;

  return public.fn_create_sale_core(
    null, p_items, p_location_id, v_web_channel_id, p_payment_method_id,
    p_customer_id, p_doctor_id, p_notes, p_external_source, p_external_order_id, p_sold_at,
    false, null, null, false,
    p_payment_account_id, p_fulfillment_type, p_payment_status
  );
end;
$$;

comment on function public.create_web_order(
  jsonb, uuid, uuid, text, text, uuid, uuid, text, timestamptz,
  public.sale_payment_status, uuid, public.sale_fulfillment_type
) is
  'Exclusivo de integraciones server-to-server autenticadas con service_role (ver '
  'app/api/integrations/web-orders/route.ts). No se otorga a authenticated/anon a propósito. '
  'p_payment_status/p_payment_account_id/p_fulfillment_type (migración 71, Checkpoint 2.1): '
  'opcionales, default null — un caller que no los manda ve el comportamiento histórico exacto '
  '(idéntico a antes de esta migración). El route handler nunca expone fulfillment_type en el '
  'contrato público: decide "SHIPPING" internamente solo cuando el payload declara payment_status. '
  'PICKUP no está soportado por este camino (fuera de alcance del Checkpoint 2.1) — solo Nueva '
  'Venta (create_sale, admin) puede crear un pedido Web PICKUP.';

-- Mismo hardening que la definición original (20260101000016): la firma
-- vieja ya no existe (DROP de arriba), acá se repite el mismo patrón de
-- revoke/grant para la firma nueva.
revoke execute on function public.create_web_order(
  jsonb, uuid, uuid, text, text, uuid, uuid, text, timestamptz,
  public.sale_payment_status, uuid, public.sale_fulfillment_type
) from public;
grant execute on function public.create_web_order(
  jsonb, uuid, uuid, text, text, uuid, uuid, text, timestamptz,
  public.sale_payment_status, uuid, public.sale_fulfillment_type
) to service_role;

-- =============================================================================
-- Bug real encontrado al probar el recorrido completo de "2 cuotas sin
-- interés" por Web (Sección L, caso L17b): mark_web_order_paid()
-- (20260201000057) NUNCA se actualizó en la migración 69 — sigue usando el
-- mismo IN hardcodeado que fn_create_sale_core/create_sale_exchange tenían
-- ANTES de convertirse en data-driven:
--
--   v_requires_billing := v_payment_method_code in ('TRANSFER', 'CARD_1', 'CARD_3');
--
-- Esto significa que hoy, para CUALQUIER medio con requires_billing=true que
-- no sea exactamente uno de esos 3 códigos —incluido CARD_6 (preexistente, ya
-- roto antes de este checkpoint) y cualquier condición nueva creada desde
-- /admin/condiciones-precio, incluida "2 cuotas sin interés"— cobrar un
-- pedido Web PENDING vía mark_web_order_paid nunca activa billing_status
-- (se queda en NOT_REQUIRED para siempre, en vez de pasar a PENDING) y
-- tampoco exige la cuenta de ingreso si no se pasó una al crear el pedido.
-- El pedido queda cobrado (payment_status=PAID) pero SIN la obligación de
-- facturación correcta — nunca aparecería para facturar.
--
-- Se corrige acá con el mismo patrón exacto que 20260201000069 ya estableció
-- para las otras dos funciones: leer payment_methods.requires_billing en vez
-- de un IN hardcodeado. Misma firma exacta (uuid, uuid, uuid) — CREATE OR
-- REPLACE sin DROP, no hace falta (no cambian los parámetros, ya se
-- reemplazó así mismo en 20260201000057 sobre la versión de 20260201000055).
-- =============================================================================
create or replace function public.mark_web_order_paid(
  p_sale_id uuid,
  p_payment_method_id uuid default null,
  p_payment_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_sale public.sales;
  v_payment_method_code text;
  v_requires_billing boolean;
  v_new_billing_status public.sale_billing_status;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede registrar cobros.';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale is null then
    raise exception 'El pedido no existe.';
  end if;

  if v_sale.fulfillment_type is null then
    raise exception 'Este pedido no es un pedido Web.';
  end if;

  if not (public.has_location_access(v_sale.location_id) or v_profile.role = 'admin') then
    raise exception 'Tu usuario no tiene acceso a la sede de este pedido.';
  end if;

  if v_sale.payment_status = 'PAID' then
    raise exception 'Este pedido ya está marcado como pagado.';
  end if;

  -- Migración 71 (bug real, ver comentario de cabecera arriba): requires_billing
  -- se lee de payment_methods, igual que fn_create_sale_core/create_sale_exchange
  -- desde la migración 69 — nunca más un IN hardcodeado de códigos.
  if p_payment_method_id is not null then
    select code, requires_billing into v_payment_method_code, v_requires_billing
    from public.payment_methods where id = p_payment_method_id and active;
    if v_payment_method_code is null then
      raise exception 'El medio de pago indicado no existe o está inactivo.';
    end if;
  else
    select code, requires_billing into v_payment_method_code, v_requires_billing
    from public.payment_methods where id = v_sale.payment_method_id;
  end if;

  v_requires_billing := coalesce(v_requires_billing, false);

  if v_requires_billing then
    if coalesce(p_payment_account_id, v_sale.payment_account_id) is null then
      raise exception 'Esta forma de pago requiere indicar la cuenta donde ingresó el dinero.';
    end if;
    if p_payment_account_id is not null and not exists (
      select 1 from public.payment_accounts where id = p_payment_account_id and active
    ) then
      raise exception 'La cuenta indicada no existe o está inactiva.';
    end if;
  end if;

  -- BUGFIX 57: la obligación de facturación nace ACÁ, al cobrar — nunca
  -- antes. Si el pedido se creó NOT_REQUIRED (porque estaba PENDING de
  -- cobro, ver fn_create_sale_core) y el medio de pago vigente factura,
  -- pasa a PENDING recién ahora. Si billing_status ya no fuera
  -- NOT_REQUIRED por algún motivo (no debería pasar en este flujo, pero se
  -- programa defensivo), se respeta tal cual — nunca se pisa.
  v_new_billing_status := case
    when v_requires_billing and v_sale.billing_status = 'NOT_REQUIRED' then 'PENDING'
    else v_sale.billing_status
  end;

  update public.sales
  set payment_status = 'PAID',
      payment_method_id = coalesce(p_payment_method_id, payment_method_id),
      payment_account_id = coalesce(p_payment_account_id, payment_account_id),
      billing_status = v_new_billing_status
  where id = p_sale_id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'WEB_ORDER_PAID', 'sales', p_sale_id,
    jsonb_build_object(
      'sale_id', p_sale_id, 'payment_method_id', coalesce(p_payment_method_id, v_sale.payment_method_id),
      'billing_status', v_new_billing_status
    )
  );

  return jsonb_build_object('sale_id', p_sale_id, 'payment_status', 'PAID', 'billing_status', v_new_billing_status);
end;
$$;

comment on function public.mark_web_order_paid(uuid, uuid, uuid) is
  'Cobro de un pedido Web (PENDING -> PAID). Nunca toca commission_total ni ningún otro snapshot. '
  'BUGFIX 57: activa billing_status=PENDING recién acá si el medio de pago factura y el pedido '
  'había quedado NOT_REQUIRED por estar pendiente de cobro — nunca antes, nunca lo pisa si ya '
  'venía distinto. No entrega (deliver_web_pickup es un paso aparte, que exige payment_status=PAID). '
  'Migración 71: requires_billing pasa a leerse de payment_methods (data-driven) — bug real '
  'encontrado probando el circuito Web de Condiciones de precio administrables, afectaba también a '
  'CARD_6 y a cualquier condición creada desde /admin/condiciones-precio.';
