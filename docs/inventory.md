# Inventario

## Modelo

- **`inventory_balances`** es un **caché derivado**, no la fuente de verdad. PK
  `(location_id, product_id)`. La única función autorizada a modificarlo es
  `fn_apply_stock_movement()` — bloquea (`SELECT ... FOR UPDATE`) la fila, valida stock negativo, la
  actualiza, e inserta el `stock_movements` correspondiente, todo en la misma transacción.
- **`stock_movements`** es el ledger auditable e inmutable (sin policy de UPDATE/DELETE para
  clientes). `quantity_delta` lleva signo; un constraint (`stock_movements_sign_matches_type`) obliga
  a que el signo sea consistente con el `movement_type`.
- Los **kits nunca tienen saldo propio**. `products.track_stock = false` para todo kit/combo
  (incluido `ACC-PADS2`, que es un combo de 2× `ACC-PADS1`). Vender un kit expande sus
  `kit_components` y descuenta cada componente.

## Disponibilidad de kits

`fn_kit_buildable_qty(kit_product_id, location_id)` calcula, para una sede, el mínimo entre
componentes de `floor(saldo_componente / cantidad_requerida)`. Ejemplo del prompt maestro:

```
Vitamina C: 3        →  3 / 1 = 3
Niacinamida: 8        →  8 / 1 = 8
Disponible KIT-VN = min(3, 8) = 3
```

La UI de `/stock` y las cards de producto en `/ventas/nueva` llaman a esta función (vía una vista o
RPC de lectura) para mostrar "Disponibles para armar: X" — nunca se persiste ese número.

## Tipos de movimiento

| Tipo | Signo | Cuándo |
|---|---|---|
| `INITIAL` | libre | Migración de stock inicial (ver seed) |
| `PURCHASE` | + | Ingreso de mercadería |
| `SALE` | − | Descuento automático al confirmar una venta |
| `SALE_CANCEL` | + | Reposición al cancelar una venta |
| `ADJUSTMENT_PLUS` / `ADJUSTMENT_MINUS` | + / − | Ajuste manual auditado |
| `TRANSFER_OUT` / `TRANSFER_IN` | − / + | Transferencia entre sedes |
| `RETURN` | + | Devolución (reservado) |

## Venta → stock

`create_sale()` expande cada línea del carrito: si el producto tiene `track_stock = true`, requiere
esa cantidad directamente; si es un kit (`track_stock = false`), suma `cantidad_kit × kit_components.quantity`
por cada componente. Agrupa por `product_id` (una venta puede pedir un producto suelto y también un
kit que lo contiene) y aplica un único movimiento `SALE` por componente, bloqueando las filas en orden
determinístico (`order by product_id`) para evitar deadlocks bajo concurrencia. Si algún componente no
alcanza, `fn_apply_stock_movement()` lanza una excepción humana
(`"No hay stock suficiente de <producto>. Disponible: X. Requerido: Y."`) y **toda la transacción se
revierte** — no queda ninguna venta ni movimiento parcial.

## Cancelación

`cancel_sale()` repite exactamente la misma expansión de kits sobre `sale_items` (no sobre el carrito
original) y aplica movimientos `SALE_CANCEL` positivos por la misma cantidad. Un constraint en `sales`
(`sales_cancellation_consistency`) impide que una venta quede cancelada sin motivo/autor/fecha, y
`cancel_sale()` verifica `status <> 'cancelled'` antes de operar — cancelar dos veces lanza
`"La venta ya fue cancelada."`.

## Transferencias

`transfer_stock(from, to, items, notes?)` crea una fila en `stock_transfers` + una por producto en
`stock_transfer_items`, y por cada ítem aplica `TRANSFER_OUT` en origen y `TRANSFER_IN` en destino.
Solo pueden transferirse productos con `track_stock = true` (no kits). Por defecto no se puede
transferir más de lo disponible (`app_settings.allow_transfer_overdraft = false`); habilitarlo requiere
que un admin lo active explícitamente.

## Ajustes

`adjust_stock(location, product, delta, reason, notes?)` — requiere `is_admin()` o
`profiles.can_adjust_stock = true` con acceso a esa sede. `reason` es un enum cerrado (recepción,
rotura, vencimiento, diferencia de conteo, devolución, otro). Cada ajuste queda en `audit_logs` además
del movimiento.

## Stock negativo

`app_settings.allow_negative_stock` (default `false`) es el interruptor global. Todas las RPC de stock
lo consultan y lo pasan como `p_allow_negative` a `fn_apply_stock_movement()`. Está pensado para
quedar en `false` en producción: la validación ocurre **dentro** de la transacción (con el row lock ya
tomado), así que no hay ventana de carrera entre "vi que había stock" y "lo descuento".
