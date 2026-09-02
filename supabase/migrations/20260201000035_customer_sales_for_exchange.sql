-- =============================================================================
-- Maguirejuve · Cambios / Devoluciones — Bloque C (paso 1): búsqueda de la
-- venta original a partir del cliente.
-- =============================================================================
-- Mismo motivo que customer_purchase_history (20260201000017): sales_select
-- (RLS) recorta a un vendedor no-admin a "mis propias ventas" — acá el
-- alcance es "las ventas de ESTE cliente", para poder hacerle un cambio
-- aunque no haya sido quien se la vendió. Por eso es una RPC dedicada, no un
-- select directo. No reutilizo customer_purchase_history (aunque el shape se
-- parece) porque un cambio necesita cosas que esa pantalla no expone:
-- sale_item.id (para poder indicar cuál línea se devuelve), el precio
-- realmente pagado por línea, y el medio de pago/cuenta de la venta.
--
-- s.status = 'confirmed' ya excluye, sin ninguna regla extra: ventas
-- canceladas Y ventas ya reemplazadas por un cambio anterior (quedan en
-- status='replaced') — ninguna de las dos es una venta "modificable" de
-- nuevo. Las ventas sin costo (is_free_sale) se listan pero el frontend las
-- muestra deshabilitadas: create_sale_exchange las rechaza (decisión de
-- diseño ya cerrada), mejor no dejar llegar a un callejón sin salida.
create or replace function public.customer_sales_for_exchange(p_customer_id uuid)
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
          'payment_account_id', s.payment_account_id,
          'total', s.total,
          'is_free_sale', s.is_free_sale,
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
              'sale_item_id', si.id,
              'product_id', si.product_id,
              'name', pr.name,
              'sku', pr.sku,
              'product_type', pr.product_type,
              'quantity', si.quantity,
              'list_unit_price', si.list_unit_price,
              'sale_unit_price', si.sale_unit_price,
              'line_total', si.line_total
            )
            order by pr.name
          ),
          '[]'::jsonb
        ) as items
        from public.sale_items si
        join public.products pr on pr.id = si.product_id
        where si.sale_id = s.id
      ) t on true
      where s.customer_id = p_customer_id
        and s.status = 'confirmed'
        and public.has_location_access(s.location_id)
    ),
    '[]'::jsonb
  );
end;
$$;

comment on function public.customer_sales_for_exchange is
  'Ventas de un cliente elegibles como origen de un cambio: solo status=confirmed '
  '(excluye canceladas y ya reemplazadas por un cambio anterior, sin regla extra). '
  'A diferencia de customer_purchase_history, expone sale_item.id y el precio '
  'realmente pagado por línea — lo que create_sale_exchange necesita del frontend.';

grant execute on function public.customer_sales_for_exchange(uuid) to authenticated;
