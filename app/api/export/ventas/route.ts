import type { NextRequest } from "next/server";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { csvResponse, toCsv } from "@/lib/csv";
import { formatDateTime } from "@/lib/utils";

export async function GET(request: NextRequest) {
  await getCurrentProfile(); // exige sesión activa; RLS igual filtra qué ventas ve cada rol
  const supabase = await createClient();
  const params = request.nextUrl.searchParams;

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
  const status = rawStatus === "confirmed" || rawStatus === "cancelled" ? rawStatus : null;

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

  const ids = {
    locations: Array.from(new Set((sales ?? []).map((s) => s.location_id))),
    channels: Array.from(new Set((sales ?? []).map((s) => s.sales_channel_id))),
    sellers: Array.from(new Set((sales ?? []).map((s) => s.seller_id).filter((v): v is string => !!v))),
    customers: Array.from(new Set((sales ?? []).map((s) => s.customer_id).filter((v): v is string => !!v))),
    doctors: Array.from(new Set((sales ?? []).map((s) => s.doctor_id).filter((v): v is string => !!v))),
    payments: Array.from(new Set((sales ?? []).map((s) => s.payment_method_id))),
  };

  const [locs, chs, sellers, customers, doctors, payments] = await Promise.all([
    ids.locations.length ? supabase.from("stock_locations").select("id, name") : Promise.resolve({ data: [] }),
    ids.channels.length ? supabase.from("sales_channels").select("id, name") : Promise.resolve({ data: [] }),
    ids.sellers.length ? supabase.from("profiles").select("id, full_name") : Promise.resolve({ data: [] }),
    ids.customers.length ? supabase.from("customers").select("id, full_name") : Promise.resolve({ data: [] }),
    ids.doctors.length ? supabase.from("doctors").select("id, full_name") : Promise.resolve({ data: [] }),
    ids.payments.length ? supabase.from("payment_methods").select("id, name") : Promise.resolve({ data: [] }),
  ]);

  const nameMap = (rows: { id: string; name?: string; full_name?: string }[] | null) =>
    new Map((rows ?? []).map((r) => [r.id, r.name ?? r.full_name ?? ""]));

  const locMap = nameMap(locs.data as never);
  const chMap = nameMap(chs.data as never);
  const sellerMap = nameMap(sellers.data as never);
  const customerMap = nameMap(customers.data as never);
  const doctorMap = nameMap(doctors.data as never);
  const paymentMap = nameMap(payments.data as never);

  const rows = (sales ?? []).map((s) => ({
    sale_number: s.sale_number,
    sold_at: formatDateTime(s.sold_at),
    location: locMap.get(s.location_id) ?? "",
    channel: chMap.get(s.sales_channel_id) ?? "",
    seller: s.seller_id ? sellerMap.get(s.seller_id) ?? "" : "",
    customer: s.customer_id ? customerMap.get(s.customer_id) ?? "" : "",
    payment_method: paymentMap.get(s.payment_method_id) ?? "",
    subtotal: s.subtotal,
    discount_total: s.discount_total,
    total: s.total,
    doctor: s.doctor_id ? doctorMap.get(s.doctor_id) ?? "" : "",
    commission_total: s.commission_total,
    status: s.status,
  }));

  const csv = toCsv(rows, [
    { key: "sale_number", header: "Nº venta" },
    { key: "sold_at", header: "Fecha" },
    { key: "location", header: "Sucursal" },
    { key: "channel", header: "Canal" },
    { key: "seller", header: "Vendedor/a" },
    { key: "customer", header: "Cliente" },
    { key: "payment_method", header: "Medio de pago" },
    { key: "subtotal", header: "Subtotal" },
    { key: "discount_total", header: "Descuento" },
    { key: "total", header: "Total" },
    { key: "doctor", header: "Doctora" },
    { key: "commission_total", header: "Comisión" },
    { key: "status", header: "Estado" },
  ]);

  return csvResponse("ventas.csv", csv);
}
