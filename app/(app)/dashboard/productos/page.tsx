import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { Download } from "lucide-react";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { EmptyState } from "@/components/shared/empty-state";
import { DashboardFilters } from "@/components/dashboard/dashboard-filters";
import { formatCurrency, todayInBuenosAires } from "@/lib/utils";
import type { ProductRevenueReport } from "@/types/database";

export const metadata: Metadata = { title: "Facturación por producto" };

export default async function ProductRevenuePage(props: PageProps<"/dashboard/productos">) {
  const searchParams = await props.searchParams;
  const profile = await getCurrentProfile();

  if (!(profile.role === "admin" || profile.canViewFinancialReports)) {
    redirect("/");
  }

  const supabase = await createClient();

  const to = typeof searchParams.to === "string" ? searchParams.to : todayInBuenosAires();
  const from =
    typeof searchParams.from === "string"
      ? searchParams.from
      : (() => {
          const d = new Date();
          d.setDate(d.getDate() - 29);
          return d.toISOString().slice(0, 10);
        })();
  const locationId = typeof searchParams.location === "string" ? searchParams.location : null;
  const channelId = typeof searchParams.channel === "string" ? searchParams.channel : null;

  const [{ data: locations }, { data: channels }, { data: report, error }] = await Promise.all([
    supabase
      .from("stock_locations")
      .select("id, name")
      .in("id", profile.locationIds.length > 0 ? profile.locationIds : ["00000000-0000-0000-0000-000000000000"])
      .order("name"),
    supabase.from("sales_channels").select("id, name").order("sort_order"),
    supabase.rpc("product_revenue_report", {
      p_from: from,
      p_to: to,
      p_location_id: locationId,
      p_sales_channel_id: channelId,
    }),
  ]);

  const rows = (report as ProductRevenueReport | null)?.rows ?? [];

  const exportParams = new URLSearchParams({ from, to });
  if (locationId) exportParams.set("location", locationId);
  if (channelId) exportParams.set("channel", channelId);

  return (
    <div className="flex flex-col gap-5 p-4 md:p-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">Facturación por producto</h1>
          <p className="text-sm text-muted-foreground">
            {from} — {to}. Un kit factura como sí mismo, no repartido entre sus componentes.
          </p>
        </div>
        {error ? null : (
          <Button variant="outline" size="sm" asChild>
            <a href={`/api/export/facturacion-productos?${exportParams.toString()}`}>
              <Download /> Exportar CSV
            </a>
          </Button>
        )}
      </div>

      <DashboardFilters locations={locations ?? []} channels={channels ?? []} basePath="/dashboard/productos" />

      {error ? (
        <p className="rounded-md bg-destructive/10 px-4 py-3 text-sm text-destructive">
          No pudimos cargar el reporte. {error.message}
        </p>
      ) : rows.length === 0 ? (
        <EmptyState title="No hay ventas en este período." />
      ) : (
        <Card>
          <CardContent className="p-0">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Producto</TableHead>
                  <TableHead className="text-right">Unidades</TableHead>
                  <TableHead className="text-right">Descuentos</TableHead>
                  <TableHead className="text-right">Facturación</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((r) => (
                  <TableRow key={r.product_id}>
                    <TableCell>
                      <div className="flex items-center gap-2">
                        {r.product_type === "kit" ? <Badge variant="secondary">Kit</Badge> : null}
                        <span className="font-medium">{r.name}</span>
                      </div>
                      <p className="text-xs text-muted-foreground">{r.sku}</p>
                    </TableCell>
                    <TableCell className="text-right">{r.units}</TableCell>
                    <TableCell className="text-right text-muted-foreground">
                      {formatCurrency(r.discount_total)}
                    </TableCell>
                    <TableCell className="text-right font-semibold">{formatCurrency(r.revenue)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
