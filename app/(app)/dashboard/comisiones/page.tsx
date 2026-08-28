import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { Download } from "lucide-react";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { EmptyState } from "@/components/shared/empty-state";
import { DashboardFilters } from "@/components/dashboard/dashboard-filters";
import { formatCurrency } from "@/lib/utils";
import type { DashboardReport } from "@/types/database";

export const metadata: Metadata = { title: "Comisiones por doctora" };

export default async function CommissionsReportPage(props: PageProps<"/dashboard/comisiones">) {
  const searchParams = await props.searchParams;
  const profile = await getCurrentProfile();

  if (!(profile.role === "admin" || profile.canViewFinancialReports)) {
    redirect("/");
  }

  const supabase = await createClient();

  const to = typeof searchParams.to === "string" ? searchParams.to : new Date().toISOString().slice(0, 10);
  const from =
    typeof searchParams.from === "string"
      ? searchParams.from
      : (() => {
          const d = new Date();
          d.setDate(d.getDate() - 29);
          return d.toISOString().slice(0, 10);
        })();
  const locationId = typeof searchParams.location === "string" ? searchParams.location : null;

  const [{ data: locations }, { data: report }] = await Promise.all([
    supabase.from("stock_locations").select("id, name").order("name"),
    supabase.rpc("dashboard_report", { p_from: from, p_to: to, p_location_id: locationId }),
  ]);

  const data = report as DashboardReport | null;
  const rows = data?.commission_by_doctor ?? [];

  const exportParams = new URLSearchParams({ from, to, ...(locationId ? { location: locationId } : {}) });

  return (
    <div className="flex flex-col gap-5 p-4 md:p-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">Comisiones por doctora</h1>
          <p className="text-sm text-muted-foreground">
            {from} — {to}
          </p>
        </div>
        <Button variant="outline" asChild>
          <a href={`/api/export/comisiones?${exportParams.toString()}`}>
            <Download /> Exportar CSV
          </a>
        </Button>
      </div>

      <DashboardFilters locations={locations ?? []} channels={[]} basePath="/dashboard/comisiones" />

      {rows.length === 0 ? (
        <EmptyState title="No hay comisiones en este período." />
      ) : (
        <Card>
          <CardContent className="p-0">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Doctora</TableHead>
                  <TableHead className="text-right">Cantidad de ventas</TableHead>
                  <TableHead className="text-right">Venta comisionable</TableHead>
                  <TableHead className="text-right">Comisión total</TableHead>
                  <TableHead />
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((r) => (
                  <TableRow key={r.doctor_id ?? r.doctor}>
                    <TableCell className="font-medium">{r.doctor}</TableCell>
                    <TableCell className="text-right">{r.sales_count}</TableCell>
                    <TableCell className="text-right">{formatCurrency(r.commissionable_revenue)}</TableCell>
                    <TableCell className="text-right font-semibold">{formatCurrency(r.commission)}</TableCell>
                    <TableCell className="text-right">
                      {r.doctor_id ? (
                        <Button variant="ghost" size="sm" asChild>
                          <Link href={`/dashboard/comisiones/${r.doctor_id}?${exportParams.toString()}`}>Ver detalle</Link>
                        </Button>
                      ) : null}
                    </TableCell>
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
