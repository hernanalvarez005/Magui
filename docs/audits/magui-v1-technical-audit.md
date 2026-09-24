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

### Cierre de Checkpoint 2 (confirmaciones pendientes, ahora resueltas)

**`app/(app)/admin/facturacion/page.tsx:1-60`** — confirmado leyendo el archivo completo: usa el mismo patrón real de paginación que `/ventas` (`.range()` + `count:"exact"`, `PAGE_SIZE=30`). Los `.in()` posteriores (`customerIds`/`accountIds`) quedan acotados por esa misma página de ≤30 filas — no hay riesgo de `.in()` grande acá.
— **Clasificación: VALIDADO — NO TOCAR.**

**`app/(app)/stock/movimientos/page.tsx:1-70`** — confirmado leyendo el archivo completo: también usa `.range()` + `count:"exact"` real (`PAGE_SIZE=50`), y el resto de queries de la página usan `Promise.all` correctamente (comentario propio del archivo explica por qué son independientes).
— **Clasificación: VALIDADO — NO TOCAR.**
— **Hallazgo secundario de over-fetch, mismo archivo, línea 67:** `supabase.from("products").select("id, sku, name").order("name")` para poblar un `<select>` de filtro, sin `.limit()`. Con 30 productos reales hoy esto es intrascendente; es el mismo patrón repetido en al menos 4 lugares del código (cualquier dropdown "elegí un producto"). No hay corrupción de datos posible (es de solo lectura, para un filtro), simplemente trae más filas de las necesarias para pintar un `<select>`.
— **Clasificación: VIGILANCIA.** Punto de cruce aproximado: catálogo de productos activos superando ~500-1000 filas (haría el dropdown pesado en el cliente, antes de convertirse en un problema de PostgREST — el cap de 1000 filas de PostgREST recién truncaría el dropdown mismo a partir de ese volumen, silenciosamente).

**Sección 8 — `.in()` grandes: prueba empírica local ejecutada, clasificación cerrada.**
Se construyó un script Node (`fetch()`, no `curl` — `curl` con querystrings de ~185.000 caracteres falla antes por el límite `ARG_MAX` de la shell, lo cual es un artefacto del método de prueba, no un hallazgo real) que ataca `next dev` local (puerto de desarrollo, sin autenticación real necesaria para medir el límite HTTP en sí) con querystrings de tamaño creciente.
— **Resultado medido (MEDIDO, no inferido):** el servidor de desarrollo Next.js/Node devuelve **HTTP 431 (Request Header Fields Too Large)** para querystrings de entre **~16.000 y ~20.000 caracteres**.
— Los tamaños reales que generarían los tres export routes en el peor caso documentado en la sección 8 (~74.000 caracteres para `detalle-ventas` con 2000 ids; ~185.000 para `ventas`/`movimientos` con 5000 ids) están **muy por encima** de ese umbral medido localmente.
— **Matiz metodológico honesto:** este 431 es del servidor Node/Next.js local, no necesariamente idéntico al comportamiento de la infraestructura real de producción (Vercel + su propio proxy/edge, con límites que pueden diferir). No se pudo medir directamente contra producción (prohibido por la regla de solo lectura + no hay sesión autenticada real disponible en este entorno). Aun así, esto es evidencia **fuerte y concreta** — no solo el cálculo de bytes — de que un `.in()` de ese tamaño falla con una U alta probabilidad en cualquier infraestructura HTTP estándar (navegadores, proxies, y el propio runtime de Node que corre en Vercel), mucho antes de llegar a Postgres.
— **Clasificación final: IMPLEMENTAR.** El fix candidato (no implementado) es el mismo ya identificado: reemplazar "traer ids del cliente y volver a preguntar con `.in()`" por una RPC agregadora del lado del servidor que reciba el rango de fechas/filtros directamente (mismo patrón que ya usan `dashboard_report`/`doctor_sales_detail`, que no sufren este problema por construcción), o paginar el `.in()` en lotes controlados (ej. de a 200-300 ids) si una RPC no es viable a corto plazo.

