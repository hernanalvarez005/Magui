# Deuda técnica conocida

Issues auditados, con causa raíz identificada y evidencia, que **deliberadamente
no se resuelven todavía** — quedan documentados acá para no perder el contexto
de la auditoría hasta que se decida priorizarlos.

## Cambios de producto: `sold_at=now()` puede mover la atribución de facturación entre períodos

**Estado:** auditado, cerrado como NO BUG para el caso puntual reportado
(ver abajo) — la venta de reemplazo SÍ se contabiliza, solo que en su propia
fecha. Queda como deuda el edge case real que el propio mecanismo habilita.

**Contexto de la auditoría:** un reporte de "faltan $38.000 en Facturación
del Dashboard" resultó ser un error de lectura del usuario — la venta
original (`status='replaced'`, $38.000) correctamente no suma (evitar doble
conteo), y su venta de reemplazo (`status='confirmed'`, $37.000) sí estaba
contabilizada, solo que más arriba en el listado/reporte de lo que se
esperaba. `dashboard_report`, `product_revenue_report`, `doctor_sales_detail`
y `promotion_performance_report` no se modificaron.

**Mecanismo (confirmado por lectura de código, `create_sale_exchange` —
última versión en `supabase/migrations/20260201000061_stock_available_transversal.sql`):**
la venta de reemplazo de un Cambio se inserta con `sold_at = now()` (el
momento en que se hace el cambio), nunca con el `sold_at` de la venta
original. La venta original pasa a `status = 'replaced'` y queda
estructuralmente excluida de todos los reportes financieros (que filtran
`status = 'confirmed'`).

**Edge case no resuelto:** si un Cambio ocurre en una fecha que cae en un
**período distinto** (mes, o cualquier rango que un reporte esté filtrando)
al de la venta original, el valor económico de la operación:

- desaparece del período de la venta original (excluida por `status`), y
- aparece en el período del Cambio, no en el de la venta original (porque
  `sold_at` de la venta de reemplazo es la fecha del Cambio).

Es decir: la operación se sigue contando exactamente una vez (no hay
duplicación ni pérdida total), pero la atribución temporal de esa
facturación puede no coincidir con la fecha en que el cliente compró
originalmente — un reporte cerrado de un mes anterior puede no reflejar una
venta que comercialmente ocurrió ese mes, si se le hizo un Cambio en el mes
siguiente.

**Por qué no se resuelve ahora:** el caso puntual reportado no lo disparó
(ambas ventas cayeron en el mismo mes). Resolverlo requiere una decisión de
diseño explícita (¿se atribuye a la fecha de la venta raíz de la cadena, vía
`replaces_sale_id`? ¿se acepta el comportamiento actual?) que no está
aprobada — no se implementa nada de esto sin esa aprobación explícita.

**Para retomarlo:** ver la auditoría completa (Bloque 1, "Dashboard / venta
reemplazada de $38.000") en el historial de la sesión de Claude Code que
originó este documento — incluye la query de reconstrucción de cadena
(`replaces_sale_id`/`sale_exchanges`) y las funciones candidatas al fix
(`create_sale_exchange`, `dashboard_report`, `product_revenue_report`,
`doctor_sales_detail`, `promotion_performance_report`).
