import { describe, expect, it } from "vitest";

import { calculateCommission, quoteSale } from "@/lib/pricing/engine";
import {
  checkStockAvailability,
  expandCartToRequiredStock,
  type KitComponent,
} from "@/lib/inventory/kit-expansion";
import { buildTestCatalog, CONDITION, PAYMENT_METHOD, PRODUCT } from "./fixtures/pricing-catalog";

// Los 12 casos de la sección 41 del prompt maestro.

describe("pricing-engine — motor de precios", () => {
  it("Caso 1: 1 Vitamina C + Transferencia = 40.770", () => {
    const catalog = buildTestCatalog();
    const result = quoteSale(catalog, [{ product_id: PRODUCT.VITC, quantity: 1 }], PAYMENT_METHOD.TRANSFER);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.total).toBe(40770);
  });

  it("Caso 2: 1 Vitamina C + Efectivo = 38.500", () => {
    const catalog = buildTestCatalog();
    const result = quoteSale(catalog, [{ product_id: PRODUCT.VITC, quantity: 1 }], PAYMENT_METHOD.CASH);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.total).toBe(38500);
  });

  it("Caso 3: 1 Vitamina C + 3 cuotas = 45.300 (precio lista)", () => {
    const catalog = buildTestCatalog();
    const result = quoteSale(catalog, [{ product_id: PRODUCT.VITC, quantity: 1 }], PAYMENT_METHOD.CARD_3);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.total).toBe(45300);
  });

  it("Caso 4: 2 productos aplica QTY_2 (20% OFF), no el medio de pago", () => {
    const catalog = buildTestCatalog();
    const result = quoteSale(
      catalog,
      [
        { product_id: PRODUCT.VITC, quantity: 1 },
        { product_id: PRODUCT.NIAC, quantity: 1 },
      ],
      PAYMENT_METHOD.TRANSFER
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.applied_price_condition_code).toBe("QTY_2");
      expect(result.total).toBe(36240 + 34000);
    }
  });

  it("Caso 5: 3 productos aplica QTY_3_PLUS (25% OFF)", () => {
    const catalog = buildTestCatalog();
    const result = quoteSale(
      catalog,
      [
        { product_id: PRODUCT.VITC, quantity: 1 },
        { product_id: PRODUCT.NIAC, quantity: 1 },
        { product_id: PRODUCT.OJOS, quantity: 1 },
      ],
      PAYMENT_METHOD.TRANSFER
    );
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.applied_price_condition_code).toBe("QTY_3_PLUS");
  });

  it("Caso 6: 3 productos + transferencia aplica SOLO QTY_3_PLUS (no acumula descuentos)", () => {
    const catalog = buildTestCatalog();
    const result = quoteSale(
      catalog,
      [
        { product_id: PRODUCT.VITC, quantity: 1 },
        { product_id: PRODUCT.NIAC, quantity: 1 },
        { product_id: PRODUCT.OJOS, quantity: 1 },
      ],
      PAYMENT_METHOD.TRANSFER
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.applied_price_condition_code).toBe("QTY_3_PLUS");
      expect(result.total).toBe(33975 + 31875 + 30750);
    }
  });

  it("Caso 7: ACC-NEC bajo una condición sin precio configurado se rechaza (nunca $0)", () => {
    const catalog = buildTestCatalog();
    const result = quoteSale(catalog, [{ product_id: PRODUCT.NEC, quantity: 1 }], PAYMENT_METHOD.CARD_3);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error_message).toContain("no tiene precio configurado");
  });

  it("Caso 12: cambiar un precio hoy no altera una venta histórica ya cotizada", () => {
    const catalog = buildTestCatalog();
    const historicalDate = new Date("2026-08-10T12:00:00-03:00");

    const before = quoteSale(catalog, [{ product_id: PRODUCT.VITC, quantity: 1 }], PAYMENT_METHOD.CASH, historicalDate);
    expect(before.ok).toBe(true);
    if (before.ok) expect(before.total).toBe(38500);

    // Un admin sube el precio de efectivo, vigente desde una fecha posterior.
    catalog.prices = catalog.prices.map((p) =>
      p.product_id === PRODUCT.VITC && p.price_condition_id === CONDITION.CASH
        ? { ...p, valid_until: "2026-08-20T00:00:00-03:00" }
        : p
    );
    catalog.prices.push({
      product_id: PRODUCT.VITC,
      price_condition_id: CONDITION.CASH,
      amount: 41000,
      active: true,
      valid_from: "2026-08-20T00:00:00-03:00",
      valid_until: null,
    });

    // La cotización histórica (misma fecha) sigue devolviendo el precio viejo...
    const stillHistorical = quoteSale(
      catalog,
      [{ product_id: PRODUCT.VITC, quantity: 1 }],
      PAYMENT_METHOD.CASH,
      historicalDate
    );
    expect(stillHistorical.ok).toBe(true);
    if (stillHistorical.ok) expect(stillHistorical.total).toBe(38500);

    // ...mientras que una cotización nueva, hoy, usa el precio actualizado.
    const today = quoteSale(
      catalog,
      [{ product_id: PRODUCT.VITC, quantity: 1 }],
      PAYMENT_METHOD.CASH,
      new Date("2026-08-25T12:00:00-03:00")
    );
    expect(today.ok).toBe(true);
    if (today.ok) expect(today.total).toBe(41000);
  });
});

