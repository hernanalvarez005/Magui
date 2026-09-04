import type { SaleFulfillmentType, SalePaymentStatus } from "@/types/database";

/**
 * Circuito Ventas Web (BLOQUE C) — reglas puras de la pantalla Nueva Venta,
 * aisladas en su propio archivo para poder testearlas sin levantar todo
 * new-sale-client.tsx (mismo criterio que payment-account-alias.ts).
 */

export type FulfillmentChoice = "" | "PICKUP_25" | "PICKUP_37" | "SHIPPING";

/** La opción elegida en el selector "Forma de entrega" resuelve directo a
 * fulfillment_type — nunca se vuelve a pedir la sede por separado. */
export function resolveFulfillmentType(choice: FulfillmentChoice): SaleFulfillmentType | null {
  if (choice === "SHIPPING") return "SHIPPING";
  if (choice === "PICKUP_25" || choice === "PICKUP_37") return "PICKUP";
  return null;
}

export interface LocationForFulfillment {
  id: string;
  code: string;
}

/** PICKUP_25/37 -> la sede física correspondiente. SHIPPING -> Depósito.
 * Si la sede necesaria no está en `locations` (el usuario no tiene acceso),
 * devuelve undefined — el caller decide cómo avisar. */
export function resolveFulfillmentLocationId(
  choice: FulfillmentChoice,
  locations: LocationForFulfillment[]
): string | undefined {
  const codeFor: Record<Exclude<FulfillmentChoice, "">, string> = {
    PICKUP_25: "SED-25",
    PICKUP_37: "SED-37",
    SHIPPING: "DEP",
  };
  if (choice === "") return undefined;
  return locations.find((l) => l.code === codeFor[choice])?.id;
}

/**
 * Cuenta de ingreso (payment_account_id): sigue siendo obligatoria para
 * transferencia/1 pago/3 cuotas — SALVO un pedido Web con payment_status
 * PENDING (todavía no se sabe en qué cuenta va a entrar un cobro que no
 * pasó; se completa después, al cobrar). Nunca afecta requiresBilling (DNI):
 * esa exigencia es un eje aparte, siempre vigente mientras el medio de pago
 * la requiera — ver comentario en new-sale-client.tsx.
 */
export function computeRequiresPaymentAccountNow(params: {
  requiresBilling: boolean;
  isWeb: boolean;
  paymentStatus: SalePaymentStatus;
}): boolean {
  if (!params.requiresBilling) return false;
  if (params.isWeb && params.paymentStatus === "PENDING") return false;
  return true;
}
