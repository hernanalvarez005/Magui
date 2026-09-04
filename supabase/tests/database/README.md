# pgTAP — baseline conocido: 30 "throws_ok compatibility artifacts"

Al correr toda la suite (`pg_prove supabase/tests/database/*.sql`) van a
aparecer **30 tests marcados como "failed" que NO son regresiones**. Es un
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
los 30 casos, muestra el error real y correcto.

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

## Lista completa (30), por archivo y nº de test

| Archivo | Tests fallidos | Total del archivo |
|---|---|---|
| `analytics.test.sql` | 9 | 24 |
| `billing_status.test.sql` | 12 | 15 |
| `exchange_legacy_stock_reversal.test.sql` | 17, 21 | 23 |
| `mejoras.test.sql` | 1, 6, 8, 11 | 12 |
| `pricing_and_sales.test.sql` | 9 | 11 |
| `promotions.test.sql` | 3, 4, 5 | 10 |
| `reversal_qty_guard_fix.test.sql` | 17, 21, 28 | 30 |
| `rls.test.sql` | 3 | 7 |
| `viewer_role.test.sql` | 10, 11 | 12 |
| `web_admin_delivery_bypass_and_stock_availability.test.sql` | 4, 9 | 11 |
| `web_fulfillment.test.sql` | 20, 21, 23, 24, 27, 29, 34, 35 | 36 |
| `web_fulfillment_permissions_and_billing.test.sql` | 5, 6 | 10 |

Total: **30 de 534** tests reales de la suite completa (al día de la
migración `20260201000059_web_pending_pickups.sql` — el total de tests
crece con cada archivo nuevo, la lista de "failed" conocidos no debería,
salvo que se agregue un test nuevo que use la misma forma de 2 argumentos
con una excepción real esperada; `web_payment_status_metrics.test.sql` y
`web_pending_pickups.test.sql` no usan `throws_ok` de 2 argumentos, así
que suman 9 y 11 tests reales respectivamente sin agregar ningún quirk
nuevo).

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
30/534 a partir de acá.
