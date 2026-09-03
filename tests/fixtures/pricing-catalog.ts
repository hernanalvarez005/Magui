import type { PricingCatalog } from "@/lib/pricing/engine";

// Espejo mínimo del seed real (supabase/migrations/20260101000012_seed_data.sql):
// mismos códigos, mismas prioridades, mismos montos para Vitamina C / Niacinamida / ACC-NEC / KIT-VN.

export const PAYMENT_METHOD = {
  CASH: "pm-cash",
  TRANSFER: "pm-transfer",
  CARD_3: "pm-card3",
};

export const CONDITION = {
  LIST: "pc-list",
  TRANSFER: "pc-transfer",
  CASH: "pc-cash",
  INSTALLMENTS_3: "pc-installments3",
};

export const PRODUCT = {
  VITC: "prod-vitc",
  NIAC: "prod-niac",
  OJOS: "prod-ojos",
  NEC: "acc-nec",
  KIT_VN: "kit-vn",
};

export function buildTestCatalog(): PricingCatalog {
  return {
    products: [
      { id: PRODUCT.VITC, sku: "PROD-VITC", name: "Sérum Vitamina C", active: true, promo_eligible: true, commissionable: true },
      { id: PRODUCT.NIAC, sku: "PROD-NIAC", name: "Sérum de Niacinamida", active: true, promo_eligible: true, commissionable: true },
      { id: PRODUCT.OJOS, sku: "PROD-OJOS", name: "Contorno de ojos", active: true, promo_eligible: true, commissionable: true },
      { id: PRODUCT.NEC, sku: "ACC-NEC", name: "Neceser Magui", active: true, promo_eligible: true, commissionable: false },
      { id: PRODUCT.KIT_VN, sku: "KIT-VN", name: "Kit Vitamina C + Niacinamida", active: true, promo_eligible: true, commissionable: true },
    ],
    conditions: [
      { id: CONDITION.LIST, code: "LIST", name: "Precio lista", rule_type: "BASE", payment_method_id: null, discount_percent: null, priority: 6, active: true },
      { id: CONDITION.TRANSFER, code: "TRANSFER", name: "Transferencia", rule_type: "PAYMENT_METHOD", payment_method_id: PAYMENT_METHOD.TRANSFER, discount_percent: 0.1, priority: 4, active: true },
      { id: CONDITION.CASH, code: "CASH", name: "Efectivo", rule_type: "PAYMENT_METHOD", payment_method_id: PAYMENT_METHOD.CASH, discount_percent: 0.15, priority: 3, active: true },
      { id: CONDITION.INSTALLMENTS_3, code: "INSTALLMENTS_3", name: "3 cuotas sin interés", rule_type: "PAYMENT_METHOD", payment_method_id: PAYMENT_METHOD.CARD_3, discount_percent: 0, priority: 5, active: true },
    ],
    prices: [
      // PROD-VITC: 45.300 | 40.770 | 38.500 | 45.300
      price(PRODUCT.VITC, CONDITION.LIST, 45300),
      price(PRODUCT.VITC, CONDITION.TRANSFER, 40770),
      price(PRODUCT.VITC, CONDITION.CASH, 38500),
      price(PRODUCT.VITC, CONDITION.INSTALLMENTS_3, 45300),
      // PROD-NIAC: 42.500 | 38.250 | 36.100 | 42.500
      price(PRODUCT.NIAC, CONDITION.LIST, 42500),
      price(PRODUCT.NIAC, CONDITION.TRANSFER, 38250),
      price(PRODUCT.NIAC, CONDITION.CASH, 36100),
      price(PRODUCT.NIAC, CONDITION.INSTALLMENTS_3, 42500),
      // PROD-OJOS: 41.000 | 36.900 | 34.850 | 41.000
      price(PRODUCT.OJOS, CONDITION.LIST, 41000),
      price(PRODUCT.OJOS, CONDITION.TRANSFER, 36900),
      price(PRODUCT.OJOS, CONDITION.CASH, 34850),
      price(PRODUCT.OJOS, CONDITION.INSTALLMENTS_3, 41000),
      // ACC-NEC: solo Transferencia y Efectivo (catálogo incompleto en la base original)
      price(PRODUCT.NEC, CONDITION.TRANSFER, 27450),
      price(PRODUCT.NEC, CONDITION.CASH, 25900),
      // KIT-VN: 83.410 | 75.069 | 71.000 | 83.410
      price(PRODUCT.KIT_VN, CONDITION.LIST, 83410),
      price(PRODUCT.KIT_VN, CONDITION.TRANSFER, 75069),
      price(PRODUCT.KIT_VN, CONDITION.CASH, 71000),
      price(PRODUCT.KIT_VN, CONDITION.INSTALLMENTS_3, 83410),
    ],
  };
}

function price(productId: string, conditionId: string, amount: number, validFrom = "2026-08-01T00:00:00-03:00") {
  return {
    product_id: productId,
    price_condition_id: conditionId,
    amount,
    active: true,
    valid_from: validFrom,
    valid_until: null,
  };
}
