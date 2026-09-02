import type { Metadata } from "next";
import { AlertTriangle, Boxes, Download, Layers, PackageX } from "lucide-react";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { EmptyState } from "@/components/shared/empty-state";
import { AdjustStockDialog } from "@/components/inventory/adjust-stock-dialog";
import { SetStockDialog } from "@/components/inventory/set-stock-dialog";
import { TransferStockDialog } from "@/components/inventory/transfer-stock-dialog";
import { StockFilters } from "@/components/inventory/stock-filters";
import { StockTable } from "@/components/inventory/stock-table";
import { KitAvailabilityList } from "@/components/inventory/kit-availability-list";

export const metadata: Metadata = { title: "Stock" };

export default async function StockPage(props: PageProps<"/stock">) {
  const searchParams = await props.searchParams;
  const profile = await getCurrentProfile();
  const supabase = await createClient();

  const category = typeof searchParams.category === "string" ? searchParams.category : undefined;
  const rawStatus = typeof searchParams.status === "string" ? searchParams.status : undefined;
  const status = rawStatus === "ok" || rawStatus === "bajo" || rawStatus === "sin_stock" ? rawStatus : undefined;
  const q = typeof searchParams.q === "string" ? searchParams.q : undefined;
  const exportSearch: Record<string, string> = {
    ...(category ? { category } : {}),
    ...(status ? { status } : {}),
  };

  // IMPORTANTE: filtrar explícitamente por sedes accesibles acá, no confiar
  // solo en RLS. La vista hace CROSS JOIN con todas las sedes; en un LEFT JOIN
  // contra inventory_balances, RLS oculta la fila pero no la sede "fantasma"
  // del cross join, así que sin este filtro una vendedora vería stock 0 (falsa
  // alerta) de sedes a las que ni siquiera tiene acceso.
  const accessibleLocationIds =
    profile.locationIds.length > 0 ? profile.locationIds : ["00000000-0000-0000-0000-000000000000"];

  let stockQuery = supabase
    .from("product_stock_status")
    .select("product_id, sku, name, category, location_id, location_code, quantity, min_stock, status, product_active")
    .in("location_id", accessibleLocationIds);

  if (category) stockQuery = stockQuery.eq("category", category);
  // Filtrar explícitamente por un estado (Sin stock / Bajo mínimo) es
  // "modo alerta" — un producto inactivo nunca debe aparecer ahí (sección
  // 17 del pedido). Sin filtro de estado (listado general), Administración
  // sigue pudiendo consultar el stock remanente de productos inactivos
  // (sección 4) — StockTable los marca con un badge "Inactivo" aparte.
  if (status) stockQuery = stockQuery.eq("status", status).eq("product_active", true);
  if (q) stockQuery = stockQuery.ilike("name", `%${q}%`);

  // Las 6 consultas de acá son independientes entre sí (accessibleLocationIds
  // sale de profile.locationIds, no de ninguna de ellas) — todas en una sola
  // ronda en vez de etapas secuenciales.
  const [
    { data: locations },
    { data: categories },
    { data: stockRows },
    { data: kitRows },
    { data: products },
    { data: totalRows },
  ] = await Promise.all([
    supabase
      .from("stock_locations")
      .select("id, code, name")
      .in("id", accessibleLocationIds)
      .eq("active", true)
      .order("name"),
    supabase.from("products").select("category").eq("active", true).not("category", "is", null),
    stockQuery.order("name"),
    supabase
      .from("kit_availability")
      .select("kit_product_id, kit_sku, kit_name, location_id, location_code, buildable_qty")
      .in("location_id", accessibleLocationIds),
    supabase
      .from("products")
      .select("id, sku, name, track_stock")
      .eq("active", true)
      .eq("track_stock", true)
      .order("name"),
    // Stock total general: SIEMPRE sin los filtros de categoría/estado de la
    // tabla (si no, "Stock total" cambiaría según el filtro aplicado, dejando
    // de ser un total real) y SIN sumar disponibilidad de kits — la vista ya
    // excluye kits (track_stock = true únicamente), así que sumar "quantity"
    // acá nunca duplica físicamente inventario armado en kits.
    supabase.from("product_stock_status").select("quantity").in("location_id", accessibleLocationIds),
  ]);

  const distinctCategories = Array.from(new Set((categories ?? []).map((c) => c.category!))).sort();

  // KPI "Sin stock" / "Bajo mínimo": son alertas operativas, nunca cuentan
  // un producto inactivo (sección 17/18 del pedido) — el filtro ya lo
  // excluye cuando `status` está seteado, pero se repite acá para que el
  // número sea correcto incluso en el listado sin filtrar.
  const withoutStock = (stockRows ?? []).filter((r) => r.status === "sin_stock" && r.product_active).length;
  const lowStock = (stockRows ?? []).filter((r) => r.status === "bajo" && r.product_active).length;
  // "Stock total": representa inventario FÍSICO real del negocio (mismo
  // criterio que ya documentaba este KPI antes de este ajuste — nunca
  // sumaba disponibilidad de kits, siempre ignoraba los filtros de la
  // tabla) — se decide a propósito seguir incluyendo acá unidades físicas
  // de productos inactivos: son stock real que sigue en el depósito/sede
  // aunque ya no sea vendible, y Administración necesita poder verlo
  // reflejado en el total (sección 18 del pedido, documentado en vez de
  // cambiarlo en silencio).
  const totalStock = (totalRows ?? []).reduce((acc, r) => acc + Number(r.quantity), 0);

  const canManageStock = profile.role === "admin";
  const canAdjust = profile.role === "admin" || profile.canAdjustStock;

  return (
    <div className="flex flex-col gap-5 p-4 md:p-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">Stock</h1>
          <p className="text-sm text-muted-foreground">Saldo actual por sucursal.</p>
        </div>
        <div className="flex flex-wrap gap-2">
          {canManageStock ? (
            <Button variant="outline" asChild>
              <a href={`/api/export/inventario?${new URLSearchParams(exportSearch).toString()}`}>
                <Download /> Exportar CSV
              </a>
            </Button>
          ) : null}
          {canAdjust ? (
            <AdjustStockDialog
              locations={locations ?? []}
              products={products ?? []}
              defaultLocationId={locations?.[0]?.id}
            />
          ) : null}
          {/* Establecer stock final es EXCLUSIVO de admin — ni siquiera un
              seller con can_adjust_stock lo ve (distinto de AdjustStockDialog). */}
          {canManageStock ? (
            <SetStockDialog
              locations={locations ?? []}
              products={products ?? []}
              defaultLocationId={locations?.[0]?.id}
            />
          ) : null}
          {canManageStock ? <TransferStockDialog locations={locations ?? []} products={products ?? []} /> : null}
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Card>
          <CardContent className="flex items-center gap-3 p-4">
            <div className="flex size-9 items-center justify-center rounded-full bg-primary/10">
              <Layers className="size-4 text-primary" />
            </div>
            <div>
              <p className="text-xs text-muted-foreground">Stock total</p>
              <p className="text-lg font-semibold">{totalStock} unidades</p>
            </div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="flex items-center gap-3 p-4">
            <div className="flex size-9 items-center justify-center rounded-full bg-destructive/10">
              <PackageX className="size-4 text-destructive" />
            </div>
            <div>
              <p className="text-xs text-muted-foreground">Sin stock</p>
              <p className="text-lg font-semibold">{withoutStock}</p>
            </div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="flex items-center gap-3 p-4">
            <div className="flex size-9 items-center justify-center rounded-full bg-warning/20">
              <AlertTriangle className="size-4 text-warning-foreground" />
            </div>
            <div>
              <p className="text-xs text-muted-foreground">Bajo mínimo</p>
              <p className="text-lg font-semibold">{lowStock}</p>
            </div>
          </CardContent>
        </Card>
        <Card className="hidden sm:block">
          <CardContent className="flex items-center gap-3 p-4">
            <div className="flex size-9 items-center justify-center rounded-full bg-primary/10">
              <Boxes className="size-4 text-primary" />
            </div>
            <div>
              <p className="text-xs text-muted-foreground">Sucursales</p>
              <p className="text-lg font-semibold">{locations?.length ?? 0}</p>
            </div>
          </CardContent>
        </Card>
      </div>

      <StockFilters categories={distinctCategories} />

      {!stockRows || stockRows.length === 0 ? (
        <EmptyState title="No encontramos productos que coincidan con estos filtros." />
      ) : (
        <StockTable rows={stockRows} locations={locations ?? []} />
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Disponibilidad de kits</CardTitle>
        </CardHeader>
        <CardContent>
          <KitAvailabilityList rows={kitRows ?? []} locations={locations ?? []} />
        </CardContent>
      </Card>
    </div>
  );
}
