/**
 * Alias para transferencia en Nueva Venta (bloque "Cuenta de ingreso +
 * alias bancario"). Aislado en su propio archivo para poder testear la
 * regla sin levantar todo new-sale-client.tsx.
 */
export interface AccountForAlias {
  name: string;
  alias: string | null;
}

/**
 * true si corresponde mostrar "Alias para transferencia". Reglas (sección
 * 3/4 del pedido):
 * - Nunca en una venta sin costo.
 * - Solo cuando el medio de pago es exactamente Transferencia — nunca
 *   Efectivo, 1 pago crédito ni 3 cuotas.
 * - Solo si la cuenta elegida tiene un alias cargado (no vacío).
 * Genérico por diseño: no hay ningún "if código === 'MERCADO_PAGO'" acá —
 * cualquier cuenta con alias (Banco Galicia, una futura Banco Nación, etc.)
 * se muestra igual.
 */
export function shouldShowTransferAlias(params: {
  isFreeSale: boolean;
  paymentMethodCode: string | undefined;
  account: AccountForAlias | undefined;
}): boolean {
  if (params.isFreeSale) return false;
  if (params.paymentMethodCode !== "TRANSFER") return false;
  return !!params.account?.alias;
}
