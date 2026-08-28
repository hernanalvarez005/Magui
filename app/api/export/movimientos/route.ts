import type { NextRequest } from "next/server";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { csvResponse, toCsv } from "@/lib/csv";
import { formatDateTime } from "@/lib/utils";

export async function GET(request: NextRequest) {
  await getCurrentProfile();
  const supabase = await createClient();
  const params = request.nextUrl.searchParams;

  let query = supabase
    .from("stock_movements")
    .select("*")
    .order("occurred_at", { ascending: false })
    .limit(5000);

  const from = params.get("from");
  const to = params.get("to");
  const location = params.get("location");
  const product = params.get("product");
  const type = params.get("type");

  if (from) query = query.gte("occurred_at", `${from}T00:00:00-03:00`);
  if (to) query = query.lte("occurred_at", `${to}T23:59:59-03:00`);
  if (location) query = query.eq("location_id", location);
  if (product) query = query.eq("product_id", product);
  if (type) {
    query = query.eq(
      "movement_type",
      type as
        | "INITIAL"
        | "PURCHASE"
        | "SALE"
        | "SALE_CANCEL"
        | "ADJUSTMENT_PLUS"
        | "ADJUSTMENT_MINUS"
        | "TRANSFER_OUT"
        | "TRANSFER_IN"
        | "RETURN"
    );
  }

  const { data: movements, error } = await query;
  if (error) return new Response(error.message, { status: 400 });

  const productIds = Array.from(new Set((movements ?? []).map((m) => m.product_id)));
  const locationIds = Array.from(new Set((movements ?? []).map((m) => m.location_id)));
  const userIds = Array.from(
    new Set((movements ?? []).map((m) => m.created_by).filter((id): id is string => !!id))
  );

  const [{ data: products }, { data: locations }, { data: users }] = await Promise.all([
    productIds.length
      ? supabase.from("products").select("id, name, sku").in("id", productIds)
      : Promise.resolve({ data: [] as { id: string; name: string; sku: string }[] }),
    locationIds.length
      ? supabase.from("stock_locations").select("id, code").in("id", locationIds)
      : Promise.resolve({ data: [] as { id: string; code: string }[] }),
    userIds.length
      ? supabase.from("profiles").select("id, full_name").in("id", userIds)
      : Promise.resolve({ data: [] as { id: string; full_name: string }[] }),
  ]);

  const productMap = new Map((products ?? []).map((p) => [p.id, p]));
  const locationMap = new Map((locations ?? []).map((l) => [l.id, l]));
  const userMap = new Map((users ?? []).map((u) => [u.id, u]));

  const rows = (movements ?? []).map((m) => ({
    occurred_at: formatDateTime(m.occurred_at),
    product: productMap.get(m.product_id)?.name ?? "",
    sku: productMap.get(m.product_id)?.sku ?? "",
    location: locationMap.get(m.location_id)?.code ?? "",
    movement_type: m.movement_type,
    quantity_delta: m.quantity_delta,
    user: m.created_by ? userMap.get(m.created_by)?.full_name ?? "" : "Sistema",
    reference: m.reference ?? "",
    reason: m.reason ?? "",
  }));

  const csv = toCsv(rows, [
    { key: "occurred_at", header: "Fecha" },
    { key: "product", header: "Producto" },
    { key: "sku", header: "SKU" },
    { key: "location", header: "Sucursal" },
    { key: "movement_type", header: "Tipo" },
    { key: "quantity_delta", header: "Cantidad" },
    { key: "user", header: "Usuario" },
    { key: "reference", header: "Referencia" },
    { key: "reason", header: "Motivo" },
  ]);

  return csvResponse("movimientos.csv", csv);
}
