-- =============================================================================
-- Maguirejuve · 41 · Facturación pendiente: create_sale + marcar facturada (Bloque A)
-- =============================================================================
-- Regla de negocio (nunca la decide el frontend, siempre el backend):
--   IF is_free_sale: NOT_REQUIRED
--   ELIF payment_method.code IN ('TRANSFER','CARD_1','CARD_3'):
--     requiere payment_account_id (activa) Y cliente con DNI -> PENDING
--   ELSE: NOT_REQUIRED (payment_account_id se fuerza a null)
--
-- Mismo patrón ya usado para is_free_sale/stock_skipped: un parámetro nuevo
-- al final de fn_create_sale_core/create_sale con default, sin romper
-- ningún llamador existente (supabase-js manda parámetros por nombre).
--
-- Postgres NO reemplaza una función al agregarle un parámetro nuevo —
-- CREATE OR REPLACE solo pisa una firma IDÉNTICA, así que agregar un
-- parámetro sin dropear antes la firma vieja deja las dos funciones
-- coexistiendo (ambigüedad de sobrecarga). Se dropean las firmas anteriores
-- primero, igual que ya se hizo en 20260201000015_backdated_sales.sql.
drop function if exists public.fn_create_sale_core(
  uuid, jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text, boolean
);
drop function if exists public.create_sale(
  jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text, boolean
);

