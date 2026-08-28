# Motor de precios (`pricing-engine`)

## Fuente de verdad

La única implementación que decide una venta real es la función SQL `fn_pricing_quote()`
(`supabase/migrations/20260101000009_functions.sql`). Se expone de dos formas:

- `quote_sale(items, payment_method_id, sold_at?)` — RPC de solo lectura. El frontend la llama en
  cada cambio del carrito para mostrar la estimación ("recalcula automáticamente").
- `create_sale(...)` — la llama internamente antes de escribir nada. Si el resultado no es válido
  (`ok = false`), aborta toda la transacción con el mismo mensaje que vio la vendedora en el preview.

El espejo en TypeScript (`lib/pricing/engine.ts`) implementa **la misma regla de negocio** para:
poder testear la lógica sin base de datos (`tests/pricing.test.ts`, los 12 casos del prompt maestro),
y compartir tipos (`PricingInput`, `PricingLine`, `PricingResult`) entre frontend y backend. **No se
usa para decidir ventas reales** — eso es exclusivo de la función SQL.

## Algoritmo

Input: lista de `{ product_id, quantity }`, un `payment_method_id`, y una fecha (`sold_at`, default
`now()`).

1. **Cantidad promocionable**: `total_qty = Σ quantity` de los ítems cuyo producto tiene
   `promo_eligible = true`. Los kits cuentan como sí mismos (no se expanden para este cálculo).
2. **Elegir UNA condición** (nunca se acumulan). Se recorren `price_conditions` activas ordenadas por
   `priority ASC` (menor número = mayor precedencia) y se toma la **primera que matchea**:
   - `rule_type = 'BASE'` → siempre matchea (es el fallback, típicamente `LIST`).
   - `rule_type = 'PAYMENT_METHOD'` → matchea si `payment_method_id` es el elegido.
   - `rule_type = 'QUANTITY'` → matchea si `total_qty >= min_units`.
3. **Precio por línea**: para la condición elegida, busca en `product_prices` el precio
   `activo, > 0, vigente en sold_at` para `(product_id, condition_id)`. Si falta, **la venta entera se
   rechaza** con un mensaje humano (`"Este producto no tiene precio configurado para <condición>: <producto>."`).
   Nunca cae a otra condición ni sustituye por $0.
   - El precio de **lista** (para mostrar el "antes/ahorro") es opcional: si el producto no tiene un
     precio `LIST` cargado (ej. `ACC-NEC`), se usa el mismo precio de venta como referencia (ahorro 0)
     en vez de bloquear la venta — la condición elegida sí tenía precio válido.
4. **Totales**: `subtotal = Σ list_unit_price·qty`, `total = Σ sale_unit_price·qty`,
   `discount_total = subtotal - total`.

## Precedencia por defecto (editable sin deploy)

`price_conditions.priority`, menor = gana:

1. `QTY_3_PLUS` — 3+ productos — 25% OFF (referencia comercial)
2. `QTY_2` — 2 productos — 20% OFF
3. `CASH` — efectivo — 15% OFF
4. `TRANSFER` — transferencia — 10% OFF
5. `INSTALLMENTS_3` — 3 cuotas — precio lista
6. `LIST` — precio lista (fallback, siempre matchea)

Un admin puede reordenar cambiando `priority`, desactivar una condición (`active = false`), o cambiar
su `discount_percent` informativo — nada de esto requiere un deploy de la aplicación. **El
`discount_percent` es solo texto comercial**; el número que realmente se cobra vive siempre en
`product_prices.amount` (ver más abajo, por qué no se puede calcular como `lista × porcentaje`).

## Por qué el precio no se calcula como `lista × (1 - porcentaje)`

La lista real tiene redondeos comerciales. Ejemplo real:

```
Precio lista Vitamina C = 45.300
15% OFF matemático      = 38.505
Precio comercial real   = 38.500
```

Por eso `product_prices` guarda el **monto exacto** por producto y condición, no una fórmula. El
`discount_percent` de `price_conditions` es puramente informativo/UI ("Efectivo — 15% OFF").

## Historial de precios

`product_prices` nunca se actualiza in-place. `set_product_price(product, condition, amount,
valid_from?)`:

1. cierra la vigencia de la fila activa anterior (`valid_until = valid_from` de la nueva),
2. inserta una fila nueva con el monto y `created_by`,
3. registra en `audit_logs`.

`sale_items` guarda un **snapshot** (`list_unit_price`, `sale_unit_price`, ...) al momento de la
venta. Cambiar un precio hoy nunca altera una venta pasada, porque `create_sale()` no vuelve a leer
`product_prices` retroactivamente para ventas ya confirmadas — el snapshot ya está escrito.

## Casos de test (`tests/pricing.test.ts` + `supabase/tests/database/pricing_and_sales.test.sql`)

Los 12 casos del prompt maestro (sección 41), incluidos: 1 Vitamina C por cada medio de pago, 2 y 3+
productos, no acumulación (3 productos + transferencia = solo QTY_3_PLUS), producto sin precio
configurado se rechaza, venta de kit descuenta componentes, stock insuficiente en un componente
rechaza la venta completa, cancelación repone stock exacto, comisión solo sobre líneas
`commissionable`, y un precio nuevo no reescribe una venta histórica.
