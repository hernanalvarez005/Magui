import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { AlertTriangle, Globe, Percent, Receipt, ShoppingBag, TrendingUp } from "lucide-react";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { DashboardFilters } from "@/components/dashboard/dashboard-filters";
import { BarList } from "@/components/dashboard/bar-list";
import { RevenueByDayChart } from "@/components/dashboard/revenue-by-day-chart";
import { formatCurrency, todayInBuenosAires } from "@/lib/utils";
import type { DashboardReport } from "@/types/database";

export const metadata: Metadata = { title: "Dashboard" };

export default async function DashboardPage(props: PageProps<"/dashboard">) {
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
    supabase.rpc("dashboard_report", {
      p_from: from,
      p_to: to,
      p_location_id: locationId,
      p_sales_channel_id: channelId,
    }),
  ]);

  const data = report as DashboardReport | null;

  return (
    <div className="flex flex-col gap-5 p-4 md:p-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">Dashboard</h1>
          <p className="text-sm text-muted-foreground">
            {from} — {to}
          </p>
        </div>
        <Button variant="outline" size="sm" asChild>
          <Link href="/dashboard/comisiones">
            <Percent /> Comisiones por doctora
          </Link>
        </Button>
      </div>

      <DashboardFilters locations={locations ?? []} channels={channels ?? []} />

      {error || !data ? (
        <p className="rounded-md bg-destructive/10 px-4 py-3 text-sm text-destructive">
          No pudimos cargar el reporte. {error?.message}
        </p>
      ) : (
        <>
          <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <Kpi icon={ShoppingBag} label="Ventas" value={String(data.kpis.sales_count)} />
            <Kpi icon={TrendingUp} label="Facturación" value={formatCurrency(data.kpis.revenue)} />
            <Kpi icon={Receipt} label="Ticket promedio" value={formatCurrency(data.kpis.avg_ticket)} />
            <Kpi icon={ShoppingBag} label="Unidades vendidas" value={String(data.kpis.units_sold)} />
            <Kpi icon={Globe} label="Ventas web" value={String(data.kpis.web_sales_count)} />
            <Kpi icon={Percent} label="Comisión generada" value={formatCurrency(data.kpis.commission_total)} />
            <Kpi
              icon={AlertTriangle}
              label="Stock crítico"
              value={String(data.critical_stock_count)}
              tone={data.critical_stock_count > 0 ? "warning" : undefined}
            />
          </div>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Facturación por día</CardTitle>
            </CardHeader>
            <CardContent>
              <RevenueByDayChart data={data.revenue_by_day} />
            </CardContent>
          </Card>

          <div className="grid gap-4 lg:grid-cols-2">
            <Card>
              <CardHeader>
                <CardTitle className="text-base">Ventas por sucursal</CardTitle>
              </CardHeader>
              <CardContent>
                <BarList
                  items={data.sales_by_location.map((r) => ({ label: r.location, value: r.revenue, sublabel: `${r.count} ventas` }))}
                />
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle className="text-base">Ventas por canal</CardTitle>
              </CardHeader>
              <CardContent>
                <BarList
                  items={data.sales_by_channel.map((r) => ({ label: r.channel, value: r.revenue, sublabel: `${r.count} ventas` }))}
                />
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle className="text-base">Facturación por medio de pago</CardTitle>
              </CardHeader>
              <CardContent>
                <BarList items={data.revenue_by_payment_method.map((r) => ({ label: r.payment_method, value: r.revenue }))} />
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle className="text-base">Top productos por unidades</CardTitle>
              </CardHeader>
              <CardContent>
                <BarList
                  items={data.top_products_by_units.map((r) => ({ label: r.product, value: r.units }))}
                  valueFormat="number"
                />
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle className="text-base">Top productos por facturación</CardTitle>
              </CardHeader>
              <CardContent>
                <BarList items={data.top_products_by_revenue.map((r) => ({ label: r.product, value: r.revenue }))} />
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle className="text-base">Comisiones por doctora</CardTitle>
              </CardHeader>
              <CardContent>
                <BarList
                  items={data.commission_by_doctor.map((r) => ({
                    label: r.doctor,
                    value: r.commission,
                    sublabel: `${r.sales_count} ventas`,
                  }))}
                />
              </CardContent>
            </Card>
          </div>
        </>
      )}
    </div>
  );
}

function Kpi({
  icon: Icon,
  label,
  value,
  tone,
}: {
  icon: React.ElementType;
  label: string;
  value: string;
  tone?: "warning";
}) {
  return (
    <Card>
      <CardContent className="flex items-center gap-3 p-4">
        <div className={`flex size-9 shrink-0 items-center justify-center rounded-full ${tone === "warning" ? "bg-warning/20" : "bg-primary/10"}`}>
          <Icon className={`size-4 ${tone === "warning" ? "text-warning-foreground" : "text-primary"}`} />
        </div>
        <div className="min-w-0">
          <p className="text-xs text-muted-foreground">{label}</p>
          <p className="truncate text-lg font-semibold">{value}</p>
        </div>
      </CardContent>
    </Card>
  );
}
