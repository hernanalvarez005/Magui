import type { Metadata } from "next";
import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { ArrowLeft } from "lucide-react";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { DashboardFilters } from "@/components/dashboard/dashboard-filters";
import { formatCurrency, formatDateTime, todayInBuenosAires } from "@/lib/utils";
import type { DoctorSalesDetail } from "@/types/database";

export const metadata: Metadata = { title: "Detalle por médica" };

export default async function DoctorSalesDetailPage(props: PageProps<"/dashboard/comisiones/[doctorId]">) {
  const { doctorId } = await props.params;
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

  const [{ data: locations }, { data: report, error }] = await Promise.all([
    supabase
      .from("stock_locations")
      .select("id, name")
      .in("id", profile.locationIds.length > 0 ? profile.locationIds : ["00000000-0000-0000-0000-000000000000"])
      .order("name"),
    supabase.rpc("doctor_sales_detail", {
      p_doctor_id: doctorId,
      p_from: from,
      p_to: to,
      p_location_id: locationId,
    }),
  ]);

  if (error?.message.includes("no existe")) notFound();

  const data = report as DoctorSalesDetail | null;
  const basePath = `/dashboard/comisiones/${doctorId}`;

  return (
    <div className="flex flex-col gap-5 p-4 md:p-6">
      <div>
        <Button variant="ghost" size="sm" asChild className="-ml-2">
          <Link href="/dashboard/comisiones">
            <ArrowLeft /> Comisiones por doctora
          </Link>
        </Button>
        <h1 className="text-xl font-semibold">{data?.doctor.full_name ?? "Detalle por médica"}</h1>
        <p className="text-sm text-muted-foreground">
          {from} — {to}. Usa la comisión ya registrada en cada venta, no el % actual de la doctora.
        </p>
      </div>

      <DashboardFilters locations={locations ?? []} channels={[]} basePath={basePath} />

      {error ? (
        <p className="rounded-md bg-destructive/10 px-4 py-3 text-sm text-destructive">
          No pudimos cargar el reporte. {error.message}
        </p>
      ) : !data ? null : (
        <>
          <div className="grid grid-cols-2 gap-3 lg:grid-cols-3">
            <Card>
              <CardContent className="p-4">
                <p className="text-xs text-muted-foreground">Ventas</p>
                <p className="text-lg font-semibold">{data.summary.sales_count}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="p-4">
                <p className="text-xs text-muted-foreground">Venta comisionable</p>
                <p className="text-lg font-semibold">{formatCurrency(data.summary.commissionable_revenue)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="p-4">
                <p className="text-xs text-muted-foreground">Comisión total</p>
                <p className="text-lg font-semibold">{formatCurrency(data.summary.commission_total)}</p>
              </CardContent>
            </Card>
          </div>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Productos vendidos</CardTitle>
            </CardHeader>
            <CardContent className="p-0">
              {data.products.length === 0 ? (
                <p className="px-5 pb-4 text-sm text-muted-foreground">Sin productos en este período.</p>
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Producto</TableHead>
                      <TableHead className="text-right">Unidades</TableHead>
                      <TableHead className="text-right">Facturación</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {data.products.map((p) => (
                      <TableRow key={p.product_id}>
                        <TableCell className="font-medium">{p.name}</TableCell>
                        <TableCell className="text-right">{p.units}</TableCell>
                        <TableCell className="text-right">{formatCurrency(p.revenue)}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Operaciones</CardTitle>
            </CardHeader>
            <CardContent className="p-0">
              {data.sales.length === 0 ? (
                <p className="px-5 pb-4 text-sm text-muted-foreground">Sin ventas en este período.</p>
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Venta</TableHead>
                      <TableHead>Sucursal</TableHead>
                      <TableHead className="text-right">Total</TableHead>
                      <TableHead className="text-right">Comisión</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {data.sales.map((s) => (
                      <TableRow key={s.id}>
                        <TableCell>
                          <Link href={`/ventas/${s.id}`} className="font-medium text-primary hover:underline">
                            {s.sale_number}
                          </Link>
                          <p className="text-xs text-muted-foreground">{formatDateTime(s.sold_at)}</p>
                        </TableCell>
                        <TableCell className="text-sm text-muted-foreground">{s.location}</TableCell>
                        <TableCell className="text-right">{formatCurrency(s.total)}</TableCell>
                        <TableCell className="text-right font-semibold">{formatCurrency(s.commission_total)}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}
