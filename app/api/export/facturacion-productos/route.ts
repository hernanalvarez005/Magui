import type { NextRequest } from "next/server";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { csvResponse, toCsv } from "@/lib/csv";
import type { ProductRevenueReport } from "@/types/database";

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
  const channel = params.get("channel");

  const { data: report, error } = await supabase.rpc("product_revenue_report", {
    p_from: from,
    p_to: to,
    p_location_id: location,
    p_sales_channel_id: channel,
  });
  if (error) return new Response(error.message, { status: 400 });

  const data = report as ProductRevenueReport;
  const csv = toCsv(
    data.rows.map((r) => ({ ...r, product_type: r.product_type === "kit" ? "Kit" : "Producto" })),
    [
      { key: "sku", header: "SKU" },
      { key: "name", header: "Nombre" },
      { key: "product_type", header: "Tipo" },
      { key: "units", header: "Unidades" },
      { key: "discount_total", header: "Descuentos" },
      { key: "revenue", header: "Facturación" },
    ]
  );

  return csvResponse("facturacion-productos.csv", csv);
}
