import type { Metadata } from "next";
import Link from "next/link";
import { ArrowLeft } from "lucide-react";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/shared/empty-state";
import { HistorialFilters } from "@/components/notificaciones/historial-filters";
import { HistorialList } from "@/components/notificaciones/historial-list";
import type { WebOrderHistoryDisplayStatus } from "@/types/database";

export const metadata: Metadata = { title: "Historial de pedidos Web" };

const PAGE_SIZE = 20;
const VALID_STATUSES: WebOrderHistoryDisplayStatus[] = ["DELIVERED", "SHIPPED", "CANCELLED"];

export default async function HistorialPage(props: PageProps<"/notificaciones/historial">) {
  const searchParams = await props.searchParams;
  await getCurrentProfile();
  const supabase = await createClient();

  const page = Math.max(1, Number(searchParams.page ?? 1) || 1);
  const from = typeof searchParams.from === "string" ? searchParams.from : undefined;
  const to = typeof searchParams.to === "string" ? searchParams.to : undefined;
  const locationId = typeof searchParams.location === "string" ? searchParams.location : undefined;
  const rawStatus = typeof searchParams.status === "string" ? searchParams.status : undefined;
  const status = VALID_STATUSES.includes(rawStatus as WebOrderHistoryDisplayStatus)
    ? (rawStatus as WebOrderHistoryDisplayStatus)
    : undefined;
  const search = typeof searchParams.q === "string" && searchParams.q.trim() ? searchParams.q.trim() : undefined;

  // Mismo criterio de zona horaria que /ventas (from/to en fecha local de
  // Buenos Aires, convertidos a límites de día completo en -03:00).
  const [{ data: locations }, { data: rows }] = await Promise.all([
    supabase.from("stock_locations").select("id, code, name").in("code", ["SED-25", "SED-37", "DEP"]).order("code"),
    supabase.rpc("web_order_history", {
      p_location_id: locationId ?? null,
      p_status: status ?? null,
      p_date_from: from ? `${from}T00:00:00-03:00` : null,
      p_date_to: to ? `${to}T23:59:59-03:00` : null,
      p_search: search ?? null,
      p_limit: PAGE_SIZE,
      p_offset: (page - 1) * PAGE_SIZE,
    }),
  ]);

  const totalCount = rows && rows.length > 0 ? rows[0].total_count : 0;
  const totalPages = totalCount ? Math.ceil(totalCount / PAGE_SIZE) : 1;

  return (
    <div className="mx-auto flex max-w-3xl flex-col gap-4 p-4 md:p-6">
      <div className="flex items-center gap-2">
        <Button variant="ghost" size="icon" asChild>
          <Link href="/notificaciones">
            <ArrowLeft className="size-4" />
          </Link>
        </Button>
        <h1 className="text-lg font-semibold">Historial de pedidos Web</h1>
      </div>

      <HistorialFilters locations={locations ?? []} />

      {!rows || rows.length === 0 ? (
        <EmptyState
          title="No hay pedidos Web que coincidan con estos filtros"
          description="Entregados, enviados y anulados van a aparecer acá."
        />
      ) : (
        <>
          <HistorialList rows={rows} />
          <div className="flex items-center justify-between text-sm text-muted-foreground">
            <span>
              Página {page} de {totalPages} · {totalCount} pedidos
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

function buildHref(searchParams: Record<string, string | string[] | undefined>, page: number) {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(searchParams)) {
    if (key === "page" || value === undefined) continue;
    params.set(key, Array.isArray(value) ? value[0] : value);
  }
  params.set("page", String(page));
  return `/notificaciones/historial?${params.toString()}`;
}
