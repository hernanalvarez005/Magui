import type { NextRequest } from "next/server";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { buildVentasWorkbook, groupProductsBySale, xlsxResponse, type VentaExportRow } from "@/lib/xlsx-ventas";

export async function GET(request: NextRequest) {
  await getCurrentProfile(); // exige sesión activa; RLS igual filtra qué ventas ve cada rol
  const supabase = await createClient();
  const params = request.nextUrl.searchParams;

  // Filtros idénticos a los que ya tenía este endpoint (y a los del listado
  // /ventas del que este botón exporta) — no se toca ninguno.
  let query = supabase
    .from("sales")
    .select("*")
    .order("sold_at", { ascending: false })
    .limit(5000);

  const from = params.get("from");
  const to = params.get("to");
  const location = params.get("location");
  const channel = params.get("channel");
  const seller = params.get("seller");
  const doctor = params.get("doctor");
  const payment = params.get("payment");
  const rawStatus = params.get("status");
  const status =
    rawStatus === "confirmed" || rawStatus === "cancelled" || rawStatus === "replaced" ? rawStatus : null;

  if (from) query = query.gte("sold_at", `${from}T00:00:00-03:00`);
  if (to) query = query.lte("sold_at", `${to}T23:59:59-03:00`);
  if (location) query = query.eq("location_id", location);
  if (channel) query = query.eq("sales_channel_id", channel);
  if (seller) query = query.eq("seller_id", seller);
  if (doctor) query = query.eq("doctor_id", doctor);
  if (payment) query = query.eq("payment_method_id", payment);
  if (status) query = query.eq("status", status);

  const { data: sales, error } = await query;
  if (error) return new Response(error.message, { status: 400 });

  const saleIds = (sales ?? []).map((s) => s.id);

  const ids = {
    locations: Array.from(new Set((sales ?? []).map((s) => s.location_id))),
    sellers: Array.from(new Set((sales ?? []).map((s) => s.seller_id).filter((v): v is string => !!v))),
    customers: Array.from(new Set((sales ?? []).map((s) => s.customer_id).filter((v): v is string => !!v))),
    doctors: Array.from(new Set((sales ?? []).map((s) => s.doctor_id).filter((v): v is string => !!v))),
    payments: Array.from(new Set((sales ?? []).map((s) => s.payment_method_id))),
    accounts: Array.from(
      new Set((sales ?? []).map((s) => s.payment_account_id).filter((v): v is string => !!v))
    ),
  };

  const [locs, sellers, customers, doctors, payments, accounts, items] = await Promise.all([
    ids.locations.length ? supabase.from("stock_locations").select("id, name") : Promise.resolve({ data: [] }),
    ids.sellers.length ? supabase.from("profiles").select("id, full_name") : Promise.resolve({ data: [] }),
    ids.customers.length
      ? supabase.from("customers").select("id, full_name, dni")
      : Promise.resolve({ data: [] as { id: string; full_name: string; dni: string | null }[] }),
    ids.doctors.length ? supabase.from("doctors").select("id, full_name") : Promise.resolve({ data: [] }),
    ids.payments.length ? supabase.from("payment_methods").select("id, name") : Promise.resolve({ data: [] }),
    ids.accounts.length ? supabase.from("payment_accounts").select("id, name") : Promise.resolve({ data: [] }),
    // sale_items comerciales tal cual quedaron en el carrito de cada venta —
    // nunca sale_item_net (eso es neto de devoluciones, otro concepto) ni
    // kit_components (un kit nunca se explota, es su propio product_id).
    saleIds.length
      ? supabase.from("sale_items").select("sale_id, product_id, quantity").in("sale_id", saleIds)
      : Promise.resolve({ data: [] as { sale_id: string; product_id: string; quantity: string }[] }),
  ]);

  const productIds = Array.from(new Set((items.data ?? []).map((i) => i.product_id)));
  const { data: products } = productIds.length
    ? await supabase.from("products").select("id, name").in("id", productIds)
    : { data: [] as { id: string; name: string }[] };

  const nameMap = (rows: { id: string; name?: string; full_name?: string }[] | null) =>
    new Map((rows ?? []).map((r) => [r.id, r.name ?? r.full_name ?? ""]));

  const locMap = nameMap(locs.data as never);
  const sellerMap = nameMap(sellers.data as never);
  const customerMap = new Map((customers.data ?? []).map((c) => [c.id, c]));
  const doctorMap = nameMap(doctors.data as never);
  const paymentMap = nameMap(payments.data as never);
  const accountMap = nameMap(accounts.data as never);
  const productNameMap = new Map((products ?? []).map((p) => [p.id, p.name]));
  const productsBySale = groupProductsBySale(items.data ?? [], productNameMap);

  const rows: VentaExportRow[] = (sales ?? []).map((s) => {
    const customer = s.customer_id ? customerMap.get(s.customer_id) : undefined;

    return {
      soldAt: s.sold_at,
      saleNumber: s.sale_number,
      customerName: customer?.full_name ?? null,
      customerDni: customer?.dni ?? null,
      products: productsBySale.get(s.id) ?? [],
      paymentMethodName: paymentMap.get(s.payment_method_id) ?? null,
      accountName: s.payment_account_id ? accountMap.get(s.payment_account_id) ?? null : null,
      total: Number(s.total),
      locationName: locMap.get(s.location_id) ?? null,
      sellerName: s.seller_id ? sellerMap.get(s.seller_id) ?? null : null,
      doctorName: s.doctor_id ? doctorMap.get(s.doctor_id) ?? null : null,
      status: s.status,
    };
  });

  const workbook = await buildVentasWorkbook(rows);
  const buffer = await workbook.xlsx.writeBuffer();
  return xlsxResponse("ventas.xlsx", buffer);
}
