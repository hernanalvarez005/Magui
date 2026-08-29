import type { Metadata } from "next";
import Link from "next/link";
import { Download } from "lucide-react";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { EmptyState } from "@/components/shared/empty-state";
import { MovementFilters } from "@/components/inventory/movement-filters";
import { MovementsTable } from "@/components/inventory/movements-table";
import { Button } from "@/components/ui/button";

export const metadata: Metadata = { title: "Movimientos de stock" };

const PAGE_SIZE = 50;

const MOVEMENT_TYPES = [
  "INITIAL",
  "PURCHASE",
  "SALE",
  "SALE_CANCEL",
  "ADJUSTMENT_PLUS",
  "ADJUSTMENT_MINUS",
  "TRANSFER_OUT",
  "TRANSFER_IN",
  "RETURN",
] as const;

export default async function StockMovementsPage(props: PageProps<"/stock/movimientos">) {
  const searchParams = await props.searchParams;
  const profile = await getCurrentProfile();
  const supabase = await createClient();

  const page = Math.max(1, Number(searchParams.page ?? 1) || 1);
  const locationId = typeof searchParams.location === "string" ? searchParams.location : undefined;
  const productId = typeof searchParams.product === "string" ? searchParams.product : undefined;
  const rawType = typeof searchParams.type === "string" ? searchParams.type : undefined;
  const type = MOVEMENT_TYPES.find((t) => t === rawType);
  const from = typeof searchParams.from === "string" ? searchParams.from : undefined;
  const to = typeof searchParams.to === "string" ? searchParams.to : undefined;

  let query = supabase
    .from("stock_movements")
    .select("*", { count: "exact" })
    .order("occurred_at", { ascending: false })
    .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);

  if (locationId) query = query.eq("location_id", locationId);
  if (productId) query = query.eq("product_id", productId);
  if (type) query = query.eq("movement_type", type);
  if (from) query = query.gte("occurred_at", `${from}T00:00:00-03:00`);
  if (to) query = query.lte("occurred_at", `${to}T23:59:59-03:00`);

  // locations/products no dependen de los filtros de arriba, así que van en
  // paralelo con la consulta de movimientos en vez de esperarla.
  const [{ data: locations }, { data: products }, { data: movements, count }] = await Promise.all([
    supabase
      .from("stock_locations")
      .select("id, code, name")
      .in("id", profile.locationIds.length > 0 ? profile.locationIds : ["00000000-0000-0000-0000-000000000000"])
      .order("name"),
    supabase.from("products").select("id, sku, name").order("name"),
    query,
  ]);

  // Nota: la RLS de stock_movements exige has_location_access(location_id)
  // — exactamente el mismo criterio que ya usa la consulta de arriba para
  // `locations` (scoped a profile.locationIds). Todo movimiento visible cae
  // necesariamente dentro de esas mismas sedes, y `products` de arriba ya
  // trae TODOS los productos — así que no hace falta volver a pedirle a la
  // base ninguna de las dos tablas por separado para armar estos mapas.
  const productMap = new Map((products ?? []).map((p) => [p.id, p]));
  const locationMap = new Map((locations ?? []).map((l) => [l.id, l]));

  const userIds = Array.from(
    new Set((movements ?? []).map((m) => m.created_by).filter((id): id is string => !!id))
  );
  const saleIds = Array.from(
    new Set((movements ?? []).map((m) => m.sale_id).filter((id): id is string => !!id))
  );

  const [{ data: profileRows }, { data: saleRows }] = await Promise.all([
    userIds.length
      ? supabase.from("profiles").select("id, full_name").in("id", userIds)
      : Promise.resolve({ data: [] as { id: string; full_name: string }[] }),
    saleIds.length
      ? supabase.from("sales").select("id, sale_number").in("id", saleIds)
      : Promise.resolve({ data: [] as { id: string; sale_number: string }[] }),
  ]);

  const profileMap = new Map((profileRows ?? []).map((p) => [p.id, p]));
  const saleMap = new Map((saleRows ?? []).map((s) => [s.id, s]));

  const rows = (movements ?? []).map((m) => ({
    ...m,
    product: productMap.get(m.product_id),
    location: locationMap.get(m.location_id),
    user: m.created_by ? profileMap.get(m.created_by) : undefined,
    sale: m.sale_id ? saleMap.get(m.sale_id) : undefined,
  }));

  const totalPages = count ? Math.ceil(count / PAGE_SIZE) : 1;

  const exportParams = new URLSearchParams();
  for (const [key, value] of Object.entries(searchParams)) {
    if (key === "page" || value === undefined) continue;
    exportParams.set(key, Array.isArray(value) ? value[0] : value);
  }

  return (
    <div className="flex flex-col gap-5 p-4 md:p-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">Movimientos de stock</h1>
          <p className="text-sm text-muted-foreground">Ledger completo, auditable y con trazabilidad de origen.</p>
        </div>
        {profile.role === "admin" ? (
          <Button variant="outline" size="sm" asChild>
            <a href={`/api/export/movimientos?${exportParams.toString()}`}>
              <Download className="size-4" /> Exportar CSV
            </a>
          </Button>
        ) : null}
      </div>

      <MovementFilters locations={locations ?? []} products={products ?? []} types={[...MOVEMENT_TYPES]} />

      {rows.length === 0 ? (
        <EmptyState title="No hay movimientos para estos filtros." />
      ) : (
        <>
          <MovementsTable rows={rows} />
          <div className="flex items-center justify-between text-sm text-muted-foreground">
            <span>
              Página {page} de {totalPages} · {count} movimientos
            </span>
            <div className="flex gap-2">
              <Button variant="outline" size="sm" disabled={page <= 1} asChild={page > 1}>
                {page > 1 ? (
                  <Link href={buildPageHref(searchParams, page - 1)}>Anterior</Link>
                ) : (
                  <span>Anterior</span>
                )}
              </Button>
              <Button variant="outline" size="sm" disabled={page >= totalPages} asChild={page < totalPages}>
                {page < totalPages ? (
                  <Link href={buildPageHref(searchParams, page + 1)}>Siguiente</Link>
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

function buildPageHref(searchParams: Record<string, string | string[] | undefined>, page: number) {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(searchParams)) {
    if (key === "page" || value === undefined) continue;
    params.set(key, Array.isArray(value) ? value[0] : value);
  }
  params.set("page", String(page));
  return `/stock/movimientos?${params.toString()}`;
}
