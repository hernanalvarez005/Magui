-- =============================================================================
-- Maguirejuve · 46 · Condiciones QUANTITY -> Promociones — desactivación (paso 5/5)
-- =============================================================================
-- PASO 0 (auditoría entregada y aprobada por el usuario, sección 24 del
-- pedido): NO se migran automáticamente los precios de product_prices bajo
-- QTY_2/QTY_3_PLUS a un % de promoción — el % configurado en el seed
-- coincide exactamente con 20%/25% para el catálogo de prueba, pero eso es
-- una coincidencia del dataset, no algo asumible en producción. La
-- promoción QUANTITY_DISCOUNT equivalente (si se quiere) se da de alta a
-- mano en /admin/promociones, con el % que Administración decida.
--
-- Se DESACTIVA, nunca se borra (sección 22/23 del pedido): sale_items
-- históricos con applied_price_condition_id apuntando a QTY_2/QTY_3_PLUS
-- siguen íntegros — la FK nunca se toca, la fila sigue existiendo. Solo dos
-- efectos prácticos de este UPDATE:
--   1) fn_pricing_quote ya no las mira de todos modos (migración anterior) —
--      esto es además redundante/belt-and-suspenders con ese cambio.
--   2) Dejan de listarse en /admin/precios (que ya filtra active=true) y en
--      /admin/condiciones-precio (ver ajuste de frontend en el mismo bloque).
do $$
declare
  v_count int;
begin
  update public.price_conditions
  set active = false
  where rule_type = 'QUANTITY' and active = true;

  get diagnostics v_count = row_count;

  raise notice 'Condiciones QUANTITY desactivadas: %', v_count;
end
$$;
