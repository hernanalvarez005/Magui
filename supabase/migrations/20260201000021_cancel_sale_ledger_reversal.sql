-- =============================================================================
-- Maguirejuve · 37 · Anulación de ventas: revertir el ledger real (Bloque D)
-- =============================================================================
-- cancel_sale ya existía (nunca hace hard delete, es transaccional, bloquea
-- doble cancelación, audita) pero tenía dos problemas reales:
--
-- 1) Era exclusiva de admin. El pedido permite Administrador Y Vendedor
--    (sección 16) — se valida en el backend, no solo ocultando el botón.
--
-- 2) Para un kit, reexpandía sale_items contra la composición ACTUAL de
--    kit_components (public.kit_components), no la que realmente se usó al
--    momento de la venta. Si la composición del kit cambió entre la venta y
--    la anulación, la reversión de stock quedaba mal. La fuente de verdad de
--    qué se descontó ya existe y es inmutable: los propios stock_movements
--    (movement_type = 'SALE') de esa venta — ahí ya está, producto por
--    producto y sede por sede, exactamente lo que se restó, sin volver a
--    tocar la definición del kit. Revertir esos movimientos 1 a 1 (signo
--    invertido, SALE_CANCEL) es correcto siempre, haya cambiado el kit o no.
create or replace function public.cancel_sale(p_sale_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_sale public.sales;
  v_movement record;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if p_reason is null or trim(p_reason) = '' then
    raise exception 'El motivo de cancelación es obligatorio.';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale is null then
    raise exception 'La venta no existe.';
  end if;

  if v_sale.status = 'cancelled' then
    raise exception 'La venta ya se encuentra anulada.';
  end if;

  if not public.has_location_access(v_sale.location_id) then
    raise exception 'Tu usuario no tiene acceso a la sucursal de esta venta.';
  end if;

  -- Un movimiento SALE por (producto, sede) — create_sale ya agrupa por
  -- product_id antes de insertar, así que esto revierte exactamente y una
  -- sola vez cada línea real que se descontó (kits incluidos, ya expandidos
  -- en su momento a sus componentes).
  for v_movement in
    select location_id, product_id, quantity_delta
    from public.stock_movements
    where sale_id = p_sale_id and movement_type = 'SALE'
    order by product_id
  loop
    perform public.fn_apply_stock_movement(
      p_location_id => v_movement.location_id,
      p_product_id => v_movement.product_id,
      p_movement_type => 'SALE_CANCEL',
      p_quantity_delta => -v_movement.quantity_delta, -- SALE es negativo; se repone en positivo.
      p_sale_id => v_sale.id,
      p_reference => v_sale.sale_number,
      p_notes => p_reason,
      p_created_by => auth.uid(),
      p_allow_negative => true
    );
  end loop;

  update public.sales
  set status = 'cancelled',
      cancelled_at = now(),
      cancelled_by = auth.uid(),
      cancellation_reason = p_reason
  where id = p_sale_id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (auth.uid(), 'cancel_sale', 'sales', p_sale_id, jsonb_build_object('reason', p_reason));

  return jsonb_build_object('sale_id', p_sale_id, 'status', 'cancelled');
end;
$$;

comment on function public.cancel_sale is
  'Nunca hace hard delete. Admin o vendedor con acceso a la sede de la venta. Revierte '
  'exactamente los movimientos SALE originales del ledger (stock_movements) — no reexpande '
  'kit_components actual, así que una anulación es correcta aunque el kit haya cambiado desde '
  'la venta. Idempotente: una venta ya cancelada no puede volver a cancelarse.';
