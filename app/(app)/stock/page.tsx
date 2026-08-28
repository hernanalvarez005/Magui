import type { Metadata } from "next";
import { AlertTriangle, Boxes, Download, PackageX } from "lucide-react";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { EmptyState } from "@/components/shared/empty-state";
import { AdjustStockDialog } from "@/components/inventory/adjust-stock-dialog";
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

  const [{ data: locations }, { data: categories }] = await Promise.all([
    supabase
      .from("stock_locations")
      .select("id, code, name")
      .in("id", profile.locationIds.length > 0 ? profile.locationIds : ["00000000-0000-0000-0000-000000000000"])
      .eq("active", true)
      .order("name"),
    supabase.from("products").select("category").eq("active", true).not("category", "is", null),
  ]);

  const distinctCategories = Array.from(new Set((categories ?? []).map((c) => c.category!))).sort();

  let stockQuery = supabase
    .from("product_stock_status")
    .select("product_id, sku, name, category, location_id, location_code, quantity, min_stock, status");

  if (category) stockQuery = stockQuery.eq("category", category);
  if (status) stockQuery = stockQuery.eq("status", status);
  if (q) stockQuery = stockQuery.ilike("name", `%${q}%`);

  const { data: stockRows } = await stockQuery.order("name");

  const { data: kitRows } = await supabase
    .from("kit_availability")
    .select("kit_product_id, kit_sku, kit_name, location_id, location_code, buildable_qty");

  const { data: products } = await supabase
    .from("products")
    .select("id, sku, name, track_stock")
    .eq("active", true)
    .eq("track_stock", true)
    .order("name");

  const withoutStock = (stockRows ?? []).filter((r) => r.status === "sin_stock").length;
  const lowStock = (stockRows ?? []).filter((r) => r.status === "bajo").length;

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
          {canManageStock ? <TransferStockDialog locations={locations ?? []} products={products ?? []} /> : null}
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
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
