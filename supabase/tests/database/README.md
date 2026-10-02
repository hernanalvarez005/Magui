# pgTAP — baseline conocido: 82 "throws_ok compatibility artifacts"

Al correr toda la suite (`pg_prove supabase/tests/database/*.sql`) van a
aparecer **82 tests marcados como "failed" que NO son regresiones**. Es un
artefacto de compatibilidad del runner local (pgTAP + Tap::Harness vía
`pg_prove`), no un bug de la aplicación ni de las RPC. Antes de investigar
cualquier "failed" nuevo, comparar contra esta lista — si coincide
exactamente, es este artefacto conocido, no una regresión.

## Causa

Todos estos tests usan la forma de **2 argumentos** de `throws_ok`:

```sql
select throws_ok(
  '<sql que debe fallar>',
  'Descripción legible del caso'
);
```

pgTAP interpreta el 2º argumento de esa forma como el **mensaje de error
esperado**, no como una descripción libre — compara el mensaje real de la
excepción contra ese texto. Como el texto que usamos ahí es una descripción
del caso de test (en español, legible), nunca coincide literalmente con el
mensaje real que lanza la RPC (`raise exception '...'`), así que pgTAP
marca el test "not ok" — **aunque la excepción se haya disparado exactamente
como se esperaba**. Se confirma leyendo la línea `caught:` del output: en
los 56 casos, muestra el error real y correcto.

Ejemplo real (de `reversal_qty_guard_fix.test.sql`):

```
# Failed test 21: "threw Caso 8: si la proporción calculada resuelve <= 0, la función lanza excepción — nunca inserta un RETURN en 0"
#       caught: P0001: No se pudo calcular una cantidad válida de reintegro de stock...
#       wanted: an exception: Caso 8: si la proporción calculada resuelve <= 0, la función lanza excepción — nunca inserta un RETURN en 0
```

La excepción SÍ se disparó (línea `caught:`) — pgTAP solo comparó mal el
mensaje contra la descripción. El test pasa su propósito real (la RPC
rechazó el caso inválido); lo que falla es la aserción textual de pgTAP.

**No se corrige reescribiendo estos tests** a la forma con SQLSTATE (3-4
argumentos) porque el patrón de 2 argumentos, con descripción en español
legible, es la convención establecida en toda la suite — cambiarlo en
algunos archivos y no en otros generaría inconsistencia sin beneficio real
(el propósito de cada test ya se verifica correctamente).

## Lista completa (82), por archivo y nº de test

| Archivo | Tests fallidos | Total del archivo |
|---|---|---|
| `analytics.test.sql` | 9 | 24 |
| `billing_status.test.sql` | 12 | 15 |
| `card6_installments.test.sql` | 11, 15, 16, 21, 22, 23 | 23 |
| `exchange_legacy_stock_reversal.test.sql` | 17, 21 | 23 |
| `mejoras.test.sql` | 1, 6, 8, 11 | 12 |
| `price_conditions_admin.test.sql` | 7, 9, 19, 20, 28, 31, 32, 33, 40, 43, 46, 47, 50, 55, 56, 72, 73, 74, 86, 87 | 87 |
| `pricing_and_sales.test.sql` | 9 | 11 |
| `promotion_payment_methods.test.sql` | 1, 2, 3, 4, 11, 12, 15, 16, 17, 19, 20, 22, 23 | 25 |
| `promotion_per_line_stacking.test.sql` | 14, 16 | 18 |
| `promotions.test.sql` | 3, 4, 5 | 10 |
| `reversal_qty_guard_fix.test.sql` | 17, 21, 28 | 30 |
| `rls.test.sql` | 3 | 7 |
| `stock_available_transversal.test.sql` | 7, 9 | 10 |
| `three_for_two_historical_backfill.test.sql` | 1, 2, 3, 4 | 12 |
| `viewer_role.test.sql` | 10, 11 | 12 |
| `web_admin_delivery_bypass_and_stock_availability.test.sql` | 4, 9 | 11 |
| `web_circuit_end_to_end_regression.test.sql` | 16 | 44 |
| `web_fulfillment.test.sql` | 20, 21, 23, 24, 27, 29, 34, 35 | 36 |
| `web_fulfillment_permissions_and_billing.test.sql` | 5, 6 | 10 |
| `web_order_history.test.sql` | 14 | 18 |
| `web_order_paid_method_change.test.sql` | 3, 5, 6 | 7 |

