import { describe, expect, it } from "vitest";

import { shouldShowTransferAlias } from "@/lib/sales/payment-account-alias";

const mercadoPago = { name: "Mercado Pago", alias: "maguirejuve.mp" };
const bancoGalicia = { name: "Banco Galicia", alias: "maguirejuve.galicia" };
const sinAlias = { name: "Banco Nación", alias: null };

describe("shouldShowTransferAlias", () => {
  it("Caso 1: Transferencia + Mercado Pago con alias -> alias visible", () => {
    expect(
      shouldShowTransferAlias({ isFreeSale: false, paymentMethodCode: "TRANSFER", account: mercadoPago })
    ).toBe(true);
  });

  it("Caso 2: Transferencia + Banco Galicia con alias -> alias visible (genérico, no hardcodeado a Mercado Pago)", () => {
    expect(
      shouldShowTransferAlias({ isFreeSale: false, paymentMethodCode: "TRANSFER", account: bancoGalicia })
    ).toBe(true);
  });

  it("Caso 3: Transferencia + cuenta sin alias -> no se muestra el bloque", () => {
    expect(
      shouldShowTransferAlias({ isFreeSale: false, paymentMethodCode: "TRANSFER", account: sinAlias })
    ).toBe(false);
  });

  it("Caso 4: Efectivo + cuenta con alias -> nunca se muestra el alias", () => {
    expect(
      shouldShowTransferAlias({ isFreeSale: false, paymentMethodCode: "CASH", account: mercadoPago })
    ).toBe(false);
  });

  it("Caso 5: 1 pago crédito -> no se muestra el alias, aunque la cuenta sea obligatoria para esa forma de pago", () => {
    expect(
      shouldShowTransferAlias({ isFreeSale: false, paymentMethodCode: "CARD_1", account: mercadoPago })
    ).toBe(false);
  });

  it("Caso 6: 3 cuotas -> no se muestra el alias", () => {
    expect(
      shouldShowTransferAlias({ isFreeSale: false, paymentMethodCode: "CARD_3", account: mercadoPago })
    ).toBe(false);
  });

  it("Caso 7: cambiar de cuenta actualiza el alias de inmediato (función pura, sin estado que quede viejo)", () => {
    const params = (account: typeof mercadoPago | typeof bancoGalicia) =>
      ({ isFreeSale: false, paymentMethodCode: "TRANSFER", account }) as const;

    expect(shouldShowTransferAlias(params(mercadoPago))).toBe(true);
    // Mismo carrito, la vendedora cambia de cuenta -> se re-evalúa con la
    // cuenta nueva, nunca queda pegado el alias de la anterior.
    expect(shouldShowTransferAlias(params(bancoGalicia))).toBe(true);
  });

  it("venta sin costo nunca muestra alias, aunque el medio fuera Transferencia", () => {
    expect(
      shouldShowTransferAlias({ isFreeSale: true, paymentMethodCode: "TRANSFER", account: mercadoPago })
    ).toBe(false);
  });

  it("sin cuenta seleccionada todavía (undefined) no se muestra nada", () => {
    expect(
      shouldShowTransferAlias({ isFreeSale: false, paymentMethodCode: "TRANSFER", account: undefined })
    ).toBe(false);
  });

  it("un alias con string vacío se trata igual que sin alias", () => {
    expect(
      shouldShowTransferAlias({
        isFreeSale: false,
        paymentMethodCode: "TRANSFER",
        account: { name: "Cuenta rara", alias: "" },
      })
    ).toBe(false);
  });
});
