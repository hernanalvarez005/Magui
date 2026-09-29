import { describe, expect, it } from "vitest";
import { Banknote, CircleDollarSign, CreditCard, Landmark } from "lucide-react";

import { resolvePaymentMethodIcon } from "@/lib/pricing/payment-method-icon";

// Ajuste visual: /precios y /admin/condiciones-precio ya eran data-driven
// (Checkpoint Final, Hallazgo C y el fix de DISPLAY_CODES) — pero el
// selector de ícono de Nueva Venta seguía cayendo en Banknote para
// cualquier code no reconocido, incluida "2 cuotas sin interés" (code
// autogenerado). Corrección: NO hay un fallback universal a CreditCard —
// /admin/condiciones-precio administra condiciones comerciales futuras en
// general, no solo cuotas. Un code desconocido se identifica por su name
// ("cuota"/"tarjeta", sin acentos ni mayúsculas) y, si tampoco eso es
// inequívoco, cae en un ícono genérico de medio de pago — nunca Banknote
// ni CreditCard. Ver comentario en lib/pricing/payment-method-icon.ts.

describe("resolvePaymentMethodIcon", () => {
  it("Efectivo (CASH) conserva el ícono de billete", () => {
    expect(resolvePaymentMethodIcon({ code: "CASH", name: "Efectivo" })).toBe(Banknote);
  });

  it("Transferencia (TRANSFER) conserva su ícono de banco", () => {
    expect(resolvePaymentMethodIcon({ code: "TRANSFER", name: "Transferencia" })).toBe(Landmark);
  });

  it("1 pago (CARD_1) conserva el ícono de tarjeta", () => {
    expect(resolvePaymentMethodIcon({ code: "CARD_1", name: "Tarjeta de crédito — 1 pago" })).toBe(CreditCard);
  });

  it("3 cuotas (CARD_3) conserva el ícono de tarjeta", () => {
    expect(resolvePaymentMethodIcon({ code: "CARD_3", name: "3 cuotas sin interés" })).toBe(CreditCard);
  });

  it("6 cuotas (CARD_6) conserva el ícono de tarjeta", () => {
    expect(resolvePaymentMethodIcon({ code: "CARD_6", name: "6 cuotas sin interés" })).toBe(CreditCard);
  });

  it('"2 cuotas sin interés" (code autogenerado PM-<uuid>) se identifica por el name y muestra tarjeta', () => {
    expect(
      resolvePaymentMethodIcon({ code: "PM-353e9ba2ae7548429d2af8613ae78100", name: "2 cuotas sin interés" })
    ).toBe(CreditCard);
  });

  it('una futura "9 cuotas sin interés" (code desconocido, nunca agregado a ningún mapa) también muestra tarjeta, solo por su name', () => {
    expect(
      resolvePaymentMethodIcon({ code: "PM-9cuotasfuturasdesconocido", name: "9 cuotas sin interés" })
    ).toBe(CreditCard);
  });

  it('"Tarjeta" con mayúscula y sin acentos sigue matcheando (normalización)', () => {
    expect(resolvePaymentMethodIcon({ code: "PM-otrocode", name: "TARJETA NARANJA" })).toBe(CreditCard);
  });

  it("una modalidad de cobro futura realmente desconocida (ni cuotas ni tarjeta en el name) NO se representa como efectivo ni como tarjeta — ícono genérico", () => {
    expect(resolvePaymentMethodIcon({ code: "PM-criptomoneda", name: "Pago con criptomonedas" })).toBe(
      CircleDollarSign
    );
  });
});
