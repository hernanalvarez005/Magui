# Base de datos

Motor: PostgreSQL (Supabase). Todas las migraciones están en `supabase/migrations/`, numeradas y
pensadas para reconstruir el esquema completo desde cero, en este orden:

1. `20260101000001_extensions_enums.sql` — extensiones (`pgcrypto`, `citext`, `pg_trgm`) y enums.
2. `20260101000002_profiles.sql` — perfiles, `stock_locations`, `profile_locations`, helpers de permisos.
3. `20260101000003_catalog.sql` — canales, medios de pago, productos, `kit_components`.
4. `20260101000004_pricing.sql` — `price_conditions`, `product_prices` (historizado).
5. `20260101000005_customers_doctors.sql` — clientes y doctoras.
6. `20260101000006_sales.sql` — `sales`, `sale_items`, contador de `sale_number`.
7. `20260101000007_inventory.sql` — `inventory_balances`, `stock_movements`, transferencias,
   `fn_apply_stock_movement`, `fn_kit_buildable_qty`.
8. `20260101000008_audit_settings.sql` — `audit_logs`, `app_settings`.
9. `20260101000009_functions.sql` — RPC de negocio (`fn_pricing_quote`, `quote_sale`, `create_sale`,
   `cancel_sale`, `transfer_stock`, `adjust_stock`, `set_product_price`).
10. `20260101000010_rls.sql` — Row Level Security + grants.
11. `20260101000011_indexes.sql` — índices de performance.
12. `20260101000012_seed_data.sql` — datos iniciales reales (idempotente).
13. `20260101000013_kit_availability_view.sql` — vistas `kit_availability` y `product_stock_status`.
14. `20260101000014_audit_triggers.sql` — auditoría automática de UPDATE en tablas editadas directo
    desde `/admin` (`price_conditions`, `products`, `profiles`, `doctors`).
15. `20260101000015_dashboard_reports.sql` — `dashboard_report()`, agregación 100% server-side para
    `/dashboard` y `/dashboard/comisiones`.
16. `20260101000016_web_orders.sql` — `seller_id` nullable, refactor a `fn_create_sale_core()`
    compartido, `create_web_order()` (exclusivo de `service_role`) y hardening de `GRANT`/`REVOKE`.

## Convenciones

- Todo importe: `numeric(14,2)`. Nunca `float`/`double`.
- Todo porcentaje (comisión, descuento informativo): `numeric(5,4)` en rango `[0,1]`.
- Timestamps: `timestamptz`, se interpretan en `America/Argentina/Buenos_Aires` en la capa de app.
- Ningún hard delete de datos transaccionales. Los "borrados" son banderas `active` o estados
  (`cancelled`) + ledger de auditoría.
- Toda tabla con datos de negocio tiene RLS habilitada. Ver `supabase/migrations/..._rls.sql`.

## Tablas principales

Ver el diagrama ER completo en `docs/architecture.md`. Notas relevantes que no se ven en el diagrama:

- **`sale_number_counters`**: soporte interno de `fn_next_sale_number()`, sin policies (nadie la lee
  directo). Garantiza números de venta sin colisiones bajo concurrencia (fila bloqueada por sede+día).
- **`inventory_balances`**: PK compuesta `(location_id, product_id)`. Es un caché — la única función
  autorizada a escribirla es `fn_apply_stock_movement()`, invocada siempre dentro de una RPC de
  negocio (nunca directo desde el cliente).
- **`stock_movements`**: constraint `stock_movements_sign_matches_type` obliga a que el signo de
  `quantity_delta` sea consistente con `movement_type` (ej. `SALE` siempre negativo).
- **`product_prices`**: nunca se hace `UPDATE amount`. `set_product_price()` cierra la vigencia
  anterior (`valid_until`) y crea una fila nueva. Esto es lo que garantiza que una venta histórica
  jamás cambie de precio retroactivamente.

## RLS: modelo de permisos

Helpers en `public` (todos `SECURITY DEFINER`, solo lectura):

