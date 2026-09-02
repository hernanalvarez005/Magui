-- =============================================================================
-- Maguirejuve · 45 · Devolución de producto — funciones (paso 3/3, Bloque B)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) create_sale_return — RPC transaccional. Admin o vendedor con acceso a la
--    sede de la venta original (viewer, bloqueado — mismo criterio que
--    create_sale_exchange). p_items: jsonb [{ "sale_item_id": uuid,
--    "quantity": numeric }, ...] — una devolución puede tocar varias líneas
--    de la misma venta en un solo evento.
--
--    Checklist (14 pasos, cerrado con el usuario antes de escribir esta
--    función): lock venta -> validar estado -> validar usuario -> validar
--    cantidades disponibles -> validar items -> calcular monto histórico ->
--    validar forma de reintegro -> validar cuenta si transferencia ->
--    reintegrar stock -> crear movimientos -> crear devolución -> crear
--    detalle -> auditar -> actualizar estado si devolución total. Cualquier
--    excepción hace ROLLBACK completo (comportamiento estándar de una
--    función plpgsql: una excepción no capturada revierte toda la transacción).
--
--    Nunca confía en valores mandados por el frontend salvo sale_item_id y
--    quantity: el precio de reintegro sale SIEMPRE del snapshot histórico
--    (sale_items.sale_unit_price), nunca de un monto que mande el cliente.
-- ---------------------------------------------------------------------------
create or replace function public.create_sale_return(
  p_original_sale_id uuid,
  p_items jsonb,
  p_refund_method public.sale_refund_method,
  p_payment_account_id uuid default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_sale public.sales;
  v_item jsonb;
  v_sale_item_id uuid;
  v_quantity numeric;
  v_returned_item public.sale_items;
  v_already_returned numeric;
  v_available numeric;
  v_physical_source_id uuid;
  v_root_quantity numeric;
  v_movement record;
  v_reversal_qty numeric;
  v_line_refund numeric;
  v_return_lines jsonb := '[]'::jsonb;
  v_line jsonb;
  v_refund_amount numeric := 0;
  v_return_id uuid;
  v_new_return_item_id uuid;
  v_net_remaining numeric;
  v_billing_status public.sale_billing_status;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede registrar devoluciones.';
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Tenés que indicar al menos un producto a devolver.';
  end if;

  -- La misma línea no puede aparecer dos veces en un mismo llamado: el lock
  -- de sale_items (más abajo) solo serializa entre llamados DISTINTOS — dos
  -- entradas del mismo sale_item_id dentro de ESTE array verían la misma
  -- disponibilidad "disponible" sin verse entre sí (el insert de
  -- sale_return_items recién pasa después de terminar el loop de validación).
  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(sale_item_id uuid, quantity numeric)
    group by x.sale_item_id
    having count(*) > 1
  ) then
    raise exception 'No se puede indicar el mismo producto más de una vez en la misma devolución — sumá la cantidad en una sola línea.';
  end if;

  if p_refund_method = 'TRANSFER' then
    if p_payment_account_id is null or not exists (
      select 1 from public.payment_accounts where id = p_payment_account_id and active
    ) then
      raise exception 'Una devolución por transferencia necesita indicar la cuenta desde la que sale el dinero.';
    end if;
  elsif p_payment_account_id is not null then
    raise exception 'Una devolución en efectivo no lleva cuenta asociada.';
  end if;

  -- -------------------------------------------------------------------------
  -- Venta original: lock, estado, sede, cliente identificado. A diferencia de
  -- create_sale_exchange, la venta NUNCA cambia de status acá salvo que esta
  -- devolución la deje en $0 neto en TODAS sus líneas (paso final) — sigue
  -- siendo 'confirmed' y elegible para nuevas devoluciones parciales futuras.
  -- Solo una venta 'confirmed' es elegible: ni cancelada, ni ya reemplazada
  -- por un cambio (ahí hay que devolver contra la venta de reemplazo, que es
  -- la vigente) ni ya devuelta en su totalidad.
  -- -------------------------------------------------------------------------
  select * into v_sale from public.sales where id = p_original_sale_id for update;

  if v_sale is null then
    raise exception 'La venta original no existe.';
  end if;

  if v_sale.status <> 'confirmed' then
    raise exception 'Esta venta no está confirmada (anulada, reemplazada por un cambio, o ya devuelta en su totalidad) — no admite una devolución.';
  end if;

  if not public.has_location_access(v_sale.location_id) then
    raise exception 'Tu usuario no tiene acceso a la sucursal de esta venta.';
  end if;

  if v_sale.is_free_sale then
    raise exception 'No se puede devolver dinero de una entrega sin costo — no hubo pago que reintegrar.';
  end if;

  -- -------------------------------------------------------------------------
  -- Por cada línea a devolver: lock de la fila real de sale_items (serializa
  -- devoluciones concurrentes sobre la MISMA línea — dos llamados que tocan
  -- el mismo sale_item quedan forzados a correr en serie), pertenece a esta
  -- venta, cantidad disponible = bruto de la línea menos todo lo ya devuelto
  -- contra ella hasta ahora (agregado vivo, no una columna fija).
  -- -------------------------------------------------------------------------
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_sale_item_id := (v_item ->> 'sale_item_id')::uuid;
    v_quantity := (v_item ->> 'quantity')::numeric;

    if v_quantity is null or v_quantity <= 0 then
      raise exception 'La cantidad a devolver tiene que ser mayor a 0.';
    end if;

    select * into v_returned_item from public.sale_items where id = v_sale_item_id for update;

    if v_returned_item is null or v_returned_item.sale_id <> p_original_sale_id then
      raise exception 'El producto a devolver no pertenece a esta venta.';
    end if;

    select coalesce(sum(quantity), 0) into v_already_returned
    from public.sale_return_items
    where sale_item_id = v_sale_item_id;

    v_available := v_returned_item.quantity - v_already_returned;

    if v_quantity > v_available then
      raise exception
        'No podés devolver % unidades: esta línea solo tiene % disponibles para devolver (ya se descontó cualquier devolución anterior).',
        v_quantity, v_available;
    end if;

    -- ---------------------------------------------------------------------
    -- Monto histórico — SIEMPRE sale_unit_price de la línea (precio
    -- realmente pagado, nunca precio actual/Lista/pricing reejecutado). Para
    -- una línea con promoción esto ya es proporcional: fn_apply_promotions
    -- guarda un único sale_unit_price uniforme por unidad en toda la línea.
    -- No se permite devolver un componente de kit como línea independiente
    -- por construcción: el picker del frontend solo puede ofrecer
    -- sale_item_id reales de esta venta, y un componente de kit nunca tiene
    -- uno propio salvo que también se haya vendido por separado.
    -- ---------------------------------------------------------------------
    v_line_refund := round(v_returned_item.sale_unit_price * v_quantity, 2);
    v_refund_amount := v_refund_amount + v_line_refund;

    v_return_lines := v_return_lines || jsonb_build_object(
      'sale_item_id', v_sale_item_id,
      'product_id', v_returned_item.product_id,
      'quantity', v_quantity,
      'unit_price_refunded', v_returned_item.sale_unit_price,
      'line_refund_total', v_line_refund,
      'physical_source_sale_item_id', coalesce(v_returned_item.physical_source_sale_item_id, v_returned_item.id)
    );
  end loop;

  -- -------------------------------------------------------------------------
  -- Reintegro de stock — idéntica reversión proporcional que create_sale_
  -- exchange: por cada fila real de stock_movements de la línea RAÍZ
  -- (resuelta con coalesce(physical_source_sale_item_id, id), funciona igual
  -- para una línea de venta directa que para una trasladada por un cambio
  -- previo), repone (cantidad_devuelta / cantidad_raíz) de ese movimiento —
  -- para un kit, cada componente vuelve en su proporción exacta, sin volver
  -- a mirar kit_components vigente.
  -- -------------------------------------------------------------------------
  for v_line in select * from jsonb_array_elements(v_return_lines)
  loop
    v_physical_source_id := (v_line ->> 'physical_source_sale_item_id')::uuid;
    select quantity into v_root_quantity from public.sale_items where id = v_physical_source_id;

    for v_movement in
      select location_id, product_id, quantity_delta
      from public.stock_movements
      where movement_type = 'SALE'
        and source_sale_item_id = v_physical_source_id
      order by product_id
    loop
      v_reversal_qty := round(
        (v_line ->> 'quantity')::numeric * abs(v_movement.quantity_delta) / v_root_quantity, 2
      );
      if v_reversal_qty > 0 then
        perform public.fn_apply_stock_movement(
          p_location_id => v_movement.location_id,
          p_product_id => v_movement.product_id,
          p_movement_type => 'RETURN',
          p_quantity_delta => v_reversal_qty,
          p_sale_id => p_original_sale_id,
          p_reference => v_sale.sale_number,
          p_notes => 'Devolución de producto',
          p_created_by => auth.uid(),
          p_allow_negative => true,
          p_source_sale_item_id => v_physical_source_id
        );
      end if;
    end loop;
  end loop;

  -- -------------------------------------------------------------------------
  -- Cabecera + detalle. sales.commission_total NUNCA se reescribe acá (queda
  -- el valor histórico bruto de la venta original, intacto): la comisión
  -- neta se recalcula en el momento en los reportes (Bloque D) contra
  -- sale_item_net, nunca leyendo/editando esta columna persistida.
  -- -------------------------------------------------------------------------
  insert into public.sale_returns (
    original_sale_id, refund_amount, refund_method, payment_account_id, notes, created_by
  ) values (
    p_original_sale_id, v_refund_amount, p_refund_method, p_payment_account_id, p_notes, auth.uid()
  )
  returning id into v_return_id;

  for v_line in select * from jsonb_array_elements(v_return_lines)
  loop
    insert into public.sale_return_items (
      return_id, sale_item_id, product_id, quantity, unit_price_refunded, line_refund_total
    ) values (
      v_return_id,
      (v_line ->> 'sale_item_id')::uuid,
      (v_line ->> 'product_id')::uuid,
      (v_line ->> 'quantity')::numeric,
      (v_line ->> 'unit_price_refunded')::numeric,
      (v_line ->> 'line_refund_total')::numeric
    )
    returning id into v_new_return_item_id;
  end loop;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'SALE_RETURN_CREATED', 'sales', p_original_sale_id,
    jsonb_build_object(
      'return_id', v_return_id,
      'original_sale_id', p_original_sale_id,
      'customer_id', v_sale.customer_id,
      'location_id', v_sale.location_id,
      'refund_amount', v_refund_amount,
      'refund_method', p_refund_method,
      'payment_account_id', p_payment_account_id,
      'items', v_return_lines
    )
  );

  -- -------------------------------------------------------------------------
  -- Devolución total: si TODAS las líneas de la venta quedan en $0 neto
  -- (nunca solo las tocadas en este llamado — se mide contra la venta
  -- completa), status pasa a 'returned'. Cada net_line_total es siempre >= 0
  -- (nunca se permite sobre-devolver), así que sum = 0 implica que cada
  -- línea, individualmente, quedó en 0 — no hace falta chequear una por una.
  -- Nunca se aplica este estado a una devolución parcial (regla crítica,
  -- cerrada con el usuario: el resto de la venta sigue siendo válido).
  --
  -- billing_status: si la venta estaba PENDING y queda en $0 neto, no hay más
  -- nada que facturar — pasa a NOT_REQUIRED. Si estaba INVOICED, el
  -- comprobante fiscal NUNCA se toca acá (proceso de nota de crédito, fuera
  -- de alcance) — se mantiene INVOICED tal cual, sea devolución parcial o
  -- total (precisión #6 del usuario). El detalle de venta (Bloque C) muestra
  -- una advertencia explícita cuando billing_status = INVOICED.
  -- -------------------------------------------------------------------------
  select coalesce(sum(net_line_total), 0) into v_net_remaining
  from public.sale_item_net
  where sale_id = p_original_sale_id;

  v_billing_status := v_sale.billing_status;

  if v_net_remaining = 0 then
    update public.sales
    set status = 'returned',
        billing_status = case when v_sale.billing_status = 'PENDING' then 'NOT_REQUIRED' else v_sale.billing_status end
    where id = p_original_sale_id
    returning billing_status into v_billing_status;
  end if;

  return jsonb_build_object(
    'return_id', v_return_id,
    'original_sale_id', p_original_sale_id,
    'refund_amount', v_refund_amount,
    'refund_method', p_refund_method,
    'is_full_return', v_net_remaining = 0,
    'sale_status', case when v_net_remaining = 0 then 'returned' else v_sale.status end,
    'billing_status', v_billing_status
  );
end;
$$;

grant execute on function public.create_sale_return(uuid, jsonb, public.sale_refund_method, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2) customer_sales_for_return — mismo motivo que customer_sales_for_exchange
--    (sales_select por RLS recorta a "mis propias ventas" para un vendedor no
--    admin; acá el alcance es "las ventas de ESTE cliente"). Expone, por
--    línea, available_to_return (bruto menos ya devuelto, vía sale_item_net)
--    para que el frontend pueda deshabilitar lo que ya no tiene saldo.
--    status = 'confirmed' excluye, sin regla extra: canceladas, ya
--    reemplazadas por un cambio (status='replaced' — hay que devolver contra
--    la venta de reemplazo, que es la que aparece acá) y ya devueltas en su
--    totalidad (status='returned').
-- ---------------------------------------------------------------------------
create or replace function public.customer_sales_for_return(p_customer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
begin
  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or not v_profile.active then
    raise exception 'Tu usuario no tiene permiso para ver esta información.';
  end if;

  if not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'El cliente no existe.';
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'sale_id', s.id,
          'sale_number', s.sale_number,
          'sold_at', s.sold_at,
          'location_id', s.location_id,
          'location_name', l.name,
          'payment_method_id', s.payment_method_id,
          'payment_method_code', pm.code,
          'payment_method_name', pm.name,
          'billing_status', s.billing_status,
          'total', s.total,
          'items', t.items
        )
        order by s.sold_at desc
      )
      from public.sales s
      join public.stock_locations l on l.id = s.location_id
      join public.payment_methods pm on pm.id = s.payment_method_id
      join lateral (
        select coalesce(
          jsonb_agg(
            jsonb_build_object(
              'sale_item_id', sin.sale_item_id,
              'product_id', sin.product_id,
              'name', pr.name,
              'sku', pr.sku,
              'product_type', pr.product_type,
              'quantity', sin.gross_quantity,
              'sale_unit_price', sin.sale_unit_price,
              'returned_quantity', sin.returned_quantity,
              'available_to_return', sin.net_quantity
            )
            order by pr.name
          ),
          '[]'::jsonb
        ) as items
        from public.sale_item_net sin
        join public.products pr on pr.id = sin.product_id
        where sin.sale_id = s.id
      ) t on true
      where s.customer_id = p_customer_id
        and s.status = 'confirmed'
        and not s.is_free_sale
        and public.has_location_access(s.location_id)
    ),
    '[]'::jsonb
  );
end;
$$;

comment on function public.customer_sales_for_return is
  'Ventas de un cliente elegibles como origen de una devolución: solo status=confirmed, '
  'sin entregas sin costo. Cada línea expone available_to_return (sale_item_net.net_quantity) '
  'para que el frontend deshabilite lo que ya no tiene saldo para devolver.';

grant execute on function public.customer_sales_for_return(uuid) to authenticated;
