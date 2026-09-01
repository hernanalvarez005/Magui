"use client";

import { useMemo, useState } from "react";
import { Search } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { EmptyState } from "@/components/shared/empty-state";
import { cn, formatCurrency, formatDate } from "@/lib/utils";
import type { PromotionType } from "@/types/database";

interface ProductLite {
  id: string;
  sku: string;
  name: string;
  product_type: string;
}
interface PriceConditionLite {
  id: string;
  code: string;
  name: string;
}
interface ProductPriceLite {
  product_id: string;
  price_condition_id: string;
  amount: string;
}
interface PromotionLite {
  id: string;
  code: string;
  name: string;
  type: PromotionType;
  price_condition_id: string;
  discount_percent: string | null;
  group_size: number;
  valid_from: string;
  valid_until: string | null;
}
interface PromotionProductLite {
  promotion_id: string;
  product_id: string;
}

// Mismo orden/columnas que la sección 6 del pedido. Ver comentario en
// page.tsx sobre por qué son estas 5 y no las 6 que muestra Administración.
const DISPLAY_CODES = ["LIST", "CASH", "TRANSFER", "CARD_1", "INSTALLMENTS_3"];
const CONDITION_LABELS: Record<string, string> = {
  LIST: "Lista",
  CASH: "Efectivo",
  TRANSFER: "Transferencia",
  CARD_1: "1 pago",
  INSTALLMENTS_3: "3 cuotas",
};
const TYPE_LABEL: Record<string, string> = { product: "Producto", kit: "Kit", accessory: "Accesorio" };
const PROMO_TYPE_LABEL: Record<PromotionType, string> = {
  THREE_FOR_TWO: "3x2",
  DUO_PERCENT: "Dúo %",
  KIT_PERCENT: "% OFF",
};

function pct(discount: string | null) {
  return discount ? `${Math.round(Number(discount) * 100)}%` : "";
}

interface PromoInfo {
  badge: string;
  priceLine: string | null;
  extraLine: string | null;
}

// Reutiliza EXACTAMENTE la misma fórmula que fn_apply_promotions (Bloque de
// promociones) para el precio con descuento: base bajo la condición propia
// de la promoción × (1 − %), redondeado a 2 decimales — no es una segunda
// implementación, es el mismo cálculo hecho una vez más porque acá no hay
// un carrito real para pasarle al motor (sección 9 del pedido). Para 3x2
// nunca se inventa un precio unitario (sección 10) — la promoción se
// muestra como "3x2", nunca como un % equivalente.
function buildPromoInfo(promo: PromotionLite, product: ProductLite, participants: ProductLite[], basePrice: string | undefined): PromoInfo {
  if (promo.type === "THREE_FOR_TWO") {
    const names = participants.map((p) => p.name).join(", ");
    return {
      badge: "3x2",
      priceLine: null,
      extraLine: `1 de cada ${promo.group_size} unidades sale gratis (la más económica). Participan: ${names}.`,
    };
  }

  const discountPct = pct(promo.discount_percent);
  const promoAmount =
    basePrice && promo.discount_percent
      ? Math.round(Number(basePrice) * (1 - Number(promo.discount_percent)) * 100) / 100
      : null;
  const promoAmountLabel = promoAmount !== null ? formatCurrency(promoAmount) : "Sin configurar";

  if (promo.type === "DUO_PERCENT") {
    const partner = participants.find((p) => p.id !== product.id);
    return {
      badge: `Dúo ${discountPct} OFF`,
      priceLine: `Precio promo: ${promoAmountLabel}${partner ? ` (al comprar junto con ${partner.name})` : ""}`,
      extraLine: null,
    };
  }

  // KIT_PERCENT: el % se aplica a toda la cantidad, sin depender de qué más
  // haya en el carrito — es seguro mostrar un precio unitario fijo.
  return {
    badge: `${discountPct} OFF`,
    priceLine: `Precio promo: ${promoAmountLabel}`,
    extraLine: null,
  };
}