### Waterfall demostrado — `app/(app)/ventas/[id]/page.tsx`

Lectura completa del archivo (líneas 1-100). Encadenamiento real de datos (no solo apariencia de secuencialidad):

1. `sale` (línea 15) — necesariamente primero, todo lo demás depende de `sale.location_id`/`sale.id`/etc.
2. `Promise.all` de 13 queries (líneas 18-64) — correctamente paralelas, todas dependen solo de `sale`. **Bien implementado.**
3. `products` (líneas 67-68) — necesariamente secuencial, depende de `items` (resultado del paso 2).
4. `returns` (líneas 76-80) — depende **solo** de `id` (conocido desde la línea 11, antes incluso del paso 1) — **podría haberse incluido en el `Promise.all` del paso 2**, no depende de nada de ese paso.
5. `returnItems` (líneas 82-84) — depende de `returnIds` (resultado del paso 4). Necesariamente después de `returns`.
6. `returnAccounts` (líneas 92-94) — depende solo de `returns` (paso 4), **no** de `returnItems` (paso 5).
7. `returnCreators` (líneas 97-98) — depende solo de `returns` (paso 4), **no** de `returnItems` (paso 5) ni de `returnAccounts` (paso 6).

Los pasos 5, 6 y 7 dependen todos **únicamente** del resultado del paso 4 y no entre sí — hoy se ejecutan en 3 round-trips secuenciales cuando podrían combinarse en un único `Promise.all`.
— **Antes (medido por dependencia real, no por timing):** 4 etapas secuenciales necesarias para la porción de "devoluciones" de la página (4 → 5 → 6 → 7).
— **Después (candidato, no implementado):** 2 etapas — (4) `returns`, luego `Promise.all([returnItems, returnAccounts, returnCreators])`. El paso 4 también podría fusionarse al `Promise.all` grande del paso 2 ya que solo depende de `id`, dejando potencialmente solo 3 etapas totales en toda la página en vez de 4-5.
— **Clasificación: IMPLEMENTAR.** Impacto proporcional a la latencia de red por round-trip (no medido contra producción); esfuerzo estimado S (reordenar/fusionar `Promise.all` existentes, sin cambiar ninguna query).

### Count-vs-detail — `web_pending_pickups`

`supabase/migrations/20260201000059_web_pending_pickups.sql`: la función es un RPC `SETOF` (`returns table(...)`), a diferencia de `dashboard_report`/`doctor_sales_detail` que devuelven `jsonb` escalar — por lo tanto **sí** está sujeta al cap de PostgREST (a diferencia de esas otras dos). El propio comentario de la migración documenta que es una fuente única deliberada, reusada tanto para el contador del badge de navegación como para el listado completo de Notificaciones. El dominio (retiros pendientes de pedidos Web) es operacionalmente chico por naturaleza — no hay mecanismo en el sistema que pueda acumular miles de retiros pendientes sin que alguien lo note mucho antes.
— **Clasificación: VALIDADO — NO TOCAR.**

---

## Checkpoint 3 — Base de datos (PostgreSQL/Supabase)

### Metodología y entorno

Todo lo que sigue se midió en una base Postgres local nueva, `magui_audit`, creada específicamente para este checkpoint y **distinta** de `magui_test` (usada por la suite pgTAP, para no interferir con ella). Se construyó aplicando el stub de `auth`/`storage` (`/tmp/preamble.sql`, ya usado en bloques anteriores de este mismo trabajo) y luego **las 83 migraciones reales de `supabase/migrations/` en orden**, sin ninguna modificación — es decir, el mismo esquema, funciones, vistas, políticas RLS e índices que existen hoy en `main`. Ninguna operación de este checkpoint tocó producción ni `magui_test`.