Total: **82 de 835** tests reales de la suite completa (al día de la
migración 73, visibilidad de condiciones de precio en `/precios` — ver `Origen`).
El total de tests crece con cada archivo nuevo, la lista de "failed"
conocidos no debería, salvo que se agregue un test nuevo que use la misma
forma de 2 argumentos con una excepción real esperada;
`web_payment_status_metrics.test.sql`, `web_pending_pickups.test.sql`,
`three_for_two_promotion_attribution_fix.test.sql`, `customer_email.test.sql`
y `doctor_sales_detail_pdf_fields.test.sql` no usan `throws_ok` de 2
argumentos, así que suman 9, 11, 16, 4 y 14 tests reales respectivamente sin
agregar ningún quirk nuevo).

## Cómo verificar que un "failed" es este artefacto y no una regresión

1. Buscar el número de test fallido en la tabla de arriba, para ese archivo.
2. Si coincide: leer la línea `caught:` del output de `pg_prove` — debe
   mostrar un mensaje de error coherente con lo que el test dice que debía
   pasar (ej: "Solo un administrador puede...", "No hay stock suficiente
   de..."). Si el mensaje tiene sentido, es el artefacto conocido.
3. Si el número de test fallido NO está en esta lista, o el `caught:` NO
   tiene sentido para ese caso (mensaje de error distinto al esperado, o
   directamente no lanzó excepción), **es una regresión real** — investigar.

## Origen

Este baseline se estableció durante el bugfix de
`20260201000053_reversal_qty_guard_fix.sql` (15 quirks preexistentes +
3 nuevos de `reversal_qty_guard_fix.test.sql`) — 18/457 en ese momento.
Actualizado durante BLOQUE B del circuito Ventas Web/Fulfillment/Reservas
(`20260201000055_web_fulfillment_functions.sql`, +8 quirks nuevos de
`web_fulfillment.test.sql`) — 26/493 a partir de acá. Actualizado de nuevo
durante el cierre de BLOQUE C, verificación de permisos de fulfillment
para admin y timing de `billing_status` vs `payment_status`
(`20260201000057_web_fulfillment_permissions_and_billing_fix.sql`, +2
quirks nuevos de `web_fulfillment_permissions_and_billing.test.sql`) —
28/512 a partir de acá. Actualizado una vez más al cerrar el bypass de
admin en `deliver_web_pickup` y la RPC `web_admin_stock_availability`
(`20260201000058_web_admin_delivery_bypass_and_stock_availability.sql`,
+2 quirks nuevos de
`web_admin_delivery_bypass_and_stock_availability.test.sql`) — 30/523 a
partir de acá. Actualizado de nuevo con BLOQUE D (bandeja de
Notificaciones, `20260201000059_web_pending_pickups.sql`,
`web_pending_pickups.test.sql` no agrega quirks — no usa `throws_ok`) —
30/534 a partir de acá. Actualizado una vez más al cerrar BLOQUE D
(auditoría del medio de pago final en `mark_web_order_paid` + viewer
bloqueado en acciones pero con lectura permitida —
`web_order_paid_method_change.test.sql`, sin migración nueva, +3 quirks
nuevos) — 33/541 a partir de acá. Actualizado de nuevo con BLOQUE E
(Historial de pedidos Web, `20260201000060_web_order_history.sql`, +1
quirk nuevo de `web_order_history.test.sql`) — 34/559 a partir de acá.
Actualizado de nuevo con BLOQUE F (stock disponible transversal,
`20260201000061_stock_available_transversal.sql`, +2 quirks nuevos de
`stock_available_transversal.test.sql`) — 36/569 a partir de acá.
Actualizado una vez más con BLOQUE G (regresión final de integración,
sin migración nueva — `web_circuit_end_to_end_regression.test.sql`
encadena las 6 combinaciones WEB de punta a punta + snapshot de kit +
métrica de venta cancelada, +1 quirk nuevo) — 37/613 a partir de acá.
Actualizado de nuevo con "Formas de pago habilitadas por promoción"
(`20260201000063_promotion_payment_methods.sql`, +13 quirks nuevos de
`promotion_payment_methods.test.sql` — 13 de sus 25 tests son `throws_ok` de
2 argumentos, mismo patrón que el resto de la suite) — 50/638 a partir de
acá. Actualizado una vez más con el fix de atribución THREE_FOR_TWO en
Analytics de promociones (`20260201000064_three_for_two_promotion_attribution_fix.sql`,
`three_for_two_promotion_attribution_fix.test.sql` no agrega quirks — no usa
`throws_ok`) — 50/654 a partir de acá. Actualizado una vez más con el
backfill histórico quirúrgico de las 4 sale_items conocidas
(`PROD_HISTORICAL_BACKFILL_065_three_for_two.sql`, +4 quirks nuevos de
`three_for_two_historical_backfill.test.sql` — sus 4 guards se prueban con
`throws_ok` de 2 argumentos, mismo patrón que el resto de la suite) —
54/666 a partir de acá. Actualizado una vez más con la corrección de regla
de negocio de promociones: el ganador se resuelve por grupo de productos
contestados (overlap + prioridad), no por venta completa — antes, una
promoción no-stackable que matcheaba bloqueaba a cualquier otra promoción
del carrito aunque no compartiera ningún producto
(`20260201000066_promotion_per_line_stacking_fix.sql`, +2 quirks nuevos de
`promotion_per_line_stacking.test.sql` — casos 14 y 16, `throws_ok` de 2
argumentos sobre la validación de medios de pago por promoción de la
migración 63, mismo patrón que el resto de la suite; `promotions.test.sql`
se actualiza en el mismo bloque — invierte la expectativa de un test
existente que hoy queda incorrecta bajo la regla nueva, sin sumar ni restar
tests ni quirks en ese archivo) — 56/684 a partir de acá. Actualizado una
vez más con la nueva condición de precio "6 cuotas sin interés"
(`20260201000067_card6_installments_and_billing.sql`, +6 quirks nuevos de
`card6_installments.test.sql` — casos 10, 14, 15, 20, 21 y 22 del pedido
original (tests 11, 15, 16, 21, 22 y 23 del archivo), todos `throws_ok` de
2 argumentos sobre rechazos esperados (promoción que no admite CARD_6,
venta sin cliente identificado, venta sin cuenta de ingreso, y la
regresión de Transferencia/CARD_1/CARD_3), mismo patrón que el resto de la
suite; `customer_email.test.sql` (Cambio 1, email opcional — reuso de
`customers.email` existente, sin migración nueva) no usa `throws_ok`, así
que no agrega quirks) — 62/711 a partir de acá. Actualizado una vez más con
los campos aditivos de doctor_sales_detail para Comisiones por Dra. →
Exportar PDF (`20260201000068_doctor_sales_detail_pdf_fields.sql`,
`doctor_sales_detail_pdf_fields.test.sql`, 14 casos, ninguno `throws_ok` —
no agrega quirks) — 62/725 a partir de acá. Actualizado una vez más con
Condiciones de precio administrables (`20260201000069_price_conditions_admin.sql`,
+8 quirks nuevos de `price_conditions_admin.test.sql` — casos A7 (condición
futura con requires_billing=true exige cuenta), B1 (sede inválida en
`create_price_condition`), D2/D3 (disponibilidad rechazada server-side en
Sede 37/Web), G1 (no-admin no puede crear una condición) y H2/H3/H4
(regresión Transferencia/CARD_1/CARD_6 exigiendo cuenta) — los 8, `throws_ok`
de 2 argumentos sobre rechazos esperados, mismo patrón que el resto de la
suite — 70/758 a partir de acá. Actualizado una vez más con
`update_price_condition` (Checkpoint 2, `20260201000070_update_price_condition.sql`
— edición atómica en lockstep price_conditions/payment_methods, más
`p_priority` opcional agregado a `create_price_condition` vía
`DROP FUNCTION IF EXISTS` + `CREATE OR REPLACE`, sin tocar el archivo de la
69), con la Sección I ampliada del mismo archivo
(`price_conditions_admin.test.sql`, +15 casos: I1-I10 edición atómica/lockstep
name-activo/toggle de disponibilidad/atomicidad ante sede inválida/permisos
RLS/rechazo de editar la condición BASE; J1-J2 camino Web real vía
`create_web_order` con `reset role`, usando la condición de prueba "PCA
Futura Billing False" — no "2 cuotas sin interés" — para aislar la prueba de
disponibilidad de una limitación estructural preexistente y ajena a esta
feature: `create_web_order` nunca expuso `p_payment_account_id`/
`p_payment_status`, así que ninguna condición con `requires_billing=true`
puede vender por ahí, cualquiera sea su código; K1-K9 prueba estructural
"9 cuotas test", condición ficticia creada solo para el test que demuestra
disponibilidad por sede/Web, `requires_billing`, y precio configurables sin
tocar una sola línea de código) — +7 quirks nuevos (`throws_ok` de 2
argumentos, mismo patrón que el resto de la suite: I5b, I7a, I8, I9, J2, K3b,
K4, todos rechazos esperados) — 77/784 a partir de acá. Actualizado una vez
más con el circuito de pago/facturación de `create_web_order` (Checkpoint
2.1, `20260201000071_web_order_payment_fulfillment.sql` — extiende
`create_web_order` con `p_payment_status`/`p_payment_account_id`/
`p_fulfillment_type` opcionales, default null, sin tocar `fn_create_sale_core`;
V1 solo soporta SHIPPING, nunca expuesto en el contrato público de
`POST /api/integrations/web-orders` — el route handler decide internamente.
De paso corrige un bug real encontrado probando el circuito completo:
`mark_web_order_paid` (20260201000057) nunca se había actualizado en la
migración 69 y seguía con el mismo `IN` hardcodeado de códigos que
`fn_create_sale_core`/`create_sale_exchange` ya habían dejado atrás —
afectaba a CARD_6 y a cualquier condición nueva creada desde
`/admin/condiciones-precio`, no solo a "2 cuotas sin interés". Sección L de
`price_conditions_admin.test.sql`, +19 casos — L13/L14/L15, `throws_ok` de 2
argumentos sobre rechazos esperados (PAID sin cuenta, Web deshabilitada,
SHIPPING fuera de Depósito), mismo patrón que el resto de la suite) —
80/803 a partir de acá. Actualizado una vez más con la generalización del
% de sugerencia a toda condición `PAYMENT_METHOD` en `/admin/precios` y la
visibilidad administrable en `/precios` vía `visible_in_price_lookup`
(`20260201000073_price_condition_visibility.sql` — agrega la columna y
extiende `create_price_condition`/`update_price_condition` con
`DROP FUNCTION IF EXISTS` + `CREATE OR REPLACE`, sin tocar la 69/70; PATCH
semantics en `update_price_condition`: `p_visible_in_price_lookup boolean
default null` preserva el valor existente cuando se omite, para no romper
callers que no lo pasan, como el toggle "Activa"). Sección M nueva de
`price_conditions_admin.test.sql`, +9 casos (M1-M7) — M6/M7, `throws_ok` de
2 argumentos sobre rechazos esperados (BASE/LIST sigue sin ser editable ni
para ocultarla; un vendedor no puede tocar `visible_in_price_lookup`),
mismo patrón que el resto de la suite, +2 quirks nuevos — 82/835 a partir
de acá. `precios_consulta.test.sql` suma 4 casos más (Condiciones 16-19,
visibilidad sobre una condición `PAYMENT_METHOD` de código desconocido)
sin agregar quirks — no usan `throws_ok`.
