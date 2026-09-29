import type { ElementType } from "react";
import { Banknote, CircleDollarSign, CreditCard, Landmark } from "lucide-react";

/**
 * Ícono del selector "Medio de pago" en Nueva Venta. Ajuste puramente
 * visual — no afecta pricing, disponibilidad ni ninguna lógica de venta.
 *
 * payment_methods no tiene ninguna columna que distinga semánticamente
 * "tarjeta/cuotas" de "efectivo/transferencia" de "otra modalidad futura"
 * (requires_billing no sirve: TRANSFER también es true y no es tarjeta) —
 * se descarta agregar schema/migración por un detalle visual.
 *
 * /admin/condiciones-precio administra condiciones comerciales futuras EN
 * GENERAL, no solo planes de cuotas — no está garantizado que toda
 * condición nueva sea tarjeta. Por eso NO hay un fallback universal a
 * CreditCard: un code no reconocido (autogenerado, ej. "2 cuotas sin
 * interés" o una futura "9 cuotas sin interés") se identifica por su
 * `name` — la única señal semántica real que el admin escribe a mano al
 * crear la condición — buscando "cuota"/"tarjeta" (sin acentos, sin
 * importar mayúsculas). Si el nombre tampoco lo deja inequívoco (una
 * modalidad de cobro realmente desconocida), se usa un ícono genérico de
 * medio de pago — nunca Banknote ni CreditCard, para no representarla
 * falsamente como efectivo o tarjeta.
 */
const PAYMENT_ICONS: Record<string, ElementType> = {
  CASH: Banknote,
  TRANSFER: Landmark,
  CARD_1: CreditCard,
  CARD_3: CreditCard,
  CARD_6: CreditCard,
};

// Mismo idioma que ya usa lib/pdf-comisiones.ts para sacar acentos (NFD +
// borrar los diacríticos combinantes) — "Tarjeta"/"CUOTAS"/"cuóta" matchean
// igual que "tarjeta"/"cuotas".
function normalize(text: string): string {
  return text
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "");
}

function nameIdentifiesCardOrInstallments(name: string): boolean {
  const normalized = normalize(name);
  return normalized.includes("cuota") || normalized.includes("tarjeta");
}

export function resolvePaymentMethodIcon(paymentMethod: { code: string; name: string }): ElementType {
  const knownIcon = PAYMENT_ICONS[paymentMethod.code];
  if (knownIcon) return knownIcon;
  if (nameIdentifiesCardOrInstallments(paymentMethod.name)) return CreditCard;
  return CircleDollarSign;
}
