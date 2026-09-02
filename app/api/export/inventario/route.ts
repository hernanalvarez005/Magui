import type { NextRequest } from "next/server";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { csvResponse, toCsv } from "@/lib/csv";

export async function GET(request: NextRequest) {
  const profile = await getCurrentProfile();
  const supabase = await createClient();
  const params = request.nextUrl.searchParams;

  let query = supabase
    .from("product_stock_status")
    .select("sku, name, category, location_code, quantity, min_stock, status")
    // Filtro explícito por sedes accesibles: la vista hace CROSS JOIN con
    // todas las sedes, y sin este filtro un LEFT JOIN + RLS deja "fantasmas"
    // en 0 para sedes a las que el usuario no tiene acceso.
    .in("location_id", profile.locationIds.length > 0 ? profile.locationIds : ["00000000-0000-0000-0000-000000000000"])
    .order("name");

  const category = params.get("category");
  const rawStatus = params.get("status");
  const status = rawStatus === "ok" || rawStatus === "bajo" || rawStatus === "sin_stock" ? rawStatus : null;

  if (category) query = query.eq("category", category);
  // Mismo criterio que /stock: filtrar por un estado puntual es "modo
  // alerta" y excluye productos inactivos (sección 17 del pedido) — el
  // listado general (sin status) sigue exportando todo, igual que la tabla.
  if (status) query = query.eq("status", status).eq("product_active", true);

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