**Dataset sintético (sección 27 del pedido).** Se generó con un script propio (`supabase/tests/database/` no — vive fuera del repo, en el scratchpad de la sesión, no se commitea por no ser código de producto) parametrizado por `:scale`. El escenario base (`:scale=1`) es una **ASUNCIÓN documentada**, no un dato real de producción (no hay acceso a volumen real): ~18 meses de operación, 2 sedes + Web, ~15 ventas/día combinadas → 8.000 ventas, 1.500 clientes. Se corrió en 1x/10x/50x/100x:

| Escala | Clientes | Ventas | `sale_items` | `stock_movements` | Tiempo de carga |
|---|---|---|---|---|---|
| 1x (base, ASUNCIÓN) | 1.500 | 8.000 | ~16.000 | ~16.000 | pocos segundos |
| 10x | 15.000 | 80.000 | ~160.000 | ~160.000 | ~9s |
| 50x | 75.000 | 400.000 | ~800.000 | ~800.000 | ~55s |
| 100x | 150.000 | 800.000 | ~1.600.000 | ~1.600.000 | ~1m57s |

Simplificación deliberada y **declarada**: el dataset inserta ventas/items/movimientos ya "resueltos" con montos plausibles, sin pasar por `fn_create_sale_core`/`fn_pricing_quote` (sería demasiado lento para el volumen objetivo y no es necesario para medir performance de *lectura*). Esto sirve exclusivamente para medir lectura a escala (reportes, listados, `EXPLAIN`) — la corrección de la lógica de creación de ventas ya está cubierta aparte por pgTAP con datos mínimos y resultado exacto conocido. Los datos sembrados por las migraciones reales (`product_prices`: 106 filas, `app_settings`: 1 fila) se preservaron intactos en las 4 corridas — verificado explícitamente en cada una.

**Nota de proceso:** la primera versión del generador tenía tres bugs reales, encontrados y corregidos durante este mismo checkpoint (no relevantes para el producto, solo para la metodología de esta auditoría): (1) referencia a una columna `profiles.email` inexistente; (2) un `truncate ... cascade` sobre `profiles` que se llevaba puesto `product_prices`/`app_settings`/`promotions` por FKs no documentadas antes de este audit (`created_by`/`updated_by` con `NO ACTION`, no `CASCADE`) — obligó a reconstruir `magui_audit` desde cero una vez; (3) `session_replication_role = replica` desactivaba también el trigger `trg_on_auth_user_created` y las verificaciones de FK (comportamiento real de Postgres, no un bug de Supabase), generando filas huérfanas — se corrigió acotando el alcance de `replica` solo al bulk-insert de ventas/items/movimientos, después de crear los perfiles sintéticos con los triggers activos.

### Hallazgo principal — `dashboard_report` degrada linealmente pero con un factor constante alto

**Medido con `EXPLAIN (ANALYZE, BUFFERS)` real, simulando una sesión admin autenticada localmente** (vía `set_config('request.jwt.claim.sub', ...)`, técnica exclusiva de este entorno de prueba local — no aplicable ni usada contra producción):

| Escala | Ventas en rango (700 días, sin filtro) | Tiempo de ejecución |
|---|---|---|
| 1x | 8.000 | **983 ms** |
| 10x | 80.000 | **10.670 ms (~10.7s)** |
| 100x | 800.000 | **88.222 ms (~88.2s)**, 52.644.023 buffer hits |

