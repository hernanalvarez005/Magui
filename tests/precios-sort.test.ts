import { describe, expect, it } from "vitest";

import { sortPromoFirst } from "@/lib/precios-sort";

describe("sortPromoFirst", () => {
  it("pone primero los productos EN PROMO, preservando el orden dentro de cada grupo", () => {
    const products = [
      { id: "a", name: "Kit A" }, // en promo
      { id: "b", name: "Kit B" }, // normal
      { id: "c", name: "Kit C" }, // en promo
      { id: "d", name: "Kit D" }, // normal
    ];
    const promoIds = new Set(["a", "c"]);

    expect(sortPromoFirst(products, promoIds).map((p) => p.id)).toEqual(["a", "c", "b", "d"]);
  });

  it("con display_order ya resuelto en el array de entrada, lo respeta dentro de cada grupo (no lo reordena de nuevo)", () => {
    // display_order ya vino resuelto del servidor: 30(promo), 10, 20(promo), 40.
    const products = [
      { id: "promo-30", name: "orden 30, en promo" },
      { id: "normal-10", name: "orden 10, normal" },
      { id: "promo-20", name: "orden 20, en promo" },
      { id: "normal-40", name: "orden 40, normal" },
    ];
    const promoIds = new Set(["promo-30", "promo-20"]);

    // Las EN PROMO quedan primero en el mismo orden relativo en que llegaron
    // (30 antes que 20, porque así venían) — la función nunca reordena por
    // display_order, solo agrupa; el display_order ya viene resuelto arriba.
    expect(sortPromoFirst(products, promoIds).map((p) => p.id)).toEqual([
      "promo-30",
      "promo-20",
      "normal-10",
      "normal-40",
    ]);
  });

  it("sin ningún producto en promo, no cambia el orden", () => {
    const products = [{ id: "x" }, { id: "y" }, { id: "z" }];
    expect(sortPromoFirst(products, new Set()).map((p) => p.id)).toEqual(["x", "y", "z"]);
  });

  it("con todos los productos en promo, no cambia el orden", () => {
    const products = [{ id: "x" }, { id: "y" }, { id: "z" }];
    const promoIds = new Set(["x", "y", "z"]);
    expect(sortPromoFirst(products, promoIds).map((p) => p.id)).toEqual(["x", "y", "z"]);
  });

  it("no muta el array original", () => {
    const products = [{ id: "b" }, { id: "a" }];
    const promoIds = new Set(["a"]);
    const original = [...products];
    sortPromoFirst(products, promoIds);
    expect(products).toEqual(original);
  });

  it("simula la búsqueda conservando prioridad promo: Kit A (promo), Kit C (promo), Kit B (normal)", () => {
    // Mismo ejemplo del pedido (sección 7): busca "Kit", hay A en promo, B
    // normal, C en promo -> A, C, B.
    const allProducts = [
      { id: "kit-a", name: "Kit A" },
      { id: "kit-b", name: "Kit B" },
      { id: "kit-c", name: "Kit C" },
      { id: "sin-kit", name: "Sérum X" },
    ];
    const promoIds = new Set(["kit-a", "kit-c"]);

    const searchResults = allProducts.filter((p) => p.name.toLowerCase().includes("kit"));
    expect(sortPromoFirst(searchResults, promoIds).map((p) => p.id)).toEqual(["kit-a", "kit-c", "kit-b"]);
  });
});
