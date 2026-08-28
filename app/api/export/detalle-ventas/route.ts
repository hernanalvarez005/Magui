import type { NextRequest } from "next/server";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { csvResponse, toCsv } from "@/lib/csv";
import { formatDateTime } from "@/lib/utils";

export async function GET(request: NextRequest) {
  await getCurrentProfile();
  const supabase = await createClient();
  const params = request.nextUrl.searchParams;

  let salesQuery = supabase
    .from("sales")
    .select("id, sale_number, sold_at, location_id")
    .order("sold_at", { ascending: false })
    .limit(2000);

  const from = params.get("from");
  const to = params.get("to");
  const location = params.get("location");

  if (from) salesQuery = salesQuery.gte("sold_at", `${from}T00:00:00-03:00`);
  if (to) salesQuery = salesQuery.lte("sold_at", `${to}T23:59:59-03:00`);
  if (location) salesQuery = salesQuery.eq("location_id", location);

  const { data: sales, error } = await salesQuery;
  if (error) return new Response(error.message, { status: 400 });

  const saleIds = (sales ?? []).map((s) => s.id);
  const { data: items } = saleIds.length
    ? await supabase.from("sale_items").select("*").in("sale_id", saleIds)
    : { data: [] };

  const productIds = Array.from(new Set((items ?? []).map((i) => i.product_id)));
  const { data: products } = productIds.length
    ? await supabase.from("products").select("id, name, sku").in("id", productIds)
    : { data: [] as { id: string; name: string; sku: string }[] };
  const productMap = new Map((products ?? []).map((p) => [p.id, p]));
  const saleMap = new Map((sales ?? []).map((s) => [s.id, s]));

  const rows = (items ?? []).map((i) => {
    const sale = saleMap.get(i.sale_id);
    const product = productMap.get(i.product_id);
    return {
      sale_number: sale?.sale_number ?? "",
      sold_at: sale ? formatDateTime(sale.sold_at) : "",
      product: product?.name ?? "",
      sku: product?.sku ?? "",
      quantity: i.quantity,
      list_unit_price: i.list_unit_price,
      sale_unit_price: i.sale_unit_price,
      line_discount: i.line_discount,
      line_total: i.line_total,
      commissionable: i.commissionable ? "Sí" : "No",
    };
  });

  const csv = toCsv(rows, [
    { key: "sale_number", header: "Nº venta" },
    { key: "sold_at", header: "Fecha" },
    { key: "product", header: "Producto" },
    { key: "sku", header: "SKU" },
    { key: "quantity", header: "Cantidad" },
    { key: "list_unit_price", header: "Precio lista" },
    { key: "sale_unit_price", header: "Precio venta" },
    { key: "line_discount", header: "Descuento" },
    { key: "line_total", header: "Total línea" },
    { key: "commissionable", header: "Comisionable" },
  ]);

  return csvResponse("detalle-ventas.csv", csv);
}
