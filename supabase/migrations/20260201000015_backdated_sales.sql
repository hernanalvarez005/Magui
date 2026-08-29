-- =============================================================================
-- Maguirejuve · 31 · Ventas con fecha anterior + carga histórica sin stock
-- =============================================================================
-- Pedido del negocio: poder cargar ventas pasadas (para completar el
-- historial) sin que descuenten del stock real, porque esa mercadería ya
-- salió hace tiempo y el stock actual no la refleja. `p_sold_at` YA existía
-- en create_sale/fn_create_sale_core desde el MVP (se usa para resolver el
-- precio vigente a esa fecha vía valid_from/valid_until), pero el frontend
-- nunca lo exponía — siempre mandaba el default now(). Acá se agrega:
--   1) La posibilidad real de elegir una fecha anterior desde la UI.
--   2) Un flag para saltear el movimiento de stock (carga histórica).
-- Ambos quedan restringidos a admin: hasta ahora CUALQUIER usuario
-- autenticado podía en teoría llamar a create_sale con un p_sold_at
-- arbitrario sin que el backend lo restringiera (la UI simplemente nunca lo
-- ofrecía) — se cierra ese hueco de una al mismo tiempo que se habilita la
-- funcionalidad, en vez de dejarlo confiado solo a que el frontend no lo
-- muestre.
alter table public.sales add column stock_skipped boolean not null default false;

comment on column public.sales.stock_skipped is
  'true si esta venta se cargó como historial sin afectar stock real '
  '(ej. venta de hace 3 meses cargada hoy para completar el registro). '
  'Nunca se pisa retroactivamente: si se necesita reponer el stock después, '
  'es un ajuste de inventario aparte, auditable por su cuenta.';

drop function if exists public.fn_create_sale_core(
  uuid, jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text
);
drop function if exists public.create_sale(
  jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text
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
  p_skip_stock_movement boolean default false
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
    is_free_sale, free_sale_reason, free_sale_notes, stock_skipped
  ) values (
    v_sale_number, p_sold_at, p_location_id, p_sales_channel_id, p_seller_id,
    p_customer_id, p_doctor_id, p_payment_method_id, (v_quote ->> 'applied_price_condition_id')::uuid,
    (v_quote ->> 'subtotal')::numeric, (v_quote ->> 'discount_total')::numeric,
    (v_quote ->> 'total')::numeric, v_commission_total, 'confirmed',
    p_external_source, p_external_order_id, p_notes,
    p_is_free_sale, p_free_sale_reason, p_free_sale_notes, p_skip_stock_movement
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
    'lines', v_quote -> 'lines'
  );
end;
$$;

revoke execute on function public.fn_create_sale_core(
  uuid, jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text, boolean
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
  p_skip_stock_movement boolean default false
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
    p_customer_id, p_doctor_id, p_notes, p_external_source, p_external_order_id, p_sold_at,
    p_is_free_sale, p_free_sale_reason, p_free_sale_notes, p_skip_stock_movement
  );
end;
$$;

grant execute on function public.create_sale(
  jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text, boolean
) to authenticated;
