-- =============================================================================
-- Maguirejuve · 16 · Canal Web: seller_id nullable + create_web_order()
-- =============================================================================
-- Un pedido importado automáticamente desde una integración externa (POST
-- /api/integrations/web-orders) no tiene una vendedora humana detrás. En vez de
-- inventar un usuario "sistema" en auth.users, permitimos seller_id nulo:
-- esas ventas solo son visibles para admin (la policy sales_select ya contempla
-- is_admin() como condición independiente de seller_id = auth.uid()).

alter table public.sales alter column seller_id drop not null;

-- ---------------------------------------------------------------------------
-- Refactor: la lógica de create_sale() se extrae a un núcleo compartido,
-- parametrizado por seller_id (nullable), para no duplicarla entre
-- create_sale() (usuario logueado) y create_web_order() (integración server-to-server).
-- ---------------------------------------------------------------------------
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
  p_sold_at timestamptz
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
begin
  if not exists (select 1 from public.stock_locations where id = p_location_id and active) then
    raise exception 'La sucursal seleccionada no existe o está inactiva.';
  end if;

  if not exists (select 1 from public.sales_channels where id = p_sales_channel_id and active) then
    raise exception 'El canal de venta seleccionado no existe o está inactivo.';
  end if;

  if not exists (select 1 from public.payment_methods where id = p_payment_method_id and active) then
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

  if p_external_source is not null and p_external_order_id is not null
     and exists (
       select 1 from public.sales
       where external_source = p_external_source and external_order_id = p_external_order_id
     ) then
    raise exception 'Este pedido externo ya fue importado (%: %).', p_external_source, p_external_order_id;
  end if;

  select * into v_settings from public.app_settings where id = 1;
  v_allow_negative := coalesce(v_settings.allow_negative_stock, false);

  v_quote := public.fn_pricing_quote(p_items, p_payment_method_id, p_sold_at);
  if not (v_quote ->> 'ok')::boolean then
    raise exception '%', v_quote ->> 'error_message';
  end if;

  if p_doctor_id is not null then
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
    external_source, external_order_id, notes
  ) values (
    v_sale_number, p_sold_at, p_location_id, p_sales_channel_id, p_seller_id,
    p_customer_id, p_doctor_id, p_payment_method_id, (v_quote ->> 'applied_price_condition_id')::uuid,
    (v_quote ->> 'subtotal')::numeric, (v_quote ->> 'discount_total')::numeric,
    (v_quote ->> 'total')::numeric, v_commission_total, 'confirmed',
    p_external_source, p_external_order_id, p_notes
  )
  returning id into v_sale_id;

  for v_line in select * from jsonb_array_elements(v_quote -> 'lines')
  loop
    insert into public.sale_items (
      sale_id, product_id, quantity, list_unit_price, sale_unit_price,
      line_list_total, line_discount, line_total, applied_price_condition_id, commissionable
    ) values (
      v_sale_id,
      (v_line ->> 'product_id')::uuid,
      (v_line ->> 'quantity')::numeric,
      (v_line ->> 'list_unit_price')::numeric,
      (v_line ->> 'sale_unit_price')::numeric,
      (v_line ->> 'line_list_total')::numeric,
      (v_line ->> 'line_discount')::numeric,
      (v_line ->> 'line_total')::numeric,
      (v_line ->> 'applied_price_condition_id')::uuid,
      (v_line ->> 'commissionable')::boolean
    );
  end loop;

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

  return jsonb_build_object(
    'sale_id', v_sale_id,
    'sale_number', v_sale_number,
    'total', (v_quote ->> 'total')::numeric,
    'subtotal', (v_quote ->> 'subtotal')::numeric,
    'discount_total', (v_quote ->> 'discount_total')::numeric,
    'commission_total', v_commission_total,
    'applied_price_condition_name', v_quote ->> 'applied_price_condition_name',
    'explanation', v_quote ->> 'explanation',
    'lines', v_quote -> 'lines'
  );
end;
$$;

-- create_sale(): valida el usuario logueado y delega en el núcleo compartido.
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
  p_sold_at timestamptz default now()
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

  if not public.has_location_access(p_location_id) then
    raise exception 'Tu usuario no tiene acceso a esta sucursal.';
  end if;

  return public.fn_create_sale_core(
    auth.uid(), p_items, p_location_id, p_sales_channel_id, p_payment_method_id,
    p_customer_id, p_doctor_id, p_notes, p_external_source, p_external_order_id, p_sold_at
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- create_web_order(): exclusivo de integraciones server-to-server (POST
-- /api/integrations/web-orders), llamado con la service_role key — NUNCA
-- expuesto a `authenticated`/`anon`. external_source/external_order_id son
-- obligatorios acá (es lo que garantiza la idempotencia del import).
-- ---------------------------------------------------------------------------
create or replace function public.create_web_order(
  p_items jsonb,
  p_location_id uuid,
  p_payment_method_id uuid,
  p_external_source text,
  p_external_order_id text,
  p_customer_id uuid default null,
  p_doctor_id uuid default null,
  p_notes text default null,
  p_sold_at timestamptz default now()
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
    p_customer_id, p_doctor_id, p_notes, p_external_source, p_external_order_id, p_sold_at
  );
end;
$$;

comment on function public.create_web_order is
  'Exclusivo de integraciones server-to-server autenticadas con service_role (ver '
  'app/api/integrations/web-orders/route.ts). No se otorga a authenticated/anon a propósito.';

-- IMPORTANTE: Postgres otorga EXECUTE a PUBLIC por defecto en toda función nueva.
-- Hay que revocarlo explícitamente para que create_web_order sea inalcanzable
-- desde el navegador (authenticated/anon) y solo la use el service_role.
revoke execute on function public.create_web_order(
  jsonb, uuid, uuid, text, text, uuid, uuid, text, timestamptz
) from public;
grant execute on function public.create_web_order(
  jsonb, uuid, uuid, text, text, uuid, uuid, text, timestamptz
) to service_role;

-- fn_create_sale_core tampoco debe ser invocable directamente por un usuario final.
revoke execute on function public.fn_create_sale_core(
  uuid, jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz
) from public;

-- ---------------------------------------------------------------------------
-- Hardening retroactivo: Postgres otorga EXECUTE a PUBLIC por defecto. Las
-- funciones SECURITY DEFINER "internas" (helpers usados por las RPC públicas,
-- nunca pensadas para invocarse directo) deben quedar inalcanzables desde
-- authenticated/anon. El dueño de la función (quien corrió las migrations)
-- conserva su propio privilegio de ejecución igual, así que create_sale(),
-- cancel_sale(), etc. siguen pudiendo llamarlas internamente sin problema.
-- ---------------------------------------------------------------------------
revoke execute on function public.fn_pricing_quote(jsonb, uuid, timestamptz) from public;
revoke execute on function public.fn_apply_stock_movement(
  uuid, uuid, public.stock_movement_type, numeric, uuid, uuid, text,
  public.stock_adjustment_reason, text, uuid, boolean
) from public;
revoke execute on function public.fn_next_sale_number(uuid, timestamptz) from public;
