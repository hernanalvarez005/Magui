import type { NextRequest } from "next/server";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { csvResponse, toCsv } from "@/lib/csv";

export async function GET(request: NextRequest) {
  await getCurrentProfile();
  const supabase = await createClient();
  const params = request.nextUrl.searchParams;

  let query = supabase
    .from("product_stock_status")
    .select("sku, name, category, location_code, quantity, min_stock, status")
    .order("name");

  const category = params.get("category");
  const rawStatus = params.get("status");
  const status = rawStatus === "ok" || rawStatus === "bajo" || rawStatus === "sin_stock" ? rawStatus : null;

  if (category) query = query.eq("category", category);
  if (status) query = query.eq("status", status);

  const { data: rows, error } = await query;
  if (error) return new Response(error.message, { status: 400 });

  const csv = toCsv(rows ?? [], [
    { key: "sku", header: "SKU" },
    { key: "name", header: "Producto" },
    { key: "category", header: "Categoría" },
    { key: "location_code", header: "Sucursal" },
    { key: "quantity", header: "Stock" },
    { key: "min_stock", header: "Mínimo" },
    { key: "status", header: "Estado" },
  ]);

  return csvResponse("inventario.csv", csv);
}