Escala prácticamente lineal (10x datos → ~10.8x tiempo; 10x→100x datos → ~8.3x tiempo) — **no es un problema cuadrático ni un missing index** (los planes de `EXPLAIN` de las queries internas usan `Index Scan`, no `Seq Scan`, donde corresponde — ver más abajo). Es un problema de **forma de la consulta**: `dashboard_report` (función `plpgsql`, `supabase/migrations` — ver `pg_get_functiondef`) arma su respuesta con **8 subconsultas independientes** (`kpis`, `revenue_by_day`, `sales_by_location`, `sales_by_channel`, `revenue_by_payment_method`, `top_products_by_units`, `top_products_by_revenue`, `commission_by_doctor`), cada una:
- Vuelve a escanear `sales` con el **mismo filtro** de rango/estado/sede/canal (6 de las 8 lo hacen de forma independiente, sin compartir el resultado entre sí).
- 6 de esas 8 hacen además un `JOIN LATERAL` contra la vista `sale_item_net` **por cada fila de `sales`** — y `sale_item_net` es en sí misma una vista con su propio `LEFT JOIN LATERAL` (contra `sale_return_items`, para descontar devoluciones) **por cada fila de `sale_items`**. Es decir: hay un patrón de subconsulta correlacionada anidado dos niveles, repetido 6-8 veces sobre el mismo conjunto de datos en una sola llamada a la función.
- `has_location_access(s.location_id)` (función `SQL STABLE SECURITY DEFINER` con un `EXISTS` contra `profile_locations`/`profiles`) se evalúa también por cada fila de `sales`, en cada una de las 8 subconsultas — invariante dentro de una misma llamada (mismo usuario, mismo `p_location_id`) pero no cacheado.

Con 800.000 ventas en el rango pedido, esto significa evaluar ese patrón anidado del orden de millones de veces dentro de una sola invocación — consistente con los 52,6 millones de buffer hits medidos.

**A qué escala esto ya es un problema real:** incluso al escenario base asumido (8.000 ventas, ~983ms), un Dashboard que un usuario abre repetidamente varias veces por día ya se siente lento (no hay evidencia de que 8.000 ventas sea realista hoy para Magui — es una asunción documentada, no un dato medido de producción real). A 10x (80.000 ventas — un crecimiento de escala plausible en pocos años), 10.7 segundos por carga de Dashboard **ya supera los timeouts default habituales de funciones serverless** (ej. 10s en muchos planes de Vercel) — esto es un riesgo de **caída dura** (error 504/timeout), no solo de percepción de lentitud, y no requiere llegar a 100x para materializarse.
— **Clasificación: IMPLEMENTAR — severidad ALTA.** No se identificó ningún índice faltante (todos los planes internos usan índices existentes correctamente); el problema es puramente de **forma de consulta**. Candidatos de rediseño (no implementados, solo documentados para el roadmap): (a) calcular los agregados de `sale_item_net` por venta **una sola vez** en una CTE/tabla temporal dentro de la función y reusarla en las 8 subconsultas, en vez de repetir el `JOIN LATERAL` 6 veces; (b) evaluar `has_location_access` una sola vez fuera del loop de filas (ej. precalculando el set de `location_id` permitidos como un array/tabla temporal, no una función por fila); (c) evaluar si todas las secciones del dashboard necesitan recalcularse en cada carga o si alguna puede diferirse/cachear a nivel de aplicación. Esto requiere diseño y prueba de regresión cuidadosa (la función tiene lógica financiera real) — no se toca en esta fase de auditoría.
— **Evidencia:** `pg_get_functiondef('public.dashboard_report(...)')` (definición completa citada arriba), `EXPLAIN (ANALYZE, BUFFERS)` a 3 escalas (medido, no inferido) contra `magui_audit` local.

### `doctor_sales_detail` y `product_revenue_report` — misma familia, medidos a 100x

| Función | Escala | Tiempo medido | Nº de `JOIN LATERAL` a `sale_item_net` en el código |
|---|---|---|---|
| `doctor_sales_detail` (1 doctora, rango completo) | 100x (800.000 ventas totales) | **7.690 ms (~7.7s)** | 4 |
| `product_revenue_report` (rango completo, sin filtro) | 100x | **11.409 ms (~11.4s)** | 1 |