create or replace function public.fn_create_sale_core(
  p_seller_id uuid,
  p_items jsonb,
  p_location_id uuid,
  p_sales_channel_id uuid,
  p_payment_method_id uuid,
  p_customer_id uuid,
  p_doctor_id uuid,
  p_notes text,
  p_external_source text,
  p_external_order_id text,
  p_sold_at timestamptz,
  p_is_free_sale boolean default false,
  p_free_sale_reason public.free_sale_reason default null,
  p_free_sale_notes text default null,
  p_skip_stock_movement boolean default false,
  p_payment_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings public.app_settings;
  v_quote jsonb;
  v_sale_id uuid;
  v_sale_number text;
  v_commission_percent numeric := 0;
  v_commission_total numeric := 0;
  v_line jsonb;
  v_required record;
  v_allow_negative boolean;
  v_payment_method_code text;
  v_requires_billing boolean;
  v_billing_status public.sale_billing_status;
  v_payment_account_id uuid;
begin
  if not exists (select 1 from public.stock_locations where id = p_location_id and active) then
    raise exception 'La sucursal seleccionada no existe o está inactiva.';
  end if;

  if not exists (select 1 from public.sales_channels where id = p_sales_channel_id and active) then
    raise exception 'El canal de venta seleccionado no existe o está inactivo.';
  end if;

  select code into v_payment_method_code from public.payment_methods where id = p_payment_method_id and active;
  if v_payment_method_code is null then
    raise exception 'El medio de pago seleccionado no existe o está inactivo.';
  end if;

  if p_customer_id is not null and not exists (
    select 1 from public.customers where id = p_customer_id and active
  ) then
    raise exception 'El cliente seleccionado no existe.';
  end if;

  if p_doctor_id is not null and not exists (
    select 1 from public.doctors where id = p_doctor_id and active
  ) then
    raise exception 'La doctora seleccionada no existe o está inactiva.';
  end if;

  if p_is_free_sale and p_free_sale_reason is null then
    raise exception 'Una entrega sin costo necesita un motivo (regalo, muestra, canje, cortesía u otro).';
  end if;

  -- Backdatear una venta (más de 1 hora de margen operativo) y saltear el
  -- movimiento de stock son exclusivos de admin — ver comentario arriba.
  if p_sold_at < now() - interval '1 hour' and not public.is_admin() then
    raise exception 'Solo un administrador puede cargar una venta con fecha anterior.';
  end if;

  if p_skip_stock_movement and not public.is_admin() then
    raise exception 'Solo un administrador puede cargar una venta sin descontar stock.';
  end if;

  if p_skip_stock_movement and p_is_free_sale then
    raise exception 'Una entrega sin costo siempre descuenta stock — no se puede combinar con carga histórica.';
  end if;

  -- ---------------------------------------------------------------------------
  -- Facturación pendiente: se resuelve acá, SIEMPRE en base a la forma de
  -- pago real (nunca un flag que mande el frontend). Efectivo y venta sin
  -- costo no requieren cuenta ni control de facturación.
  -- ---------------------------------------------------------------------------
  v_requires_billing := not p_is_free_sale and v_payment_method_code in ('TRANSFER', 'CARD_1', 'CARD_3');

  if v_requires_billing then
    if p_payment_account_id is null or not exists (
      select 1 from public.payment_accounts where id = p_payment_account_id and active
    ) then
      raise exception 'Esta forma de pago requiere indicar la cuenta donde ingresó el dinero.';
    end if;

    if p_customer_id is null or not exists (
      select 1 from public.customers
      where id = p_customer_id and dni is not null and trim(dni) <> ''
    ) then
      raise exception
        'Esta operación se puede facturar, así que necesita un cliente identificado con nombre y DNI.';
    end if;

    v_payment_account_id := p_payment_account_id;
    v_billing_status := 'PENDING';
  else
    -- La cuenta de ingreso es un concepto aparte del medio de pago — si no
    -- corresponde (efectivo/sin costo), nunca se guarda, aunque el frontend
    -- la haya mandado por error.
    v_payment_account_id := null;
    v_billing_status := 'NOT_REQUIRED';
  end if;

  if p_external_source is not null and p_external_order_id is not null
     and exists (
       select 1 from public.sales
       where external_source = p_external_source and external_order_id = p_external_order_id
     ) then
    raise exception 'Este pedido externo ya fue importado (%: %).', p_external_source, p_external_order_id;
  end if;

  select * into v_settings from public.app_settings where id = 1;
  v_allow_negative := coalesce(v_settings.allow_negative_stock, false);

  v_quote := public.fn_pricing_quote(p_items, p_payment_method_id, p_sold_at, p_is_free_sale);
  if not (v_quote ->> 'ok')::boolean then
    raise exception '%', v_quote ->> 'error_message';
  end if;

  -- Comisión SIEMPRE 0 en una entrega sin costo, sin importar la doctora
  -- seleccionada (fn_pricing_quote ya marcó todas las líneas no comisionables,
  -- esto es una segunda barrera explícita). Una venta histórica sin stock SÍ
  -- genera comisión normal — es una venta real, solo que ya despachada.
  if not p_is_free_sale and p_doctor_id is not null then
    select commission_percent into v_commission_percent from public.doctors where id = p_doctor_id;
  end if;

  select coalesce(sum((line ->> 'line_total')::numeric), 0)
  into v_commission_total
  from jsonb_array_elements(v_quote -> 'lines') line
  where (line ->> 'commissionable')::boolean = true;

  v_commission_total := round(v_commission_total * v_commission_percent, 2);

  v_sale_number := public.fn_next_sale_number(p_location_id, p_sold_at);

  insert into public.sales (
    sale_number, sold_at, location_id, sales_channel_id, seller_id,
    customer_id, doctor_id, payment_method_id, applied_price_condition_id,
    subtotal, discount_total, total, commission_total, status,
    external_source, external_order_id, notes,
    is_free_sale, free_sale_reason, free_sale_notes, stock_skipped,
    payment_account_id, billing_status
  ) values (
    v_sale_number, p_sold_at, p_location_id, p_sales_channel_id, p_seller_id,
    p_customer_id, p_doctor_id, p_payment_method_id, (v_quote ->> 'applied_price_condition_id')::uuid,
    (v_quote ->> 'subtotal')::numeric, (v_quote ->> 'discount_total')::numeric,
    (v_quote ->> 'total')::numeric, v_commission_total, 'confirmed',
    p_external_source, p_external_order_id, p_notes,
    p_is_free_sale, p_free_sale_reason, p_free_sale_notes, p_skip_stock_movement,
    v_payment_account_id, v_billing_status
  )
  returning id into v_sale_id;

  for v_line in select * from jsonb_array_elements(v_quote -> 'lines')
  loop
    insert into public.sale_items (
      sale_id, product_id, quantity, list_unit_price, sale_unit_price,
      line_list_total, line_discount, line_total, applied_price_condition_id, commissionable,
      applied_promotion_id, promotion_discount
    ) values (
      v_sale_id,
      (v_line ->> 'product_id')::uuid,
      (v_line ->> 'quantity')::numeric,
      (v_line ->> 'list_unit_price')::numeric,
      (v_line ->> 'sale_unit_price')::numeric,
      (v_line ->> 'line_list_total')::numeric,
      (v_line ->> 'line_discount')::numeric,
      (v_line ->> 'line_total')::numeric,
      nullif(v_line ->> 'applied_price_condition_id', '')::uuid,
      (v_line ->> 'commissionable')::boolean,
      nullif(v_line ->> 'applied_promotion_id', '')::uuid,
      coalesce((v_line ->> 'promotion_discount')::numeric, 0)
    );
  end loop;

  if not p_skip_stock_movement then
    for v_required in
      with items as (
        select (elem ->> 'product_id')::uuid as product_id, (elem ->> 'quantity')::numeric as quantity
        from jsonb_array_elements(p_items) elem
      ),
      expanded as (
        select i.product_id, i.quantity as required_qty
        from items i
        join public.products p on p.id = i.product_id and p.track_stock = true
        union all
        select kc.component_product_id, i.quantity * kc.quantity as required_qty
        from items i
        join public.products p on p.id = i.product_id and p.track_stock = false
        join public.kit_components kc on kc.kit_product_id = i.product_id
      )
      select product_id, sum(required_qty) as required_qty
      from expanded
      group by product_id
      order by product_id
    loop
      perform public.fn_apply_stock_movement(
        p_location_id => p_location_id,
        p_product_id => v_required.product_id,
        p_movement_type => 'SALE',
        p_quantity_delta => -v_required.required_qty,
        p_sale_id => v_sale_id,
        p_reference => v_sale_number,
        p_created_by => p_seller_id,
        p_allow_negative => v_allow_negative
      );
    end loop;
  end if;

  return jsonb_build_object(
    'sale_id', v_sale_id,
    'sale_number', v_sale_number,
    'total', (v_quote ->> 'total')::numeric,
    'subtotal', (v_quote ->> 'subtotal')::numeric,
    'discount_total', (v_quote ->> 'discount_total')::numeric,
    'commission_total', v_commission_total,
    'applied_price_condition_name', v_quote ->> 'applied_price_condition_name',
    'explanation', v_quote ->> 'explanation',
    'is_free_sale', p_is_free_sale,
    'stock_skipped', p_skip_stock_movement,
    'billing_status', v_billing_status,
    'lines', v_quote -> 'lines'
  );
end;
$$;

revoke execute on function public.fn_create_sale_core(
  uuid, jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text, boolean, uuid
) from public;

-- ---------------------------------------------------------------------------
create or replace function public.create_sale(
  p_items jsonb,
  p_location_id uuid,
  p_sales_channel_id uuid,
  p_payment_method_id uuid,
  p_customer_id uuid default null,
  p_doctor_id uuid default null,
  p_notes text default null,
  p_external_source text default null,
  p_external_order_id text default null,
  p_sold_at timestamptz default now(),
  p_is_free_sale boolean default false,
  p_free_sale_reason public.free_sale_reason default null,
  p_free_sale_notes text default null,
  p_skip_stock_movement boolean default false,
  p_payment_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede cargar ventas.';
  end if;

  if not public.has_location_access(p_location_id) then
    raise exception 'Tu usuario no tiene acceso a esta sucursal.';
  end if;

  return public.fn_create_sale_core(
    auth.uid(), p_items, p_location_id, p_sales_channel_id, p_payment_method_id,
    p_customer_id, p_doctor_id, p_notes, p_external_source, p_external_order_id, p_sold_at,
    p_is_free_sale, p_free_sale_reason, p_free_sale_notes, p_skip_stock_movement,
    p_payment_account_id
  );
end;
$$;

grant execute on function public.create_sale(
  jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text, boolean, uuid
) to authenticated;

-- ---------------------------------------------------------------------------
-- mark_sale_invoiced / mark_sale_pending: exclusivo de admin. Nunca vía
-- policy de UPDATE directa sobre sales (no existe ninguna) — mismo patrón
-- que cancel_sale: SECURITY DEFINER, valida adentro, audita.
-- ---------------------------------------------------------------------------
create or replace function public.mark_sale_invoiced(p_sale_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sale public.sales;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede marcar una venta como facturada.';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;
  if v_sale is null then
    raise exception 'La venta no existe.';
  end if;

  if v_sale.status <> 'confirmed' then
    raise exception 'Una venta anulada no se puede marcar como facturada.';
  end if;

  if v_sale.billing_status = 'INVOICED' then
    raise exception 'Esta venta ya está facturada.';
  end if;

  if v_sale.billing_status = 'NOT_REQUIRED' then
    raise exception 'Esta venta no requiere facturación.';
  end if;

  update public.sales
  set billing_status = 'INVOICED', invoiced_at = now(), invoiced_by = auth.uid()
  where id = p_sale_id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'mark_sale_invoiced', 'sales', p_sale_id,
    jsonb_build_object('previous_status', v_sale.billing_status, 'new_status', 'INVOICED')
  );

  return jsonb_build_object('sale_id', p_sale_id, 'billing_status', 'INVOICED');
end;
$$;

comment on function public.mark_sale_invoiced(uuid) is
  'Exclusivo de admin. No cambia sales.status (comercial) — solo el workflow de facturación.';

grant execute on function public.mark_sale_invoiced(uuid) to authenticated;

create or replace function public.mark_sale_pending(p_sale_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sale public.sales;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede revertir una facturación marcada por error.';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;
  if v_sale is null then
    raise exception 'La venta no existe.';
  end if;

  if v_sale.billing_status <> 'INVOICED' then
    raise exception 'Esta venta no está facturada — no hay nada que revertir.';
  end if;

  update public.sales
  set billing_status = 'PENDING', invoiced_at = null, invoiced_by = null
  where id = p_sale_id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'mark_sale_pending', 'sales', p_sale_id,
    jsonb_build_object('previous_status', 'INVOICED', 'new_status', 'PENDING')
  );

  return jsonb_build_object('sale_id', p_sale_id, 'billing_status', 'PENDING');
end;
$$;

comment on function public.mark_sale_pending(uuid) is
  'Exclusivo de admin. Corrige una marcación accidental — vuelve la venta a PENDING de facturación.';

grant execute on function public.mark_sale_pending(uuid) to authenticated;
