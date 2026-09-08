/**
 * Ajuste UX — Ocultar/mostrar importes de Facturación en Inicio.
 * Control de privacidad puramente visual sobre el bloque "Resumen de
 * Facturación" del Dashboard (Inicio de admin/viewer). Preferencia 100% de
 * navegador (localStorage) — nunca persistida en Supabase, no depende del
 * usuario logueado, no afecta ningún cálculo ni backend. Aislado en su
 * propio archivo para poder testear lectura/escritura sin levantar el
 * componente (mismo criterio que lib/sales/web-fulfillment.ts).
 */

export const HIDE_HOME_BILLING_AMOUNTS_KEY = "hide_home_billing_amounts";

export const MASKED_AMOUNT_PLACEHOLDER = "$ ••••••";

/** Lee la preferencia guardada. Recibe cualquier objeto con getItem (un
 * `Storage` real, o un mock en tests) en vez de asumir `window` directamente
 * — así el caller decide qué pasar (y puede omitirlo durante SSR, donde
 * `window` no existe). Cualquier error de acceso (modo privado, storage
 * deshabilitado) deja los importes visibles por defecto, nunca ocultos por
 * accidente. */
export function readHideBillingAmounts(storage: Pick<Storage, "getItem"> | null | undefined): boolean {
  if (!storage) return false;
  try {
    return storage.getItem(HIDE_HOME_BILLING_AMOUNTS_KEY) === "true";
  } catch {
    return false;
  }
}

/** Persiste la preferencia. Si el storage no está disponible o falla
 * (privado, cuota llena), el toggle sigue funcionando para esta sesión —
 * simplemente no sobrevive a un reload. */
export function writeHideBillingAmounts(storage: Pick<Storage, "setItem"> | null | undefined, hidden: boolean): void {
  if (!storage) return;
  try {
    storage.setItem(HIDE_HOME_BILLING_AMOUNTS_KEY, String(hidden));
  } catch {
    // Nada que hacer — ver comentario de arriba.
  }
}

/** Importe formateado o placeholder enmascarado, según el estado actual.
 * El ancho de la tarjeta lo define la grilla (CSS grid), no el largo del
 * texto — alternar entre "$ 123.456" y "$ ••••••" nunca mueve el layout. */
export function displayAmount(formattedAmount: string, hidden: boolean): string {
  return hidden ? MASKED_AMOUNT_PLACEHOLDER : formattedAmount;
}
