-- =============================================================================
-- Maguirejuve · 47 · Analytics de productos, kits y promociones — snapshot
-- histórico de promoción en sale_items (paso 1/5, cierre del punto 2 de la
-- auditoría PASO 0)
-- =============================================================================
-- Hallazgo de la auditoría (aprobado con precisión del usuario): sale_items.
-- applied_promotion_id ya guarda QUÉ promoción generó la línea, pero no guarda
-- CÓMO ERA esa promoción en ese momento — el nombre/tipo/% se resuelven hoy
-- siempre por JOIN contra promotions "vivo". Como promotions SÍ es editable
-- (nombre, %, vigencia — nunca su tipo, ver check de la tabla), un reporte
-- histórico mes a mes podía mostrar retroactivamente el nombre/% ACTUAL en
-- vez del que tenía la promoción cuando se vendió. Analytics necesita
-- comparar promociones históricas de forma estable — se agrega acá el
-- snapshot mínimo necesario, mismo criterio ya usado para
-- applied_price_condition_id/sale_unit_price (la plata nunca dependió del
-- join; ahora la IDENTIDAD comercial tampoco).
--
-- Todas nullable: cada columna solo tiene sentido cuando applied_promotion_id
-- no es null, y las ventas ya existentes (legado, anteriores a esta
-- migración) se quedan sin snapshot — NUNCA se completa retroactivamente con
-- un valor inventado. fn_create_sale_core (paso 2/5) es la única vía de
-- escritura de acá en adelante; create_sale_exchange (paso 2/5 también) copia
-- el snapshot ya existente de las líneas no tocadas/remanente, nunca lo
-- recalcula.
alter table public.sale_items
  add column promotion_name_snapshot text,
  add column promotion_type_snapshot public.promotion_type,
  add column promotion_discount_percent_snapshot numeric(5, 4),
  add column promotion_started_at_snapshot timestamptz,
  add column promotion_ended_at_snapshot timestamptz;

comment on column public.sale_items.promotion_name_snapshot is
  'Nombre de la promoción (promotions.name) tal como era al momento de esta venta. Null si la '
  'línea no tuvo promoción, o si es una venta legado anterior a esta columna (ahí Analytics cae '
  'a resolver por JOIN contra promotions vigente — ver comentario de uso en las funciones de '
  'reporte). Nunca se reescribe si más adelante se edita el nombre de la promoción.';
comment on column public.sale_items.promotion_type_snapshot is
  'promotions.type al momento de la venta. Mismo criterio que promotion_name_snapshot — el tipo '
  'de una promoción no es editable hoy (ver constraint de promotions), pero se snapshotea igual '
  'para que Analytics nunca dependa del join ni de que ese supuesto se mantenga en el futuro.';
comment on column public.sale_items.promotion_discount_percent_snapshot is
  'promotions.discount_percent al momento de la venta (null para THREE_FOR_TWO, que no tiene %). '
  'Es SOLO informativo/de exhibición — la plata real de esta línea ya está en sale_unit_price/'
  'promotion_discount, nunca se recalcula desde este snapshot.';
comment on column public.sale_items.promotion_started_at_snapshot is
  'promotions.valid_from al momento de la venta — contexto para interpretar la promoción en un '
  'reporte histórico (ej. "vigente desde tal fecha"), no participa en ningún cálculo de importes.';
comment on column public.sale_items.promotion_ended_at_snapshot is
  'promotions.valid_until al momento de la venta (null = sin fecha de fin definida en ese '
  'momento). Mismo criterio que promotion_started_at_snapshot — puramente informativo.';
