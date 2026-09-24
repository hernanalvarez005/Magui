# Auditoría Técnica Integral — Magui Rejuve V1

**Rama de auditoría:** `claude/magui-v1-performance-audit` (creada desde `origin/main` en `80026d3`, exclusiva para este documento — no contiene código).
**Base auditada:** `main` @ `80026d3` (Merge PR #3 — Comisiones por Dra. PDF).
**NO auditado:** `claude/magui-v1-elegante-ui` (exploración visual, fuera de alcance por instrucción explícita).
**Estado:** EN PROGRESO — documento vivo, se actualiza por checkpoint. Ningún fix implementado todavía.

---

## CHECKPOINT 0 — Verificación de entorno y seguridad

- `git fetch origin` ejecutado. `origin/main` = `80026d3`, working tree limpio antes de empezar.
- Rama `claude/magui-v1-performance-audit` creada desde `origin/main` (no desde la rama visual).
- Regla de producción: **no se ejecutó, ni se va a ejecutar, ningún INSERT/UPDATE/DELETE/UPSERT/migration/SQL destructivo contra producción durante esta auditoría.** No se usó `SUPABASE_SERVICE_ROLE_KEY` en ningún momento.
- Este documento es el único artefacto que se commitea en esta rama.

### Qué puede medirse en este entorno y qué no (declarado antes de medir nada — sección 4/6 del pedido)

| Capacidad | Disponible | Detalle |
|---|---|---|
| Lectura estática del código (`main` completo) | ✅ Sí | Sin restricciones — es la fuente principal de evidencia de esta auditoría. |
| PostgreSQL **local** (`magui_test`, rebuild completo de las 68+ migraciones vigentes) | ✅ Sí | `psql` directo, `EXPLAIN (ANALYZE, BUFFERS)` real, dataset sintético permitido y **exigido** por el pedido (sección 27) — se construye acá, nunca en producción. |
| `next build` / `next dev` local | ✅ Sí | Bundle real, rutas reales, tiempos de build. |
| Sesión autenticada real (local o producción) | ❌ No | No tengo credenciales de ningún usuario Magui. No voy a pedir que se creen para mí (violaría "no crear usuarios/fixtures"). Todo lo que dependa de una sesión logueada real (TTFB de una página protegida, Web Vitals reales, navegación autenticada) queda **NO MEDIDO** salvo que el usuario decida compartir/generar algo puntual bajo su propio criterio. |
| Base de datos de **producción** (conexión directa, `psql`/service role) | ❌ No disponible y no se va a solicitar | Ninguna medición de esta auditoría depende de acceso directo a producción. Todo lo referido a "producción" en este informe es **inferido del código** (qué se ejecutaría) salvo que se indique explícitamente lo contrario. |
| Supabase CLI / Dashboard | ❌ No instalado/logueado en este entorno (`supabase --version` → command not found) | Métricas de dashboard (logs, métricas de proyecto, Advisors) → **NO MEDIDO**. |
| Vercel CLI / Dashboard / Analytics | ❌ No instalado/logueado (`vercel --version` → command not found) | Región de despliegue, cold starts reales, Web Vitals de campo, logs de función → **NO MEDIDO**. |
| Playwright + Chromium headless | ✅ Sí (preinstalado) | Sirve para medir HTML/CSS/JS servido localmente sin sesión (páginas públicas: `/login`) y para deep-dive de bundle; **no** sirve para medir páginas protegidas sin credenciales. |

**Consecuencia directa para el resto del informe:** cualquier fila de la tabla de baseline (sección C) que dependa de una request real contra una ruta protegida, en local o producción, se declara **NO MEDIDO** en la columna Entorno salvo que haya sido efectivamente ejecutada. Las columnas de queries/filas/riesgo de esas mismas rutas sí se completan por **inspección estática** del código server-side (que no requiere sesión para leerse, solo para ejecutarse) y se marcan **INFERIDO**.

---

## CHECKPOINT 1 — Mapa del sistema

### Stack real detectado (no asumido)

| Capa | Detectado | Evidencia |
|---|---|---|
| Framework | Next.js 16.3.3, App Router, Turbopack | `package.json:"next": "16.3.3"`, `next.config.ts` sin config custom |
| React | 19.2.8 | `package.json` |
| TypeScript | ^5 | `package.json` |
| Estilos | Tailwind CSS v4 (`@import "tailwindcss"`, sin `tailwind.config.js`) | `app/globals.css` |
| Componentes UI | shadcn/ui copiado al repo sobre Radix UI | `components/ui/*.tsx`, `@radix-ui/react-*` en `package.json` |
| Backend | Supabase (Postgres + Auth + PostgREST + RPC), sin capa ORM intermedia | `@supabase/ssr` ^0.12.5, `@supabase/supabase-js` ^2.112.4 |
| Storage | **No detectado uso real de Supabase Storage** | No hay bucket ni `storage.from(` en el código de `main`; `public/brand/` son assets estáticos del repo, no Storage. Confirmar explícitamente: **Storage NO está en uso en V1** (contradice la expectativa inicial del pedido — se declara así, no se asume). |
| Deploy | Vercel (inferido: `next build`/`next start` estándar, sin Dockerfile, sin config de otro proveedor) | INFERIDO — no hay acceso a Vercel para confirmar. |
| Exportaciones | CSV propio (`lib/csv.ts`), XLSX real (`exceljs`), PDF real (`jspdf` + `jspdf-autotable`) | `package.json`, `lib/xlsx-ventas.ts`, `lib/pdf-comisiones.ts` |

### Inventario cuantitativo

| Elemento | Cantidad | Comando/evidencia |
|---|---|---|
| Migraciones SQL | 83 archivos (`20260101000001` … `20260201000068`) | `ls supabase/migrations \| wc -l` |
| Funciones/RPC `public.*` (nombres únicos, última definición vigente) | 60 | `grep -rhoE "create or replace function public\.[a-z_0-9]+"` deduplicado |
| Tablas `public.*` | 29 | `grep create table` |
| Vistas `public.*` | 3 (`kit_availability`, `product_stock_status`, `sale_item_net`) | |
| Policies RLS (nombres distintos declarados; el número vigente puede ser menor por `drop policy`/`create policy` repetidos sobre el mismo nombre) | 59 declaraciones, sobre 27 tablas | Ver nota metodológica abajo |
| Páginas (`page.tsx`) | 24 | `find app -name page.tsx` |
| Route Handlers (`route.ts`) | 8 (7 exports + 1 integración Web) | `find app -name route.ts` |
| Server Actions (`"use server"`) | 2 archivos (`app/login/actions.ts`, `app/(app)/admin/usuarios/actions.ts`) | |
| Archivos `"use client"` | 56 de 145 (~39%) en `app/`+`components/`+`lib/` | |
| Tests pgTAP (`.sql`) | 44 archivos | `find supabase/tests -name "*.sql"` |
| Tests Vitest (`.test.ts`) | 15 archivos | `find tests -name "*.test.ts"` |

**Nota metodológica sobre el conteo de policies:** el conteo de 59 es sobre nombres de `create policy` declarados en el historial de migraciones — varias migraciones hacen `drop policy X; create policy X` sobre el mismo nombre para reemplazar una regla (patrón correcto, documentado en los propios comentarios de las migraciones, ej. `20260201000023_viewer_role_permissions.sql`). El número de policies **realmente activas hoy** es menor y requiere consultar `pg_policies` contra una base ya migrada — se hace en el Checkpoint 3 (Database Report), no acá, para no mezclar inventario estático con estado real de una base.

### Flujos críticos identificados (24 páginas reales, ninguna inventada)

| Página | Ruta | Tipo | Datos que toca (primera pasada) |
|---|---|---|---|
| Home (según rol) | `/` | Server Component | `sales` (hoy, sin límite — ver Checkpoint 2), `product_stock_status`, promociones activas |
| Dashboard | `/dashboard` | Server Component | RPC `dashboard_report`, RPC `dashboard_products_breakdown` |
| Facturación por producto | `/dashboard/productos` | Server Component | RPC `product_revenue_report` |
| Comisiones por doctora (listado) | `/dashboard/comisiones` | Server Component | RPC `dashboard_report` (reuso, `commission_by_doctor`) |
| Comisiones por doctora (detalle) | `/dashboard/comisiones/[doctorId]` | Server Component | RPC `doctor_sales_detail` |
| Nueva Venta | `/ventas/nueva` | Server Component + Client grande (`new-sale-cart.tsx`, 796 líneas) | `products`, `doctors`, RPC `quote_sale`/`fn_pricing_quote`, RPC `create_sale`/`create_web_order` |
| Ventas (listado) | `/ventas` | Server Component | `sales` **con paginación real** (`.range`, `count:"exact"`, `PAGE_SIZE=30`) — ver Checkpoint 2 |
| Detalle de venta | `/ventas/[id]` | Server Component | `sales`, `sale_items`, `stock_movements`, `customers`, `doctors`, `products` |
| Productos (admin) | `/admin/productos` | Server + Client | `products` |
| Kits (admin) | `/admin/kits` | Server + Client | `products`, `kit_components` |
| Precios (consulta) | `/precios` | Server Component | `products`, `product_prices` |
| Precios (admin/matriz) | `/admin/precios` | Server + Client (`price-matrix.tsx`) | `products`, `product_prices`, RPC `set_product_price`/`clear_product_price` **en loop secuencial** — ver hallazgo Checkpoint 2 |
| Condiciones de precio (admin) | `/admin/condiciones-precio` | Server + Client | `price_conditions` |
| Promociones (admin) | `/admin/promociones` | Server + Client | `promotions`, `promotion_products`, `promotion_payment_methods`, RPC `set_promotion_products`/`set_promotion_payment_methods` |
| Facturación pendiente (admin) | `/admin/facturacion` | Server Component | `sales`, `customers`, `products` |
| Bancos/Cuentas (admin) | `/admin/cuentas` | Server + Client | `payment_accounts` |
| Doctoras (admin) | `/admin/doctores` | Server + Client | `doctors` |
| Usuarios (admin) | `/admin/usuarios` | Server + Client + Server Action | `profiles`, `profile_locations`, Auth admin (service role, justificado en el propio código — ver Checkpoint 3/Seguridad) |
| Stock | `/stock` | Server Component | `product_stock_status` |
| Movimientos de stock | `/stock/movimientos` | Server Component | `stock_movements` **con `.limit()` — confirmar exacto en Checkpoint 2** |
| Clientes | `/clientes` | Server + Client | `customers` |
| Cambios/Devoluciones | `/cambios` | Server + Client | `sales`, `sale_items`, RPC `create_sale_exchange`/`create_sale_return` |
| Notificaciones (pedidos Web pendientes) | `/notificaciones` | Server Component | RPC `web_pending_pickups` |
| Historial de notificaciones | `/notificaciones/historial` | Server Component | RPC `web_order_history` |

**Rutas Web (API, no UI):** `POST /api/integrations/web-orders` (creación de pedidos Web externos, autenticado por token compartido — ver Checkpoint 3 seguridad). No hay una pantalla "Ventas Web" separada: el canal Web se filtra dentro de `/ventas` (columna canal) y se opera desde `/notificaciones` — confirmado también en el bloque de exploración visual anterior de esta misma conversación, consistente acá.

**Exportaciones (Route Handlers, todas server-side, ninguna en el bundle cliente — se confirma con evidencia en Checkpoint 4):**
`/api/export/ventas` (XLSX, `exceljs`), `/api/export/comisiones` (CSV), `/api/export/comisiones-doctora/[doctorId]/pdf` (PDF, `jspdf`), `/api/export/detalle-ventas` (CSV), `/api/export/facturacion-productos` (CSV), `/api/export/inventario` (CSV), `/api/export/movimientos` (CSV).

### Auth: middleware → layout → page → server actions (mapa de resolución, no medición todavía)

1. `lib/supabase/proxy.ts` (`updateSession`, invocado como middleware de Next 16) — llama `supabase.auth.getUser()` en **cada** request no-asset. Esto es correcto y necesario (revalida el JWT contra Auth, a diferencia de `getSession()`) — no se recomienda eliminarlo, es un control de seguridad, no redundancia. Ambos clientes (`server.ts` y `proxy.ts`) usan `fetchWithTimeout(8000)` como `fetch` — mismo mecanismo en los dos puntos.
2. `app/(app)/layout.tsx` — llama `getCurrentProfile()` (definida en `lib/auth/get-profile.ts`, envuelta en `cache()` de React) una vez por request; cualquier `page.tsx` hijo que también llame `getCurrentProfile()` reutiliza la misma promesa dentro del mismo request (memoización real de React, no una suposición — confirmado leyendo el comentario propio del archivo y el uso de `cache()`).
3. Cada `page.tsx` protegido vuelve a llamar `getCurrentProfile()` (deduplicado por el punto 2) y algunos repiten el chequeo de rol (`if (!(profile.role === "admin" || ...)) redirect(...)`) — esto es defensa en profundidad documentada explícitamente en los propios comentarios del código ("RLS es la autoridad real, esto es para no renderizar una UI rota"), no una duplicación accidental.
4. Server Actions (`app/login/actions.ts`, `app/(app)/admin/usuarios/actions.ts`) resuelven su propia sesión vía `createClient()`/`createServiceRoleClient()` — el uso de service role en `admin/usuarios/actions.ts` está acotado a operaciones de administración de usuarios (crear/desactivar) y **nunca** se importa desde un componente cliente (confirmado: no hay `"use client"` en ese archivo ni imports cruzados) — evaluación de seguridad, no de performance, se detalla en Checkpoint 3.

Este mapa de Auth se retoma con mediciones concretas (cuántas veces se resuelve por request, dónde hay trabajo redundante real vs. memoización de React) en el Checkpoint 4 (Frontend).

---

## CHECKPOINT 2 (EN PROGRESO) — Baseline, PostgREST, paginación, `.in()`, N+1, waterfalls

### Inventario cuantitativo de patrones de query (sección 7-14 del pedido)

| Patrón | Ocurrencias en `app/`+`lib/`+`components/` |
|---|---|
| `.rpc(` | 40 |
| `.from("...")` | 164 |
| `.in(` | 46 |
| `.limit(` | 7 |
| `.range(` | 6 |
| `count: "exact"` | 3 |

Este desbalance (164 lecturas de tabla contra solo 7 `.limit()`/6 `.range()`) es la señal de entrada al riesgo de la sección 7 del pedido (límite implícito de PostgREST) — **no es una conclusión todavía**, es el punto de partida que se investiga fila por fila abajo.

### 7. PostgREST — límite implícito de filas: hallazgos concretos

**Contexto técnico (confirmado por documentación de PostgREST/Supabase, no específico de este proyecto):** una consulta `.from(tabla).select(...)` sin `.limit()` ni `.range()` explícito queda sujeta al `max-rows` configurado del lado del servidor PostgREST (valor por defecto de la plataforma Supabase: 1000 filas). Esto **NO aplica** a resultados de funciones RPC que devuelven `jsonb`/escalar (como `dashboard_report`, `doctor_sales_detail`, `product_revenue_report`) — esas funciones agregan del lado del servidor con SQL puro, sin pasar por el límite de filas de la capa REST. Esta distinción es importante y se aplica de forma consistente abajo.

Se revisaron con evidencia directa todos los `.from("sales")`, `.from("sale_items")`, `.from("customers")`, `.from("products")`, `.from("stock_movements")`, `.from("audit_logs")`, `.from("product_prices")`, `.from("doctors")` del código (68 ocurrencias combinadas). Clasificación:

| Archivo:línea | Query | Límite explícito | Alcance real | Estado |
|---|---|---|---|---|
| `app/(app)/ventas/page.tsx:40-45` | `sales` (listado principal) | `.range()` + `count:"exact"`, `PAGE_SIZE=30` | Paginado correctamente, cualquier volumen | **VALIDADO — NO TOCAR** |
| `app/api/export/ventas/route.ts:14-18` | `sales` (export XLSX) | `.limit(5000)` explícito | Exportación acotada a propósito | **VALIDADO — NO TOCAR** (ver riesgo de truncamiento silencioso abajo) |
| `app/api/export/detalle-ventas/route.ts:13-22` | `sales` (export CSV detalle) | `.limit(2000)` explícito | Igual patrón | **VALIDADO — NO TOCAR** (mismo riesgo de truncamiento silencioso) |
| `app/api/export/movimientos/route.ts:12-17` | `stock_movements` (export CSV) | `.limit(5000)` explícito | Igual patrón | **VALIDADO — NO TOCAR** (mismo riesgo) |
| `app/(app)/page.tsx:27-31` (Home, "Ventas hoy"/"Facturación hoy") | `sales` filtrado a `seller_id` + `status=confirmed` + `sold_at >= hoy` | Sin `.limit()` | Acotado implícitamente por "1 vendedora, 1 día" — no por código | **VIGILANCIA** (ver detalle abajo) |
| `app/(app)/admin/facturacion/page.tsx:37` | `sales` (facturación pendiente) | Sin `.limit()` visible en el grep — **pendiente de confirmar el resto de la query completa** | — | **NO MEDIDO todavía** (a cerrar en la próxima pasada de este checkpoint) |
| `app/(app)/stock/movimientos/page.tsx:45` | `stock_movements` (listado UI, no export) | **Pendiente confirmar si usa `.range()`/`.limit()` como `/ventas` o si es igual al export** | — | **NO MEDIDO todavía** |
| `app/(app)/ventas/[id]/page.tsx` (múltiples) | `sale_items`, `stock_movements` filtrados por `sale_id` único | Sin límite, pero acotados por PK de una sola venta (una venta real no tiene miles de líneas) | Seguro por naturaleza del dominio | **VALIDADO — NO TOCAR** |

**Hallazgo de correctitud real (no solo performance) — truncamiento silencioso en exports:**
Los tres exports con `.limit()` explícito (5000/2000/5000) **no verifican si el resultado real alcanzó el límite** (no comparan `data.length === limit` ni usan `count:"exact"` para avisar). Si un rango de fechas seleccionado por el usuario devuelve más filas que el límite, el archivo exportado se genera igual, **sin ningún aviso**, con menos filas de las que realmente existen — el usuario recibe un Excel/CSV que **parece completo pero está truncado**, sin ningún indicio visual. Esto encaja exactamente en la categoría que el pedido marca como CRÍTICO ("un truncamiento que cambia un resultado financiero"): un export de ventas truncado a 5000 filas puede subestimar facturación real si se pide, por ejemplo, "todo el año" en una operación que ya superó ese volumen.
— **Clasificación: IMPLEMENTAR** (agregar detección de truncamiento + aviso explícito al usuario; no requiere cambiar el límite en sí).
— **Evidencia:** `app/api/export/ventas/route.ts:14-18`, `app/api/export/detalle-ventas/route.ts:13-22`, `app/api/export/movimientos/route.ts:12-17`. Ninguno de los tres compara `sales.length` (o el resultado de la query principal) contra su propio límite antes de generar el archivo.
— **Volumen real necesario para disparar esto:** NO MEDIDO (depende de cuántas ventas/movimientos tiene Magui en producción hoy — no accesible desde este entorno). Se agenda como candidato a validar con el dataset sintético del Checkpoint 3, ya que 5000 filas es un volumen perfectamente alcanzable por una PyME con >1 año de operación diaria.

**Home "Ventas hoy" (`app/(app)/page.tsx:27-31,65`) — detalle del VIGILANCIA:**
`salesCount` y `revenueToday` se calculan con `.reduce()` en JS sobre el resultado de una query sin `.limit()`. El límite implícito de PostgREST (1000 filas) truncaría ese cálculo recién si una sola vendedora superara 1000 ventas confirmadas en un solo día calendario — hoy estructuralmente imposible en el flujo real de Magui (una venta presencial toma minutos, no segundos). El punto de cruce solo aparecería si se agregara en el futuro algo como una herramienta de carga masiva/bulk import de ventas históricas atribuidas a un único vendedor en una única fecha. No se recomienda tocar esto ahora.
— **Clasificación: VIGILANCIA.** Punto de cruce aproximado: >1000 ventas de un mismo vendedor en un mismo día — hoy sin mecanismo en el sistema que pueda producir ese volumen.

### 8. `.in()` grandes — riesgo real de URL/HTTP 414

Los tres export routes (`ventas`, `detalle-ventas`, `movimientos`) siguen el patrón exacto que el pedido pide detectar:

```
fetch sales (hasta 5000/2000 filas)
→ extraer saleIds = sales.map(s => s.id)
→ .from("sale_items").select(...).in("sale_id", saleIds)
```
Evidencia: `app/api/export/ventas/route.ts:68-70`, `app/api/export/detalle-ventas/route.ts:36-38`, `app/api/export/movimientos/route.ts` (vía `product`/`location` ids, volumen menor).

**Cálculo concreto (no estimado a ojo) del punto de fallo:**
Un UUID de Postgres, en su representación de texto (formato `.in()` de PostgREST), ocupa 36 caracteres + 3 caracteres de codificación URL para las comillas (`%22`) por cada lado si se citan, o 36+1 (coma) si no. Tomando el caso simple sin comillas: `36 + 1 = 37` bytes por id.
- Con el límite real de `detalle-ventas` (2000 sales): hasta 2000 × 37 ≈ **74.000 caracteres** en un único parámetro de query string.
- Con el límite real de `ventas`/`movimientos` (5000): hasta 5000 × 37 ≈ **185.000 caracteres**.

Límites típicos de infraestructura HTTP (Nginx/Cloudflare/navegadores) rondan 8.000–16.000 caracteres de URL total según el componente — **muy por debajo** de los 74.000–185.000 calculados arriba. Esto es un candidato fuerte a **HTTP 414 (URI Too Long)** real bajo volumen, no solo lentitud.
— **Clasificación provisional: IMPLEMENTAR** (alternativas ya identificadas por el pedido: RPC agregadora del lado del servidor en vez de "traer ids y volver a preguntar", o paginación por lotes controlados) — **pendiente de una prueba empírica local** (construir 2000-5000 UUIDs reales y correr la request contra `next dev` local para confirmar en qué punto exacto falla, sin tocar producción) antes de cerrar la clasificación final. Se ejecuta en la continuación de este checkpoint.
— **Matiz importante:** esto solo se dispara si el volumen de ventas del rango de fechas pedido realmente se acerca al límite (2000-5000) — con el volumen operativo normal de Magui hoy (una clínica, no una cadena), es plausible que nunca se haya alcanzado. Se declara **INFERIDO — REQUIERE MEDICIÓN**, no un bug ya confirmado en producción.

### 12. N+1 — demostrado con evidencia (no "posible")

**`components/admin/price-matrix.tsx:191-237`** (guardado de la matriz de precios en Administración → Precios): al guardar, el código recorre tres colecciones con `for (...) { await supabase.rpc/from(...) }` **secuencial, una llamada de red por elemento**:
- `dirtyPercents.length` llamadas a `.from("price_conditions").update()` (una por condición de precio con % editado).
- `toSave.length` llamadas a `.rpc("set_product_price")` (una por celda de precio editada).
- `toClear.length` llamadas a `.rpc("clear_product_price")` (una por celda vaciada).

Ejemplo concreto pedido por el usuario: si un admin edita 20 celdas de precio en una sola sesión de guardado (perfectamente plausible al revisar una lista de productos), el guardado dispara **20 round-trips de red secuenciales**, no 1. Con una latencia típica de ~150-300ms por round-trip (INFERIDO, no medido contra producción), eso son 3-6 segundos de "Guardando…" para 20 celdas — proporcional y no paralelo.

**Esto es deliberado, no un descuido** — el comentario del propio archivo (línea 182-185) explica que el guardado secuencial permite rastrear exactamente qué celdas se guardaron con éxito y cuáles fallaron, para no perder ediciones. Reemplazarlo por `Promise.all` ingenuo perdería esa semántica; `Promise.allSettled` la preservaría paralelizando. No se implementa nada ahora — se documenta como oportunidad real con solución concreta ya identificada.
— **Clasificación: IMPLEMENTAR** (bajo impacto salvo ediciones grandes; esfuerzo estimado S — ver sección de priorización en Checkpoint 6).

**Resto del código:** no se encontró el anti-patrón `.map(async ...)` en ningún archivo (`grep` sin resultados). Los demás `for (const ... of ...)` con `await` en el archivo (ej. `lib/promotions/active-promotions.ts`) tienen el `await` **fuera** del loop (2 queries totales, agrupación en JS pura adentro del loop) — confirmado leyendo el archivo completo, no solo el grep.
— **Clasificación: VALIDADO — NO TOCAR** para `lib/promotions/active-promotions.ts` específicamente.

### Pendiente para cerrar Checkpoint 2 (próxima entrega)
- Confirmar `admin/facturacion/page.tsx` y `stock/movimientos/page.tsx` completos (límites/paginación).
- Prueba empírica local del punto de fallo de `.in()` (sección 8) contra `next dev` local, sin producción.
- Over-fetch (sección 9): medir filas descargadas vs. mostradas en al menos Clientes, Productos, Stock.
- Count vs. detail (sección 11): revisar `product_stock_status`/stock crítico y el badge de Notificaciones.
- Waterfalls (sección 14): confirmar `Promise.all` real vs. awaits secuenciales en Dashboard, Nueva Venta, Comisiones, ficha de venta — primera lectura ya sugiere que `dashboard/page.tsx`, `ventas/page.tsx` y `dashboard/comisiones/[doctorId]/page.tsx` sí usan `Promise.all` correctamente (visto en código ya citado en trabajo previo de esta misma sesión) — se confirma formalmente con cita de línea en la próxima pasada, no se da por sentado.

---

*(Checkpoints 3-6 — PostgreSQL/índices/RLS/RPCs/concurrencia, Frontend/bundle/imágenes, Tests/fixtures/observabilidad/Supabase grants, e informe consolidado con roadmap — continúan en la próxima entrega de este mismo documento, dentro de esta misma rama.)*
