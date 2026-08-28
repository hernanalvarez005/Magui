import type { NextRequest } from "next/server";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { csvResponse, toCsv } from "@/lib/csv";
import type { DashboardReport } from "@/types/database";

export async function GET(request: NextRequest) {
  const profile = await getCurrentProfile();
  if (!(profile.role === "admin" || profile.canViewFinancialReports)) {
    return new Response("No autorizado.", { status: 403 });
  }

  const supabase = await createClient();
  const params = request.nextUrl.searchParams;
  const from = params.get("from") ?? new Date().toISOString().slice(0, 10);
  const to = params.get("to") ?? new Date().toISOString().slice(0, 10);
  const location = params.get("location");

  const { data: report, error } = await supabase.rpc("dashboard_report", {
    p_from: from,
    p_to: to,
    p_location_id: location,
  });
  if (error) return new Response(error.message, { status: 400 });

  const data = report as DashboardReport;
  const csv = toCsv(data.commission_by_doctor, [
    { key: "doctor", header: "Doctora" },
    { key: "sales_count", header: "Cantidad de ventas" },
    { key: "commissionable_revenue", header: "Venta comisionable" },
    { key: "commission", header: "Comisión total" },
  ]);

  return csvResponse("comisiones.csv", csv);
}
