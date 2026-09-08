import type { Metadata } from "next";

import { createClient } from "@/lib/supabase/server";
import { PromotionsTable } from "@/components/admin/promotions-table";
import { PromotionsTabs } from "@/components/admin/promotions-tabs";
import { PromotionPerformanceView } from "@/components/admin/promotion-performance-view";
import { todayInBuenosAires } from "@/lib/utils";
import type { PromotionPerformanceReport } from "@/types/database";

export const metadata: Metadata = { title: "Promociones" };

export default async function AdminPromotionsPage(props: PageProps<"/admin/promociones">) {
  const searchParams = await props.searchParams;
  const supabase = await createClient();

  const to = typeof searchParams.to === "string" ? searchParams.to : todayInBuenosAires();
  const from =
    typeof searchParams.from === "string"
      ? searchParams.from
      : (() => {
          const d = new Date();
          d.setDate(d.getDate() - 29);
          return d.toISOString().slice(0, 10);
        })();

  const [
    { data: promotions },
    { data: promotionProducts },
    { data: promotionPaymentMethods },
    { data: products },
    { data: priceConditions },
    { data: paymentMethods },
    { data: performance },
  ] = await Promise.all([
    supabase
      .from("promotions")
      .select(
        "id, code, name, type, price_condition_id, discount_percent, group_size, minimum_quantity, priority, stackable, active, valid_from, valid_until, notes"
      )
      .order("priority"),
    supabase.from("promotion_products").select("promotion_id, product_id"),
    // [] para una promoción = sin restricción configurada todavía (legacy,
    // admite cualquier medio activo) — ver 20260201000063_promotion_payment_methods.sql.
    supabase.from("promotion_payment_methods").select("promotion_id, payment_method_id"),
    supabase.from("products").select("id, sku, name, product_type").eq("active", true).order("name"),
    supabase.from("price_conditions").select("id, name").eq("active", true).order("priority"),
    supabase.from("payment_methods").select("id, code, name").eq("active", true).order("sort_order"),
    // Bloque C de Analytics: rendimiento histórico — nunca filtra por
    // promotions.active, así que una promoción desactivada o vencida sigue
    // apareciendo acá si tuvo ventas en el rango consultado.
    supabase.rpc("promotion_performance_report", { p_from: from, p_to: to }),
  ]);

  const productsByPromotion = new Map<string, string[]>();
  for (const pp of promotionProducts ?? []) {
    const list = productsByPromotion.get(pp.promotion_id) ?? [];
    list.push(pp.product_id);
    productsByPromotion.set(pp.promotion_id, list);
  }

  const paymentMethodsByPromotion = new Map<string, string[]>();
  for (const ppm of promotionPaymentMethods ?? []) {
    const list = paymentMethodsByPromotion.get(ppm.promotion_id) ?? [];
    list.push(ppm.payment_method_id);
    paymentMethodsByPromotion.set(ppm.promotion_id, list);
  }

  const performanceReport = performance as PromotionPerformanceReport | null;

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-muted-foreground">
        Cada promoción calcula su descuento sobre SU PROPIA condición de precio base — nunca sobre
        la que haya resuelto el medio de pago del carrito. Una venta con promoción usa
        exclusivamente el precio de la promoción: no se combina con transferencia, efectivo, cuotas
        ni ningún otro descuento. Un producto pertenece a lo sumo a una promoción activa a la vez.
        Si una promoción no combinable matchea el carrito, gana ella sola; si no, se aplican todas
        las combinables que matcheen. &ldquo;Medios de pago&rdquo; restringe con qué formas de pago se puede
        confirmar una venta presencial (Sede 25 / Sede 37) con esa promoción aplicada — las Ventas
        Web no se restringen por esta configuración.
      </p>
      <PromotionsTabs
        promotionsPanel={
          <PromotionsTable
            promotions={(promotions ?? []).map((p) => ({
              ...p,
              productIds: productsByPromotion.get(p.id) ?? [],
              paymentMethodIds: paymentMethodsByPromotion.get(p.id) ?? [],
            }))}
            products={products ?? []}
            priceConditions={priceConditions ?? []}
            paymentMethods={paymentMethods ?? []}
          />
        }
        performancePanel={
          <PromotionPerformanceView
            rows={performanceReport?.rows ?? []}
            promotionsMeta={(promotions ?? []).map((p) => ({
              id: p.id,
              active: p.active,
              valid_from: p.valid_from,
              valid_until: p.valid_until,
            }))}
            from={from}
            to={to}
          />
        }
      />
    </div>
  );
}
