import type { Metadata } from "next";
import Link from "next/link";
import { Download } from "lucide-react";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { EmptyState } from "@/components/shared/empty-state";
import { SalesFilters } from "@/components/sales/sales-filters";
import { SalesTable } from "@/components/sales/sales-table";
import { Button } from "@/components/ui/button";
import { todayInBuenosAires } from "@/lib/utils";

export const metadata: Metadata = { title: "Ventas" };

const PAGE_SIZE = 30;

export default async function SalesListPage(props: PageProps<"/ventas">) {
  const searchParams = await props.searchParams;
  const profile = await getCurrentProfile();
  const supabase = await createClient();

  const page = Math.max(1, Number(searchParams.page ?? 1) || 1);
  const from = typeof searchParams.from === "string" ? searchParams.from : undefined;
  const to = typeof searchParams.to === "string" ? searchParams.to : todayInBuenosAires();
  const locationId = typeof searchParams.location === "string" ? searchParams.location : undefined;
  const channelId = typeof searchParams.channel === "string" ? searchParams.channel : undefined;
  const sellerId = typeof searchParams.seller === "string" ? searchParams.seller : undefined;
  const doctorId = typeof searchParams.doctor === "string" ? searchParams.doctor : undefined;
  const paymentMethodId = typeof searchParams.payment === "string" ? searchParams.payment : undefined;
  const rawStatus = typeof searchParams.status === "string" ? searchParams.status : undefined;
  const status =
    rawStatus === "confirmed" || rawStatus === "cancelled" || rawStatus === "replaced" ? rawStatus : undefined;

  // Columnas explícitas: SalesTable y los mapeos de abajo (locationIds,
  // sellerIds, etc.) solo usan estas 14 — la tabla tiene 26 en total
  // (subtotal, notes, external_source/order_id, cancellation_reason,
  // created_at/updated_at, etc. quedan afuera). El detalle de una venta
  // puntual (/ventas/[id]) sí necesita todo, ahí select("*") es correcto.
  let query = supabase
    .from("sales")
    .select(
      "id, sale_number, sold_at, location_id, sales_channel_id, seller_id, customer_id, doctor_id, payment_method_id, total, commission_total, status, is_free_sale, stock_skipped",
      { count: "exact" }
    )
    .order("sold_at", { ascending: false })
    .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);

  if (from) query = query.gte("sold_at", `${from}T00:00:00-03:00`);
  if (to) query = query.lte("sold_at", `${to}T23:59:59-03:00`);
  if (locationId) query = query.eq("location_id", locationId);
  if (channelId) query = query.eq("sales_channel_id", channelId);
  if (sellerId) query = query.eq("seller_id", sellerId);
  if (doctorId) query = query.eq("doctor_id", doctorId);
  if (paymentMethodId) query = query.eq("payment_method_id", paymentMethodId);
  if (status) query = query.eq("status", status);

  // Ninguna de estas depende de las otras (los filtros de arriba usan los IDs
  // crudos de la URL, no las filas resueltas) — van todas en paralelo.
  const [{ data: locations }, { data: channels }, { data: paymentMethods }, { data: doctors }, sellersResult, { data: sales, count }] =
    await Promise.all([
      supabase
        .from("stock_locations")
        .select("id, code, name")
        .in("id", profile.locationIds.length > 0 ? profile.locationIds : ["00000000-0000-0000-0000-000000000000"])
        .order("name"),
      supabase.from("sales_channels").select("id, code, name").order("sort_order"),
      supabase.from("payment_methods").select("id, code, name").order("sort_order"),
      supabase.from("doctors").select("id, code, full_name").order("full_name"),
      profile.role === "admin"
        ? supabase.from("profiles").select("id, full_name").order("full_name")
        : Promise.resolve({ data: null }),
      query,
    ]);
  const sellers = sellersResult.data;

  const locationIds = Array.from(new Set((sales ?? []).map((s) => s.location_id)));
  const channelIds = Array.from(new Set((sales ?? []).map((s) => s.sales_channel_id)));
  const sellerIds = Array.from(
    new Set((sales ?? []).map((s) => s.seller_id).filter((id): id is string => !!id))
  );
  const customerIds = Array.from(
    new Set((sales ?? []).map((s) => s.customer_id).filter((id): id is string => !!id))
  );
  const doctorIds = Array.from(
    new Set((sales ?? []).map((s) => s.doctor_id).filter((id): id is string => !!id))
  );
  const paymentIds = Array.from(new Set((sales ?? []).map((s) => s.payment_method_id)));

  const [{ data: locRows }, { data: chRows }, { data: sellerRows }, { data: custRows }, { data: docRows }, { data: pmRows }] =
    await Promise.all([
      locationIds.length
        ? supabase.from("stock_locations").select("id, code, name").in("id", locationIds)
        : empty<{ id: string; code: string; name: string }>(),
      channelIds.length
        ? supabase.from("sales_channels").select("id, name").in("id", channelIds)
        : empty<{ id: string; name: string }>(),
      sellerIds.length
        ? supabase.from("profiles").select("id, full_name").in("id", sellerIds)
        : empty<{ id: string; full_name: string }>(),
      customerIds.length
        ? supabase.from("customers").select("id, full_name").in("id", customerIds)
        : empty<{ id: string; full_name: string }>(),
      doctorIds.length
        ? supabase.from("doctors").select("id, full_name").in("id", doctorIds)
        : empty<{ id: string; full_name: string }>(),
      paymentIds.length
        ? supabase.from("payment_methods").select("id, name").in("id", paymentIds)
        : empty<{ id: string; name: string }>(),
    ]);

  const locMap = new Map((locRows ?? []).map((r) => [r.id, r]));
  const chMap = new Map((chRows ?? []).map((r) => [r.id, r]));
  const sellerMap = new Map((sellerRows ?? []).map((r) => [r.id, r]));
  const custMap = new Map((custRows ?? []).map((r) => [r.id, r]));
  const docMap = new Map((docRows ?? []).map((r) => [r.id, r]));
  const pmMap = new Map((pmRows ?? []).map((r) => [r.id, r]));

  const rows = (sales ?? []).map((s) => ({
    ...s,
    location: locMap.get(s.location_id),
    channel: chMap.get(s.sales_channel_id),
    seller: s.seller_id ? sellerMap.get(s.seller_id) : undefined,
    customer: s.customer_id ? custMap.get(s.customer_id) : undefined,
    doctor: s.doctor_id ? docMap.get(s.doctor_id) : undefined,
    paymentMethod: pmMap.get(s.payment_method_id),
  }));

  const totalPages = count ? Math.ceil(count / PAGE_SIZE) : 1;

  const exportParams = new URLSearchParams();
  for (const [key, value] of Object.entries(searchParams)) {
    if (value === undefined) continue;
    exportParams.set(key, Array.isArray(value) ? value[0] : value);
  }

  return (
    <div className="flex flex-col gap-5 p-4 md:p-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">Ventas</h1>
          <p className="text-sm text-muted-foreground">
            {profile.role === "admin" || profile.role === "viewer"
              ? "Ventas de las sucursales a las que tenés acceso."
              : "Tus ventas recientes."}
          </p>
        </div>
        {profile.role === "admin" ? (
          <div className="flex gap-2">
            <Button variant="outline" size="sm" asChild>
              <a href={`/api/export/ventas?${exportParams.toString()}`}>
                <Download className="size-4" /> Exportar ventas
              </a>
            </Button>
            <Button variant="outline" size="sm" asChild>
              <a href={`/api/export/detalle-ventas?${exportParams.toString()}`}>
                <Download className="size-4" /> Exportar detalle
              </a>
            </Button>
          </div>
        ) : null}
      </div>

      <SalesFilters
        locations={locations ?? []}
        channels={channels ?? []}
        paymentMethods={paymentMethods ?? []}
        doctors={doctors ?? []}
        sellers={sellers}
      />

      {rows.length === 0 ? (
        <EmptyState
          title="Todavía no hay ventas en este período."
          action={
            <Button asChild size="sm">
              <Link href="/ventas/nueva">Nueva venta</Link>
            </Button>
          }
        />
      ) : (
        <>
          <SalesTable rows={rows} />
          <div className="flex items-center justify-between text-sm text-muted-foreground">
            <span>
              Página {page} de {totalPages} · {count} ventas
            </span>
            <div className="flex gap-2">
              <Button variant="outline" size="sm" disabled={page <= 1} asChild={page > 1}>
                {page > 1 ? <Link href={buildHref(searchParams, page - 1)}>Anterior</Link> : <span>Anterior</span>}
              </Button>
              <Button variant="outline" size="sm" disabled={page >= totalPages} asChild={page < totalPages}>
                {page < totalPages ? (
                  <Link href={buildHref(searchParams, page + 1)}>Siguiente</Link>
                ) : (
                  <span>Siguiente</span>
                )}
              </Button>
            </div>
          </div>
        </>
      )}
    </div>
  );
}

function empty<T>() {
  return Promise.resolve({ data: [] as T[] });
}

function buildHref(searchParams: Record<string, string | string[] | undefined>, page: number) {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(searchParams)) {
    if (key === "page" || value === undefined) continue;
    params.set(key, Array.isArray(value) ? value[0] : value);
  }
  params.set("page", String(page));
  return `/ventas?${params.toString()}`;
}