- `is_active_profile()` — el usuario logueado tiene un `profiles.active = true`.
- `is_admin()` — además, `role = 'admin'`.
- `has_location_access(location_id)` — existe una fila en `profile_locations` para ese usuario y
  sede, y el usuario está activo. **Se aplica igual a admin y a seller**: un admin sin fila en
  `profile_locations` para Sede 25 no ve nada de Sede 25.

Patrón general de policy:

| Tabla | SELECT | INSERT/UPDATE/DELETE |
|---|---|---|
| `products`, `price_conditions`, `payment_methods`, `sales_channels`, `stock_locations`, `doctors` | cualquier usuario activo | solo `is_admin()` |
| `product_prices` | cualquier usuario activo | **ninguna** — solo vía `set_product_price()` |
| `customers` | cualquier usuario activo | insert: cualquier activo · update: creador o admin |
| `sales` / `sale_items` | `has_location_access` + (`is_admin()` o `seller_id = auth.uid()`) | **ninguna** — solo vía `create_sale()` |
| `inventory_balances` / `stock_movements` | `has_location_access(location_id)` | **ninguna** — solo vía las RPC de stock |
| `stock_transfers` / `stock_transfer_items` | acceso a origen o destino | **ninguna** — solo vía `transfer_stock()` |
| `audit_logs` | solo `is_admin()` | **ninguna** — las RPC insertan como `SECURITY DEFINER` |
| `app_settings` | cualquier usuario activo | solo `is_admin()` |

Los reportes financieros (comisiones por doctora, KPIs de facturación) no dependen solo de RLS de fila:
se sirven mediante RPC dedicadas que además exigen `is_admin() or profiles.can_view_financial_reports`.

## RPC de negocio (todas `SECURITY DEFINER`, validan permisos "a mano")

| Función | Quién puede | Qué hace |
|---|---|---|
| `quote_sale(items, payment_method_id, sold_at?)` | cualquier usuario activo | Preview de precio (solo lectura). |
| `create_sale(...)` | usuario activo con acceso a la sede | Recalcula precio, valida stock (expandiendo kits), crea venta + detalle + movimientos. Atómico. |
| `cancel_sale(sale_id, reason)` | admin con acceso a la sede de la venta | Marca cancelada, repone stock exacto. No permite doble cancelación. |
| `transfer_stock(from, to, items, notes?)` | admin con acceso a ambas sedes | Transferencia atómica (`TRANSFER_OUT` + `TRANSFER_IN`). |
| `adjust_stock(location, product, delta, reason, notes?)` | admin, o seller con `can_adjust_stock = true` | Ajuste auditado de stock. |
| `set_product_price(product, condition, amount, valid_from?)` | admin | Cierra vigencia anterior y versiona el precio nuevo. |
| `dashboard_report(from, to, location?, channel?)` | admin, o seller con `can_view_financial_reports = true` | Agregación server-side para `/dashboard` y `/dashboard/comisiones` (KPIs, series, top productos, comisión por doctora). |
| `create_web_order(items, location, payment_method, external_source, external_order_id, ...)` | **solo `service_role`** (nunca `authenticated`/`anon`) | Ingesta idempotente de pedidos del canal Web desde `POST /api/integrations/web-orders`. Comparte lógica con `create_sale` vía `fn_create_sale_core()`, pero sin exigir un usuario logueado — `seller_id` queda `null`. |

Postgres otorga `EXECUTE` a `PUBLIC` en toda función nueva por defecto. Los helpers internos
(`fn_pricing_quote`, `fn_apply_stock_movement`, `fn_next_sale_number`, `fn_create_sale_core`) tienen
ese privilegio revocado explícitamente — solo son invocables desde las RPC públicas de la tabla de
arriba (el dueño de la función, que corrió las migrations, conserva su propio privilegio, así que las
llamadas internas entre funciones siguen funcionando).

## Reconstrucción del esquema

```bash
supabase db reset   # aplica todas las migraciones desde cero + seed
```

En un entorno remoto: `supabase link` y luego `supabase db push`.
