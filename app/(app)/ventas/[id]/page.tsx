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
    { data: condition },
    { data: cancelledBy },
    { data: movements },
  ] = await Promise.all([
    supabase.from("sale_items").select("*").eq("sale_id", id),
    supabase.from("stock_locations").select("code, name").eq("id", sale.location_id).single(),
    supabase.from("sales_channels").select("name").eq("id", sale.sales_channel_id).single(),
    supabase.from("profiles").select("full_name").eq("id", sale.seller_id).single(),
    sale.customer_id
      ? supabase.from("customers").select("full_name, dni, whatsapp").eq("id", sale.customer_id).maybeSingle()
      : Promise.resolve({ data: null }),
    sale.doctor_id
      ? supabase.from("doctors").select("full_name, commission_percent").eq("id", sale.doctor_id).maybeSingle()
      : Promise.resolve({ data: null }),
    supabase.from("payment_methods").select("name").eq("id", sale.payment_method_id).single(),
    sale.applied_price_condition_id
      ? supabase.from("price_conditions").select("name").eq("id", sale.applied_price_condition_id).maybeSingle()
      : Promise.resolve({ data: null }),
    sale.cancelled_by
      ? supabase.from("profiles").select("full_name").eq("id", sale.cancelled_by).maybeSingle()
      : Promise.resolve({ data: null }),
    supabase.from("stock_movements").select("*").eq("sale_id", id).order("occurred_at"),
  ]);

  const productIds = Array.from(new Set((items ?? []).map((i) => i.product_id)));
  const { data: products } = productIds.length
    ? await supabase.from("products").select("id, name, sku").in("id", productIds)
    : { data: [] as { id: string; name: string; sku: string }[] };
  const productMap = new Map((products ?? []).map((p) => [p.id, p]));

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
      condition={condition}
      cancelledByName={cancelledBy?.full_name}
      movements={movements ?? []}
      canCancel={profile.role === "admin"}
    />
  );
}
