-- =============================================================================
-- Maguirejuve · 62 · Decisión V1 explícita: WEB + SHIPPING + payment_status
-- PENDING queda fulfillment_status=SHIPPED desde la creación
-- =============================================================================
-- Solo comentarios — CERO cambio funcional. Cierre de BLOQUE G: el usuario
-- confirmó explícitamente que el comportamiento actual (vigente desde
-- 20260201000054/055) es el comportamiento QUERIDO para esta V1, no un bug
-- pendiente de corregir. Se documenta acá, en el esquema, para que quien
-- audite este código más adelante no lo interprete como una omisión.
--
-- Semántica confirmada para V1:
--   - SHIPPING descuenta stock físico de Depósito de inmediato al crear el
--     pedido (fn_create_sale_core, misma rama que una venta presencial —
--     fn_check_available_stock + fn_apply_stock_movement, sin reserva).
--   - SHIPPING nunca genera una fila en sale_stock_reservations — no hay
--     nada que "retirar" después, el envío ya salió.
--   - fulfillment_status queda 'SHIPPED' desde el instante de creación,
--     siempre, sin importar payment_status.
--   - payment_status puede seguir en 'PENDING' después de creado — el envío
--     y el cobro son ejes independientes (igual que para PICKUP): se puede
--     despachar un pedido y cobrarlo después con mark_web_order_paid, sin
--     que eso bloquee ni reordene el envío.
--   - Deliberadamente NO se agrega, en esta V1, un estado intermedio
--     'PENDING_SHIPMENT' ni ningún workflow de "despacho" separado de la
--     creación — si en el futuro el negocio necesita un paso de picking/
--     packing previo al envío real, es un bloque de producto aparte, con
--     su propio diseño (fecha de despacho real, quién empacó, etc.),
--     nunca una corrección de esto.
-- =============================================================================

comment on type public.sale_fulfillment_status is
  'PENDING_PICKUP/DELIVERED son el ciclo de un PICKUP. SHIPPED se asigna una única vez, en el '
  'momento de crear un pedido SHIPPING (el envío ya salió de Depósito de inmediato) — nunca pasa '
  'por PENDING_PICKUP. Decisión V1 confirmada (20260201000062): SHIPPED se asigna así incluso si '
  'payment_status queda PENDING — el envío y el cobro son ejes independientes, igual que para '
  'PICKUP. No existe (a propósito, en esta V1) un estado intermedio de "pendiente de despacho".';

comment on column public.sales.fulfillment_status is
  'Ver sale_fulfillment_status. Null para toda venta no-Web. Para SHIPPING queda SHIPPED desde la '
  'creación sin importar payment_status (decisión V1, 20260201000062) — nunca se reinterprete como '
  'un bug: no hay ningún paso de despacho separado de la creación en esta versión.';

comment on column public.sales.payment_status is
  'PAID o PENDING. Null para toda venta no-Web (esas siempre se asumen cobradas de inmediato, '
  'como siempre funcionó). NUNCA depende de billing_status/invoiced_at — son ejes distintos. '
  'Tampoco depende de fulfillment_status/fulfillment_type (decisión V1, 20260201000062): un '
  'SHIPPING con payment_status=PENDING se despacha igual de inmediato y se cobra después con '
  'mark_web_order_paid, sin que eso reordene ni bloquee el envío ya realizado.';
