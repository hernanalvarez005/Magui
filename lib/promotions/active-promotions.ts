import type { createClient } from "@/lib/supabase/server";

type SupabaseServerClient = Awaited<ReturnType<typeof createClient>>;

/**
 * "Vigente" para promociones — fuente única de la regla, para no dejar que
 * dos pantallas (Home del vendedor, /precios) terminen escribiendo el WHERE
 * dos veces y divergiendo con el tiempo. Es EXACTAMENTE el mismo criterio
 * que ya usa fn_apply_promotions al vender: active = true AND
 * valid_from <= now AND (valid_until is null OR valid_until > now).
 *
 * Devuelve el query builder sin resolver — cada pantalla decide qué
 * columnas necesita y si además pagina/limita.
 */
export function activePromotionsQuery(supabase: SupabaseServerClient, nowIso: string = new Date().toISOString()) {
  return supabase
    .from("promotions")
    .select("id, code, name, type, price_condition_id, discount_percent, group_size, valid_from, valid_until")
    .eq("active", true)
    .lte("valid_from", nowIso)
    .or(`valid_until.is.null,valid_until.gt.${nowIso}`);
}

export interface PromotionParticipant {
  id: string;
  sku: string;
  name: string;
  product_type: string;
}

/**
 * Productos/kits participantes de un set de promociones, sin N+1: 1 query a
 * promotion_products + 1 query a products (solo los ids que realmente
 * participan, nunca el catálogo completo) — 2 queries totales sin importar
 * cuántas promociones haya. Compatible con selección múltiple (una
 * promoción puede tener 1 o varios productos/kits asociados).
 *
 * /precios ya tiene el catálogo completo cargado para el buscador, así que
 * ahí sale más barato resolver participantes contra ese mismo array en
 * memoria en vez de pedir productos una segunda vez — este helper es para
 * pantallas (como la Home) que NO necesitan el catálogo completo.
 */
export async function resolvePromotionParticipants(
  supabase: SupabaseServerClient,
  promotionIds: string[]
): Promise<Map<string, PromotionParticipant[]>> {
  const map = new Map<string, PromotionParticipant[]>();
  if (promotionIds.length === 0) return map;

  const { data: promotionProducts } = await supabase
    .from("promotion_products")
    .select("promotion_id, product_id")
    .in("promotion_id", promotionIds);

  const productIds = Array.from(new Set((promotionProducts ?? []).map((pp) => pp.product_id)));
  const { data: products } = productIds.length
    ? await supabase.from("products").select("id, sku, name, product_type").in("id", productIds)
    : { data: [] as PromotionParticipant[] };

  const productById = new Map((products ?? []).map((p) => [p.id, p]));
  for (const pp of promotionProducts ?? []) {
    const product = productById.get(pp.product_id);
    if (!product) continue;
    const list = map.get(pp.promotion_id) ?? [];
    list.push(product);
    map.set(pp.promotion_id, list);
  }

  return map;
}
