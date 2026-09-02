import type { Metadata } from "next";
import { notFound } from "next/navigation";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { SaleDetailView } from "@/components/sales/sale-detail-view";

export const metadata: Metadata = { title: "Detalle de venta" };

export default async function SaleDetailPage(props: PageProps<"/ventas/[id]">) {
  const { id } = await props.params;
  const profile = await getCurrentProfile();
  const supabase = await createClient();

  const { data: sale } = await supabase.from("sales").select("*").eq("id", id).maybeSingle();
  if (!sale) notFound();

  const [
    { data: items },
    { data: location },
    { data: channel },
    { data: seller },
    { data: customer },
    { data: doctor },
    { data: paymentMethod },
    { data: paymentAccount },
    { data: condition },
    { data: cancelledBy },
    { data: movements },
    { data: replacedBy },
    { data: replacesOriginal },
  ] = await Promise.all([
    supabase.from("sale_items").select("*").eq("sale_id", id),
    supabase.from("stock_locations").select("code, name").eq("id", sale.location_id).single(),
    supabase.from("sales_channels").select("name").eq("id", sale.sales_channel_id).single(),
    sale.seller_id
      ? supabase.from("profiles").select("full_name").eq("id", sale.seller_id).maybeSingle()
      : Promise.resolve({ data: null }),
    sale.customer_id
      ? supabase.from("customers").select("full_name, dni, whatsapp").eq("id", sale.customer_id).maybeSingle()
      : Promise.resolve({ data: null }),
    sale.doctor_id
      ? supabase.from("doctors").select("full_name, commission_percent").eq("id", sale.doctor_id).maybeSingle()
      : Promise.resolve({ data: null }),
    supabase.from("payment_methods").select("name").eq("id", sale.payment_method_id).single(),
    sale.payment_account_id
      ? supabase.from("payment_accounts").select("name").eq("id", sale.payment_account_id).maybeSingle()
      : Promise.resolve({ data: null }),
    sale.applied_price_condition_id
      ? supabase.from("price_conditions").select("name").eq("id", sale.applied_price_condition_id).maybeSingle()
      : Promise.resolve({ data: null }),
    sale.cancelled_by
      ? supabase.from("profiles").select("full_name").eq("id", sale.cancelled_by).maybeSingle()
      : Promise.resolve({ data: null }),
    supabase.from("stock_movements").select("*").eq("sale_id", id).order("occurred_at"),
    // Cambios/Devoluciones — vínculo en las DOS direcciones (sección 34 del
    // pedido). replacedBy: esta venta fue reemplazada por un cambio
    // (status=replaced) -> la operación nueva. originatesFrom: esta venta ES
    // la operación nueva de un cambio -> la venta que reemplaza.
    supabase.from("sales").select("id, sale_number").eq("replaces_sale_id", id).maybeSingle(),
    sale.replaces_sale_id
      ? supabase.from("sales").select("id, sale_number").eq("id", sale.replaces_sale_id).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);

  const productIds = Array.from(new Set((items ?? []).map((i) => i.product_id)));
  const { data: products } = productIds.length
    ? await supabase.from("products").select("id, name, sku").in("id", productIds)
    : { data: [] as { id: string; name: string; sku: string }[] };
  const productMap = new Map((products ?? []).map((p) => [p.id, p]));

  // Devoluciones (sección 38 del pedido): NUNCA reemplazan/ocultan la venta
  // original en pantalla — se listan aparte, como un evento más de su
  // historial. Mismo patrón manual de joins que el resto de esta página (sin
  // embedding de PostgREST), consulta por consulta.
  const { data: returns } = await supabase
    .from("sale_returns")
    .select("*")
    .eq("original_sale_id", id)
    .order("created_at");
  const returnIds = (returns ?? []).map((r) => r.id);
  const { data: returnItems } = returnIds.length
    ? await supabase.from("sale_return_items").select("*").in("return_id", returnIds)
    : { data: [] as { return_id: string; product_id: string; quantity: string; unit_price_refunded: string; line_refund_total: string }[] };
  const returnItemsByReturn = new Map<string, typeof returnItems>();
  for (const ri of returnItems ?? []) {
    const list = returnItemsByReturn.get(ri.return_id) ?? [];
    list.push(ri);
    returnItemsByReturn.set(ri.return_id, list);
  }
  const returnAccountIds = Array.from(new Set((returns ?? []).flatMap((r) => (r.payment_account_id ? [r.payment_account_id] : []))));
  const { data: returnAccounts } = returnAccountIds.length
    ? await supabase.from("payment_accounts").select("id, name").in("id", returnAccountIds)
    : { data: [] as { id: string; name: string }[] };
  const returnAccountMap = new Map((returnAccounts ?? []).map((a) => [a.id, a.name]));
  const returnCreatorIds = Array.from(new Set((returns ?? []).map((r) => r.created_by)));
  const { data: returnCreators } = returnCreatorIds.length
    ? await supabase.from("profiles").select("id, full_name").in("id", returnCreatorIds)
    : { data: [] as { id: string; full_name: string }[] };
  const returnCreatorMap = new Map((returnCreators ?? []).map((p) => [p.id, p.full_name]));

  const returnsForView = (returns ?? []).map((r) => ({
    id: r.id,
    refund_amount: r.refund_amount,
    refund_method: r.refund_method,
    payment_account_name: r.payment_account_id ? (returnAccountMap.get(r.payment_account_id) ?? null) : null,
    notes: r.notes,
    created_at: r.created_at,
    created_by_name: returnCreatorMap.get(r.created_by) ?? null,
    items: (returnItemsByReturn.get(r.id) ?? []).map((ri) => ({
      product_name: productMap.get(ri.product_id)?.name ?? ri.product_id,
      quantity: ri.quantity,
      unit_price_refunded: ri.unit_price_refunded,
      line_refund_total: ri.line_refund_total,
    })),
  }));

  return (
    <SaleDetailView
      sale={sale}
      items={(items ?? []).map((i) => ({ ...i, product: productMap.get(i.product_id) }))}
      location={location}
      channel={channel}
      seller={seller}
      customer={customer}
      doctor={doctor}
      paymentMethod={paymentMethod}
      paymentAccount={paymentAccount}
      condition={condition}
      cancelledByName={cancelledBy?.full_name}
      movements={movements ?? []}
      replacedBy={replacedBy}
      replacesOriginal={replacesOriginal}
      returns={returnsForView}
      // Admin y vendedora pueden anular (sección 16 del pedido) — el backend
      // (cancel_sale) es la fuente final de verdad: valida usuario activo y
      // acceso a la sede de la venta, esto solo decide si se muestra el botón.
      canCancel={profile.role === "admin" || profile.role === "seller"}
    />
  );
}
