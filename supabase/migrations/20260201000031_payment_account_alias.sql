-- =============================================================================
-- Maguirejuve · Cuenta de ingreso: alias bancario + administración de cuentas
-- =============================================================================
-- PASO 0 (auditoría, resumen — ver informe completo entregado al usuario):
--   - payment_accounts YA existe (20260201000024_billing_schema.sql) con
--     id/code/name/active/sort_order/created_at, seedeada con Mercado Pago
--     y Banco Galicia, y sales.payment_account_id YA la referencia. No se
--     crea ninguna estructura paralela — se extiende esta misma tabla.
--   - RLS de payment_accounts YA es exactamente lo que pide el pedido:
--     SELECT para cualquier perfil activo (is_active_profile — vendedor
--     incluido), INSERT/UPDATE exclusivos de admin (is_admin), y
--     deliberadamente SIN policy de DELETE (mismo patrón que promotions:
--     nunca hard delete, solo active = false) — no hace falta ninguna
--     migración de RLS para las secciones 18/19 del pedido.
--   - "Editar cuenta": no se agrega snapshot histórico del nombre de
--     cuenta — sales.payment_account_id ya es una FK simple (igual que
--     payment_method_id, location_id, etc.) y ninguna de esas referencias
--     tiene snapshot propio en la venta; el nombre se resuelve siempre vía
--     join, igual en todos lados. No hay un requerimiento contable
--     explícito para snapshot acá tampoco — se sigue el mismo criterio ya
--     establecido en el resto del sistema (sección 10 del pedido: "no
--     agregar snapshot sin necesidad").
--
-- Único cambio real de schema: alias, nullable, sin valor inicial
-- inventado (Mercado Pago y Banco Galicia quedan con alias = null hasta
-- que Administración los cargue — sección 14 del pedido).
alter table public.payment_accounts add column if not exists alias text;

comment on column public.payment_accounts.alias is
  'Alias bancario/de Mercado Pago para compartir al cobrar por transferencia (ej. "maguirejuve.mp"). '
  'Null = sin alias configurado todavía; Nueva Venta no muestra el bloque de alias en ese caso. '
  'Pertenece a la cuenta, nunca a la venta ni al medio de pago — un mismo alias sirve para todas las '
  'ventas futuras que usen esa cuenta, y cambiarlo no toca ninguna venta ya confirmada.';
