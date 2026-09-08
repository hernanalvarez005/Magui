import { describe, expect, it } from "vitest";

import { computeAllowedPaymentMethodIds, mapToLookup } from "@/lib/sales/promotion-payment-methods";

// Formas de pago habilitadas por promoción (migración 63) — reglas puras de
// Nueva Venta. El backend (fn_create_sale_core) sigue siendo la autoridad
// real; esto solo replica su misma lógica de intersección para poder avisar
// antes de confirmar.

describe("computeAllowedPaymentMethodIds", () => {
  it("sin ninguna promoción ganadora, no hay restricción (null)", () => {
    const lookup = mapToLookup(new Map());
    expect(computeAllowedPaymentMethodIds([], lookup)).toBeNull();
    expect(computeAllowedPaymentMethodIds([null, undefined], lookup)).toBeNull();
  });

  it("una promoción con medios configurados restringe a exactamente esos", () => {
    const lookup = mapToLookup(new Map([["promo-a", ["cash", "transfer"]]]));
    expect(computeAllowedPaymentMethodIds(["promo-a"], lookup)).toEqual(["cash", "transfer"]);
  });

  it("promoción legacy (sin filas configuradas) no restringe nada", () => {
    const lookup = mapToLookup(new Map()); // promo-legacy ausente del mapa
    expect(computeAllowedPaymentMethodIds(["promo-legacy"], lookup)).toBeNull();
  });

  it("promoción legacy con array vacío explícito tampoco restringe", () => {
    const lookup = mapToLookup(new Map([["promo-legacy", []]]));
    expect(computeAllowedPaymentMethodIds(["promo-legacy"], lookup)).toBeNull();
  });

  it("dos promociones con intersección: solo el medio en común queda permitido", () => {
    const lookup = mapToLookup(
      new Map([
        ["promo-a", ["cash", "transfer"]],
        ["promo-b", ["transfer"]],
      ])
    );
    // Simula 2 líneas del quote, cada una con su applied_promotion_id.
    expect(computeAllowedPaymentMethodIds(["promo-a", "promo-b"], lookup)).toEqual(["transfer"]);
  });

  it("dos promociones sin intersección: array vacío (ningún medio confirma la venta)", () => {
    const lookup = mapToLookup(
      new Map([
        ["promo-cash", ["cash"]],
        ["promo-transfer", ["transfer"]],
      ])
    );
    expect(computeAllowedPaymentMethodIds(["promo-cash", "promo-transfer"], lookup)).toEqual([]);
  });

  it("promoción restringida + promoción legacy en el mismo carrito: la legacy no amplía ni reduce la intersección", () => {
    const lookup = mapToLookup(new Map([["promo-a", ["cash", "transfer"]]])); // promo-legacy ausente
    expect(computeAllowedPaymentMethodIds(["promo-a", "promo-legacy"], lookup)).toEqual(["cash", "transfer"]);
  });

  it("un mismo promotion_id repetido en varias líneas del carrito no se cuenta dos veces", () => {
    const lookup = mapToLookup(new Map([["promo-a", ["cash"]]]));
    expect(computeAllowedPaymentMethodIds(["promo-a", "promo-a", "promo-a"], lookup)).toEqual(["cash"]);
  });
});
