-- =============================================================================
-- Maguirejuve · Ajustes: visibilidad de promociones + sede/canal habilitado
-- =============================================================================
-- PASO 0 (auditoría, resumen — ver informe completo entregado al usuario):
--   - has_location_access(p_location_id) YA existe y YA es rol-agnóstica: un
--     admin también necesita estar en profile_locations (comment de
--     20260101000002_profiles.sql). create_sale() YA la llama antes de
--     delegar en fn_create_sale_core — la restricción de sede en backend
--     (sección 17 del pedido) YA estaba implementada, no se toca.
--   - Nueva Venta (app/(app)/ventas/nueva/page.tsx) YA arma el listado de
--     `locations` filtrado a profile.locationIds — el selector de sede YA
--     solo muestra las sedes habilitadas del usuario (sección 13). Y YA
--     bloquea la pantalla entera con un mensaje claro si locationIds está
--     vacío (sección 20) — no se toca ninguna de las dos cosas.
--   - create_web_order() (integración server-to-server, exclusiva de
--     service_role, revocada de authenticated/anon) es un camino
--     COMPLETAMENTE APARTE de create_sale() — el canal Web sigue existiendo
--     en el modelo de datos y la integración externa sigue funcionando
--     igual (sección 16), esta migración no la toca.
--
-- El único gap real encontrado: create_sale() (el RPC que usa un usuario
-- logueado desde Nueva Venta) no validaba el CANAL — un vendedor podía
-- mandar p_sales_channel_id = el id de 'WEB' manipulando la request, aunque
-- el selector del frontend ya no se lo ofrezca (sección 18). Se agrega acá
-- el mismo tipo de chequeo que ya existía para sede, en el mismo lugar
-- (antes de delegar en fn_create_sale_core) — mismo patrón, sin tocar
-- fn_create_sale_core ni ninguna otra función.
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
  v_channel_code text;
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

  -- Canal Web exclusivo de admin (sección 18 del pedido) — un vendedor
  -- nunca puede registrar una venta manual por este canal, ni siquiera
  -- manipulando la request directamente. El canal en sí sigue existiendo
  -- (create_web_order y el listado de canales no cambian).
  select code into v_channel_code from public.sales_channels where id = p_sales_channel_id;
  if v_channel_code = 'WEB' and v_profile.role <> 'admin' then
    raise exception 'Solo un administrador puede registrar ventas por el canal Web.';
  end if;

  return public.fn_create_sale_core(
    auth.uid(), p_items, p_location_id, p_sales_channel_id, p_payment_method_id,
    p_customer_id, p_doctor_id, p_notes, p_external_source, p_external_order_id, p_sold_at,
    p_is_free_sale, p_free_sale_reason, p_free_sale_notes, p_skip_stock_movement,
    p_payment_account_id
  );
end;
$$;

comment on function public.create_sale(
  jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text, boolean, uuid
) is
  'Valida sede (has_location_access, rol-agnóstica) y canal (Web exclusivo de admin) antes de '
  'delegar en fn_create_sale_core. create_web_order() es un camino aparte, exclusivo de service_role, sin cambios.';