`doctor_sales_detail` filtra a una sola doctora (por eso es más rápida que `dashboard_report` pese a escanear la misma tabla base), pero repite el mismo patrón de `JOIN LATERAL` contra `sale_item_net` 4 veces dentro de la función — mismo tipo de causa raíz. `product_revenue_report` solo lo hace una vez, por eso es la más liviana de las tres pese a no tener ningún filtro de sede/canal en esta prueba — pero sigue sin paginar ni acotar el rango internamente, por lo que a mayor escala seguiría creciendo linealmente.
— **Clasificación: IMPLEMENTAR** para ambas, mismo candidato de rediseño que `dashboard_report` (CTE única reusada en vez de `JOIN LATERAL` repetido), prioridad más baja que `dashboard_report` por ser de uso menos frecuente (reportes puntuales, no una pantalla que se abre constantemente) y por afectar a un único doctor/rango a la vez en el caso de `doctor_sales_detail`.

### Paginación real — confirmado a escala con `EXPLAIN`

| Query | Escala | Plan | Tiempo |
|---|---|---|---|
| `/ventas` listado, página 1 (`.range(0,29)` equivalente, `order by sold_at desc`) | 100x (800.000 filas) | `Index Scan using sales_sold_at_idx`, `Limit` | **0.18 ms** |
| `/ventas` listado, página ~100 (`offset 2970`) | 100x | mismo índice, sigue siendo `Index Scan` (no `Seq Scan`) | **10.1 ms** |
| `count(*) exact` sobre `sales` (equivalente a `count:"exact"` de PostgREST) | 100x | `Parallel Index Only Scan` sobre `sales_status_idx`, 2 workers | **53.6 ms** |
| `.in()` de `sale_items` por 2.000 `sale_id` (simulando el peor caso de `detalle-ventas`) | 100x | `HashAggregate` + `Nested Loop` usando `sale_items_sale_id_idx` | **17.4 ms** |

Todo esto confirma, con datos reales a 800.000 ventas, lo que Checkpoint 2 ya había clasificado por lectura de código: la paginación real (`/ventas`, `/admin/facturacion`, `/stock/movimientos`) es rápida y correcta a esta escala — **VALIDADO — NO TOCAR**. También confirma que el problema de `.in()` grande de la sección 8 **no es de costo en la base de datos** (17ms es trivial) sino puramente de tamaño de URL/HTTP, tal como se había medido de forma independiente con el test empírico de 431 — ambas mediciones son consistentes entre sí y se refuerzan mutuamente.

La paginación por `OFFSET` en sí (usada por `/ventas`, `/admin/facturacion`, `/stock/movimientos`) degrada linealmente con la profundidad de la página (Postgres debe recorrer y descartar todas las filas anteriores al offset) — a offset 2970 ya cuesta 10ms; **no medido** a offsets mucho más profundos (ej. página 10.000) porque ningún flujo real de Magui pagina tan profundo hoy (no hay UI que permita saltar a una página arbitraria lejana, solo "siguiente/anterior").
— **Clasificación: VIGILANCIA.** Sin punto de cruce crítico identificado dentro de los rangos de uso real observables en el código actual.

### Índices — no se identificaron candidatos faltantes

Los 8+ planes de `EXPLAIN` corridos en este checkpoint (dashboard, doctor detail, product revenue, listados paginados, count, `.in()`) usan consistentemente `Index Scan`/`Index Only Scan`/`Parallel Index Only Scan` sobre índices que ya existen en las migraciones reales (`sales_sold_at_idx`, `sales_location_sold_at_idx`, `sales_status_idx`, `sale_items_sale_id_idx`, `sale_return_items_sale_item_id_idx`, entre otros ya confirmados vía `\d sales`/`\d sale_return_items`). En ningún caso apareció un `Seq Scan` sobre una tabla grande como consecuencia de un índice faltante.
— **Clasificación: VALIDADO — NO TOCAR.** El cuello de botella real de este checkpoint (`dashboard_report`/`doctor_sales_detail`/`product_revenue_report`) es de **forma de consulta** (subconsultas correlacionadas repetidas), no de indexación — agregar índices no lo resolvería.

