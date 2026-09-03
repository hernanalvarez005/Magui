import type { Metadata } from "next";
import Link from "next/link";

import { createClient } from "@/lib/supabase/server";
import { EmptyState } from "@/components/shared/empty-state";
import { BillingTable } from "@/components/admin/billing-table";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";

export const metadata: Metadata = { title: "Facturación pendiente" };

const PAGE_SIZE = 30;

const TABS = [
  { value: "pending", label: "Pendientes" },
  { value: "invoiced", label: "Facturadas" },
  { value: "all", label: "Todas" },
] as const;

type Tab = (typeof TABS)[number]["value"];

export default async function BillingPage(props: PageProps<"/admin/facturacion">) {
  const searchParams = await props.searchParams;
  const rawTab = typeof searchParams.tab === "string" ? searchParams.tab : "pending";
  const tab: Tab = rawTab === "invoiced" || rawTab === "all" ? rawTab : "pending";
  const page = Math.max(1, Number(searchParams.page ?? 1) || 1);

  const supabase = await createClient();

  // Solo las columnas que realmente se muestran (sección 31 del pedido) —
  // nunca select("*"). status = confirmed SIEMPRE: una venta anulada nunca
  // aparece acá, en ninguna de las 3 pestañas (sección 21/22) — este panel
  // es exclusivamente sobre operaciones vigentes, la vista de anuladas ya
  // vive en /ventas con su propio filtro.
  let query = supabase
    .from("sales")
    .select(
      "id, sale_number, sold_at, customer_id, total, payment_account_id, payment_method_id, billing_status, invoiced_at, invoiced_by",
      { count: "exact" }
    )
    .eq("status", "confirmed");

  if (tab === "pending") {
    // Vista por defecto: la más antigua primero, para facturar en orden y
    // no saltear operaciones (sección 12 del pedido).
    query = query.eq("billing_status", "PENDING").order("sold_at", { ascending: true });
  } else if (tab === "invoiced") {
    query = query.eq("billing_status", "INVOICED").order("sold_at", { ascending: false });
  } else {
    query = query.order("sold_at", { ascending: false });
  }

  query = query.range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);

  const { data: sales, count } = await query;

  const saleIds = (sales ?? []).map((s) => s.id);
  const customerIds = Array.from(new Set((sales ?? []).map((s) => s.customer_id).filter((id): id is string => !!id)));
  const accountIds = Array.from(
    new Set((sales ?? []).map((s) => s.payment_account_id).filter((id): id is string => !!id))
  );
  const paymentIds = Array.from(new Set((sales ?? []).map((s) => s.payment_method_id)));
  const invoicedByIds = Array.from(
    new Set((sales ?? []).map((s) => s.invoiced_by).filter((id): id is string => !!id))
  );

  const [{ data: customers }, { data: accounts }, { data: paymentMethods }, { data: invoicedByProfiles }, { data: saleItems }] =
    await Promise.all([
      customerIds.length
        ? supabase.from("customers").select("id, full_name, dni").in("id", customerIds)
        : Promise.resolve({ data: [] as { id: string; full_name: string; dni: string | null }[] }),
      accountIds.length
        ? supabase.from("payment_accounts").select("id, name").in("id", accountIds)
        : Promise.resolve({ data: [] as { id: string; name: string }[] }),
      paymentIds.length
        ? supabase.from("payment_methods").select("id, name").in("id", paymentIds)
        : Promise.resolve({ data: [] as { id: string; name: string }[] }),
      invoicedByIds.length
        ? supabase.from("profiles").select("id, full_name").in("id", invoicedByIds)
        : Promise.resolve({ data: [] as { id: string; full_name: string }[] }),
      // Detalle de "qué se compró" (sección 1-3 del pedido): igual criterio
      // que sale_items (un kit vendido queda UNA fila, con su propio
      // product_id de kit — nunca se reconstruye mirando movimientos de
      // stock), pero leído de sale_item_net en vez del crudo: cantidad e
      // importe netos de devoluciones (precisión #6 del pedido, cerrada con
      // el usuario — una venta PENDING no puede seguir mostrando el bruto
      // original después de una devolución, o se termina facturando de más).
      // INVOICED nunca se toca acá (el comprobante ya emitido es un hecho
      // fiscal consumado, ver advertencia en el detalle de la venta) — solo
      // PENDING usa el neto, más abajo. Solo las columnas que realmente se
      // usan, nunca select("*") (sección 10).
      saleIds.length
        ? supabase
            .from("sale_item_net")
            .select("sale_id, product_id, net_quantity, net_line_total")
            .in("sale_id", saleIds)
        : Promise.resolve({ data: [] as { sale_id: string; product_id: string; net_quantity: number; net_line_total: number }[] }),
    ]);

  const netTotalBySale = new Map<string, number>();
  for (const row of saleItems ?? []) {
    netTotalBySale.set(row.sale_id, (netTotalBySale.get(row.sale_id) ?? 0) + Number(row.net_line_total));
  }

  // sale_items solo guarda product_id (no un snapshot de nombre) — el
  // nombre se resuelve vía join a products, mismo criterio que ya usa
  // /ventas/[id] para el detalle de una venta. Una sola query batcheada acá
  // (nunca 1 por venta): sin importar cuántas ventas/ítems haya en la
  // página, siempre son 5 queries fijas (sección 9 del pedido).
  const itemProductIds = Array.from(new Set((saleItems ?? []).map((i) => i.product_id)));
  const { data: itemProducts } = itemProductIds.length
    ? await supabase.from("products").select("id, name").in("id", itemProductIds)
    : { data: [] as { id: string; name: string }[] };
  const itemProductNameById = new Map((itemProducts ?? []).map((p) => [p.id, p.name]));

  const itemsBySale = new Map<string, { name: string; quantity: number }[]>();
  for (const item of saleItems ?? []) {
    // Una línea devuelta en su totalidad (net_quantity=0) no queda listada:
    // no hay nada de ese producto que siga pendiente de facturar.
    if (Number(item.net_quantity) <= 0) continue;
    const list = itemsBySale.get(item.sale_id) ?? [];
    list.push({ name: itemProductNameById.get(item.product_id) ?? "Producto eliminado", quantity: Number(item.net_quantity) });
    itemsBySale.set(item.sale_id, list);
  }

  const customerMap = new Map((customers ?? []).map((c) => [c.id, c]));
  const accountMap = new Map((accounts ?? []).map((a) => [a.id, a.name]));
  const paymentMap = new Map((paymentMethods ?? []).map((p) => [p.id, p.name]));
  const invoicedByMap = new Map((invoicedByProfiles ?? []).map((p) => [p.id, p.full_name]));

  const rows = (sales ?? []).map((s) => {
    const netTotal = netTotalBySale.get(s.id) ?? Number(s.total);
    const hasReturn = netTotal !== Number(s.total);
    return {
      ...s,
      // Solo PENDING reemplaza el importe mostrado por el neto — INVOICED
      // sigue mostrando lo que realmente se facturó (matriz PENDING/INVOICED
      // × parcial/total, cerrada con el usuario).
      total: s.billing_status === "PENDING" ? String(netTotal) : s.total,
      hasReturn,
      customer: s.customer_id ? customerMap.get(s.customer_id) : undefined,
      accountName: s.payment_account_id ? accountMap.get(s.payment_account_id) : undefined,
      paymentName: paymentMap.get(s.payment_method_id),
      invoicedByName: s.invoiced_by ? invoicedByMap.get(s.invoiced_by) : undefined,
      items: itemsBySale.get(s.id) ?? [],
    };
  });

  const totalPages = count ? Math.ceil(count / PAGE_SIZE) : 1;

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-muted-foreground">
        Workflow administrativo sobre ventas ya confirmadas y cobradas — controla si ya se emitió la factura
        correspondiente. Nunca modifica el estado comercial de la venta ni crea ventas nuevas.
      </p>

      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex gap-1 rounded-lg bg-muted p-1">
          {TABS.map((t) => (
            <Link
              key={t.value}
              href={`/admin/facturacion?tab=${t.value}`}
              className={cn(
                "rounded-md px-3.5 py-1.5 text-sm font-medium transition-colors",
                tab === t.value ? "bg-background text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground"
              )}
            >
              {t.label}
              {t.value === "pending" ? <Badge variant="warning" className="ml-1.5">{tab === "pending" ? count ?? 0 : ""}</Badge> : null}
            </Link>
          ))}
        </div>
      </div>

      {rows.length === 0 ? (
        <EmptyState
          title={
            tab === "pending"
              ? "No hay operaciones pendientes de facturar."
              : tab === "invoiced"
                ? "Todavía no se marcó ninguna operación como facturada."
                : "No hay operaciones para mostrar."
          }
        />
      ) : (
        <>
          <BillingTable rows={rows} showInvoicedColumns={tab !== "pending"} />
          <div className="flex items-center justify-between text-sm text-muted-foreground">
            <span>
              Página {page} de {totalPages} · {count} operaciones
            </span>
            <div className="flex gap-2">
              <Button variant="outline" size="sm" disabled={page <= 1} asChild={page > 1}>
                {page > 1 ? (
                  <Link href={`/admin/facturacion?tab=${tab}&page=${page - 1}`}>Anterior</Link>
                ) : (
                  <span>Anterior</span>
                )}
              </Button>
              <Button variant="outline" size="sm" disabled={page >= totalPages} asChild={page < totalPages}>
                {page < totalPages ? (
                  <Link href={`/admin/facturacion?tab=${tab}&page=${page + 1}`}>Siguiente</Link>
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