export function PreciosView({
  products,
  priceConditions,
  productPrices,
  promotions,
  promotionProducts,
}: {
  products: ProductLite[];
  priceConditions: PriceConditionLite[];
  productPrices: ProductPriceLite[];
  promotions: PromotionLite[];
  promotionProducts: PromotionProductLite[];
}) {
  const [search, setSearch] = useState("");

  const productById = useMemo(() => new Map(products.map((p) => [p.id, p])), [products]);
  const conditionNameById = useMemo(() => new Map(priceConditions.map((c) => [c.id, c.name])), [priceConditions]);

  const priceByProductAndCondition = useMemo(() => {
    const map = new Map<string, string>();
    for (const pp of productPrices) map.set(`${pp.product_id}|${pp.price_condition_id}`, pp.amount);
    return map;
  }, [productPrices]);

  const orderedDisplayConditions = useMemo(
    () =>
      DISPLAY_CODES.map((code) => priceConditions.find((c) => c.code === code)).filter(
        (c): c is PriceConditionLite => !!c
      ),
    [priceConditions]
  );

  const participantsByPromotion = useMemo(() => {
    const map = new Map<string, ProductLite[]>();
    for (const pp of promotionProducts) {
      const product = productById.get(pp.product_id);
      if (!product) continue;
      const list = map.get(pp.promotion_id) ?? [];
      list.push(product);
      map.set(pp.promotion_id, list);
    }
    return map;
  }, [promotionProducts, productById]);

  // Un producto pertenece a lo sumo UNA promoción activa a la vez — ya lo
  // garantiza un constraint en la base (fn_check_promotion_product_exclusive).
  // No hace falta elegir una "promoción ganadora" acá (sección 12 del pedido).
  const promotionByProductId = useMemo(() => {
    const map = new Map<string, PromotionLite>();
    for (const promo of promotions) {
      for (const product of participantsByPromotion.get(promo.id) ?? []) {
        map.set(product.id, promo);
      }
    }
    return map;
  }, [promotions, participantsByPromotion]);

  // Sin backend/debounce: el catálogo completo ya está en memoria (mismo
  // criterio que el buscador de Nueva Venta) — filtrar acá es instantáneo
  // y evita una consulta por tecla (secciones 5 y 19 del pedido).
  const filteredProducts = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return products;
    return products.filter((p) => p.name.toLowerCase().includes(q) || p.sku.toLowerCase().includes(q));
  }, [products, search]);

  return (
    <div className="flex flex-col gap-6">
      <div className="relative">
        <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
        <Input
          placeholder="Buscar producto o kit…"
          className="pl-9"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
      </div>

      <div className="flex flex-col gap-3">
        {filteredProducts.length === 0 ? (
          <EmptyState title="No encontramos productos que coincidan con tu búsqueda." />
        ) : (
          filteredProducts.map((p) => {
            const promotion = promotionByProductId.get(p.id) ?? null;
            const participants = promotion ? participantsByPromotion.get(promotion.id) ?? [] : [];
            const basePrice = promotion
              ? priceByProductAndCondition.get(`${p.id}|${promotion.price_condition_id}`)
              : undefined;
            const promoInfo = promotion ? buildPromoInfo(promotion, p, participants, basePrice) : null;

            return (
              <div key={p.id} className="rounded-xl border border-border bg-card p-4">
                <div className="flex items-start justify-between gap-2">
                  <div>
                    <p className="font-medium">{p.name}</p>
                    <p className="text-xs text-muted-foreground">{p.sku}</p>
                  </div>
                  <Badge variant="outline">{TYPE_LABEL[p.product_type] ?? p.product_type}</Badge>
                </div>

                <div className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 text-sm sm:grid-cols-5">
                  {orderedDisplayConditions.map((c) => {
                    const amount = priceByProductAndCondition.get(`${p.id}|${c.id}`);
                    return (
                      <div key={c.id} className="flex flex-col">
                        <span className="text-xs text-muted-foreground">{CONDITION_LABELS[c.code] ?? c.name}</span>
                        <span className={cn("font-medium tabular-nums", !amount && "text-xs font-normal text-muted-foreground")}>
                          {amount ? formatCurrency(amount) : "Sin configurar"}
                        </span>
                      </div>
                    );
                  })}
                </div>

                {promotion && promoInfo ? (
                  <div className="mt-3 flex flex-col gap-1 rounded-lg border border-primary/30 bg-primary/5 p-3">
                    <div className="flex flex-wrap items-center gap-2">
                      <Badge>EN PROMO · {promoInfo.badge}</Badge>
                      <span className="text-sm font-medium">{promotion.name}</span>
                    </div>
                    <p className="text-xs text-muted-foreground">
                      Base: {conditionNameById.get(promotion.price_condition_id) ?? "—"}
                      {promotion.valid_until ? ` · vigente hasta ${formatDate(promotion.valid_until)}` : ""}
                    </p>
                    {promoInfo.priceLine ? <p className="text-sm">{promoInfo.priceLine}</p> : null}
                    {promoInfo.extraLine ? <p className="text-xs text-muted-foreground">{promoInfo.extraLine}</p> : null}
                    <p className="text-xs text-muted-foreground">Promoción no acumulable con otros descuentos.</p>
                  </div>
                ) : null}
              </div>
            );
          })
        )}
      </div>

      <div className="flex flex-col gap-3">
        <h2 className="text-base font-semibold">Promociones vigentes</h2>
        {promotions.length === 0 ? (
          <EmptyState title="No hay promociones vigentes en este momento." />
        ) : (
          <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
            {promotions.map((promo) => {
              const participants = participantsByPromotion.get(promo.id) ?? [];
              const benefit = promo.type === "THREE_FOR_TWO" ? "3x2" : `${pct(promo.discount_percent)} OFF`;
              return (
                <div key={promo.id} className="rounded-xl border border-border bg-card p-4">
                  <div className="flex items-center justify-between gap-2">
                    <p className="font-medium">{promo.name}</p>
                    <Badge>{benefit}</Badge>
                  </div>
                  <p className="text-xs text-muted-foreground">
                    {PROMO_TYPE_LABEL[promo.type]} · Base: {conditionNameById.get(promo.price_condition_id) ?? "—"}
                  </p>
                  <p className="mt-1 text-xs text-muted-foreground">
                    Vigencia: {formatDate(promo.valid_from)} — {promo.valid_until ? formatDate(promo.valid_until) : "sin fin"}
                  </p>
                  <p className="mt-2 text-sm">Incluye: {participants.map((p) => p.name).join(", ") || "—"}</p>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}