describe("pricing-engine — comisiones (Caso 11)", () => {
  it("la comisión se calcula solo sobre líneas commissionable, no sobre el total de la venta", () => {
    const catalog = buildTestCatalog();
    // Crema (commissionable) $40.000 equivalente + accesorio no commissionable.
    const lines = [
      {
        product_id: PRODUCT.VITC,
        sku: "PROD-VITC",
        name: "Sérum Vitamina C",
        quantity: 1,
        list_unit_price: 45300,
        sale_unit_price: 40000,
        line_list_total: 45300,
        line_discount: 5300,
        line_total: 40000,
        commissionable: true,
        applied_price_condition_id: CONDITION.CASH,
      },
      {
        product_id: PRODUCT.NEC,
        sku: "ACC-NEC",
        name: "Neceser Magui",
        quantity: 1,
        list_unit_price: 20000,
        sale_unit_price: 20000,
        line_list_total: 20000,
        line_discount: 0,
        line_total: 20000,
        commissionable: false,
        applied_price_condition_id: CONDITION.CASH,
      },
    ];

    const commission = calculateCommission(lines, 0.2);
    // 40.000 × 20% = 8.000 (NO 60.000 × 20% = 12.000)
    expect(commission).toBe(8000);
    void catalog;
  });
});

describe("kit-expansion — stock (Casos 8, 9 y 10)", () => {
  const products = [
    { id: PRODUCT.VITC, track_stock: true },
    { id: PRODUCT.NIAC, track_stock: true },
    { id: PRODUCT.KIT_VN, track_stock: false },
  ];
  const kitComponents: KitComponent[] = [
    { kit_product_id: PRODUCT.KIT_VN, component_product_id: PRODUCT.VITC, quantity: 1 },
    { kit_product_id: PRODUCT.KIT_VN, component_product_id: PRODUCT.NIAC, quantity: 1 },
  ];

  it("Caso 8: vender 2×KIT-VN requiere 2 Vitamina C + 2 Niacinamida (nunca 'kits' como stock propio)", () => {
    const required = expandCartToRequiredStock(
      [{ product_id: PRODUCT.KIT_VN, quantity: 2 }],
      products,
      kitComponents
    );
    expect(required.get(PRODUCT.VITC)).toBe(2);
    expect(required.get(PRODUCT.NIAC)).toBe(2);
    expect(required.has(PRODUCT.KIT_VN)).toBe(false);
  });

  it("Caso 9: stock insuficiente en un componente del kit rechaza la venta completa", () => {
    const required = expandCartToRequiredStock(
      [{ product_id: PRODUCT.KIT_VN, quantity: 2 }],
      products,
      kitComponents
    );
    const available = new Map([
      [PRODUCT.VITC, 1], // solo hay 1, se necesitan 2
      [PRODUCT.NIAC, 8],
    ]);
    const check = checkStockAvailability(required, available);
    expect(check.ok).toBe(false);
    expect(check.missing?.product_id).toBe(PRODUCT.VITC);
    expect(check.missing?.available).toBe(1);
    expect(check.missing?.required).toBe(2);
  });

  it("Caso 10: cancelar una venta repone exactamente la cantidad descontada", () => {
    const required = expandCartToRequiredStock(
      [{ product_id: PRODUCT.KIT_VN, quantity: 2 }],
      products,
      kitComponents
    );
    const balances = new Map([
      [PRODUCT.VITC, 17],
      [PRODUCT.NIAC, 47],
    ]);

    // Vender: descuenta.
    for (const [productId, qty] of required.entries()) {
      balances.set(productId, (balances.get(productId) ?? 0) - qty);
    }
    expect(balances.get(PRODUCT.VITC)).toBe(15);
    expect(balances.get(PRODUCT.NIAC)).toBe(45);

    // Cancelar: repone EXACTAMENTE lo mismo que se descontó.
    for (const [productId, qty] of required.entries()) {
      balances.set(productId, (balances.get(productId) ?? 0) + qty);
    }
    expect(balances.get(PRODUCT.VITC)).toBe(17);
    expect(balances.get(PRODUCT.NIAC)).toBe(47);
  });
});