### RLS y funciones helper — auditoría de forma, no de debilitamiento

`has_location_access(uuid)` (`SQL STABLE SECURITY DEFINER`) hace un `EXISTS` con join `profile_locations`/`profiles` filtrado por `auth.uid()` — correcto y seguro en su lógica; el único hallazgo es de performance (se evalúa por fila dentro de `dashboard_report`, ya documentado arriba), no de seguridad. No se propone ni se evaluó ningún debilitamiento de RLS en ningún punto de este checkpoint, conforme a la restricción explícita del pedido.

### RPCs críticas — atomicidad y concurrencia (auditoría dirigida, evidencia real)

Se leyó el código fuente completo (`pg_get_functiondef`) de las funciones de escritura más sensibles a condiciones de carrera:

**`fn_next_sale_number(location_id, sold_at)`** — genera el número de venta legible (`MJ-SED25-20260201-0001`). Usa:
```sql
insert into public.sale_number_counters (location_id, day, last_seq)
values (p_location_id, v_day, 1)
on conflict (location_id, day) do update set last_seq = last_seq + 1
returning last_seq into v_seq;
```
Este es el patrón atómico correcto (`INSERT ... ON CONFLICT DO UPDATE ... RETURNING` es una única sentencia, Postgres la ejecuta con el lock de fila implícito del `UPDATE`) — **no hay condición de carrera posible** aquí, dos ventas simultáneas en la misma sede/día no pueden recibir el mismo número.
— **Clasificación: VALIDADO — NO TOCAR.**

**`fn_check_available_stock` / `fn_apply_stock_movement`** (usadas por `fn_create_sale_core` para descontar stock) — ambas hacen:
```sql
select quantity into v_current from public.inventory_balances
where location_id = ... and product_id = ... for update;
```
`SELECT ... FOR UPDATE` es un lock pesimista de fila explícito sobre el saldo de inventario **antes** de leer la cantidad y decidir si hay stock suficiente — el patrón correcto para evitar sobreventa bajo ventas concurrentes del mismo producto/sede (dos vendedoras cargando la última unidad del mismo producto al mismo tiempo: la segunda transacción espera el lock de la primera y ve el saldo ya actualizado, no el saldo obsoleto).
— **Clasificación: VALIDADO — NO TOCAR.** Este es un hallazgo real y directamente contrario a lo que podría suponerse sin leer el código (que un contador de stock derivado de `stock_movements` podría no tener protección) — el diseño real usa una tabla de saldos materializada (`inventory_balances`) con lock de fila explícito, no un simple `SUM()` sobre movimientos en el momento de la venta.

**Concurrencia — análisis conceptual (no probado bajo carga real):** los dos mecanismos anteriores cubren los dos riesgos de carrera más evidentes del dominio (numeración de venta, sobreventa de stock). No se identificó, por lectura de código, un tercer punto de riesgo de igual severidad en `fn_create_sale_core`/`create_sale_exchange`/`create_sale_return` (todas ejecutan dentro de una única transacción implícita de Postgres por invocación de función — no hay transacciones autónomas ni commits parciales). **No se realizó una prueba de concurrencia real (2 conexiones simultáneas) en este pase** por acotar el alcance a lo que la evidencia de código ya deja bien fundamentado — queda como **NO MEDIDO** (no como IMPLEMENTAR ni VALIDADO) si se quiere cerrar con evidencia de prueba real en vez de solo lectura de código, y puede ejecutarse en un pase posterior, siempre contra `magui_audit` local, nunca contra producción.

---

*(Checkpoints 4-6 — Frontend/bundle/imágenes/mobile, Tests/fixtures/observabilidad/Supabase grants, e informe consolidado con priorización y roadmap — continúan en la próxima entrega de este mismo documento, dentro de esta misma rama.)*
