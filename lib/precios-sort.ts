/**
 * Orden visual de la pantalla /precios: productos/kits EN PROMO primero,
 * el resto después — dentro de cada grupo se preserva el orden con el que
 * llegan (display_order, ya resuelto por la query del servidor). Nunca
 * modifica products.display_order: es puramente de presentación en esta
 * pantalla (sección 5 del pedido).
 *
 * Array.prototype.sort es estable desde ES2019 — separado en su propio
 * archivo (en vez de inline en el componente) para poder testearlo sin
 * levantar todo precios-view.tsx.
 */
export function sortPromoFirst<T extends { id: string }>(items: T[], promoProductIds: ReadonlySet<string>): T[] {
  return [...items].sort((a, b) => {
    const aPromo = promoProductIds.has(a.id) ? 0 : 1;
    const bPromo = promoProductIds.has(b.id) ? 0 : 1;
    return aPromo - bPromo;
  });
}
