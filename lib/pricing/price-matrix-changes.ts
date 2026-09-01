/**
 * Detección de cambios del formulario de Administración → Precios
 * (components/admin/price-matrix.tsx). Antes de este archivo, el conteo de
 * "hay cambios" (para habilitar el botón) y el guardado usaban dos filtros
 * ligeramente distintos, y el de guardado excluía los campos vacíos — así
 * que borrar un precio contaba para habilitar el botón pero no se guardaba,
 * mostrando "No hay cambios para guardar" a pesar de que sí había un
 * cambio real. Ahora hay una sola función (`classifyDirtyPriceCells`), y
 * tanto el conteo/resaltado como el guardado leen de acá — no pueden
 * volver a divergir.
 */

export type NormalizedPriceInput =
  | { kind: "empty" }
  | { kind: "invalid" }
  | { kind: "value"; amount: number };

/**
 * Normaliza lo tipeado en un input de precio. "" (o solo espacios) es
 * "empty" — un precio borrado/inexistente, NUNCA $0 (recordatorio del
 * pedido: un precio inexistente no debe convertirse automáticamente en
 * $0). Un número no positivo o no numérico es "invalid" — se marca como
 * cambio (para no esconderlo), pero se rechaza al guardar con un mensaje
 * claro, igual que set_product_price() ya rechaza p_amount <= 0.
 */
export function normalizePriceInput(raw: string): NormalizedPriceInput {
  const trimmed = raw.trim();
  if (trimmed === "") return { kind: "empty" };
  const num = Number(trimmed);
  if (!Number.isFinite(num) || num <= 0) return { kind: "invalid" };
  return { kind: "value", amount: num };
}

/** true si lo tipeado en el input difiere del precio original (ya sea que
 * cambió el número, se borró uno existente, se cargó uno nuevo, o se
 * tipeó algo inválido) — comparación siempre sobre valores normalizados,
 * nunca comparando el string crudo contra el number original. */
export function isPriceCellDirty(rawValue: string, originalAmount: number | null | undefined): boolean {
  const parsed = normalizePriceInput(rawValue);
  if (parsed.kind === "invalid") return true;
  const normalizedCurrent = parsed.kind === "value" ? parsed.amount : null;
  const normalizedOriginal = originalAmount ?? null;
  return normalizedCurrent !== normalizedOriginal;
}

export interface PriceCellToSave {
  key: string;
  amount: number;
}
export interface PriceCellToClear {
  key: string;
}
export interface PriceCellInvalid {
  key: string;
  rawValue: string;
}

export interface PriceChangeClassification {
  /** Precio nuevo o modificado — se persiste con set_product_price(). */
  toSave: PriceCellToSave[];
  /** Precio existente que se dejó vacío — se persiste con clear_product_price(). */
  toClear: PriceCellToClear[];
  /** Se tipeó algo pero no es un precio válido — no se guarda, se avisa. */
  invalid: PriceCellInvalid[];
}

/**
 * Recorre todas las celdas editadas (edited: key -> string tipeado) contra
 * los valores originales (original: key -> number) y las clasifica. Una
 * celda que quedó exactamente igual al original (después de normalizar) no
 * aparece en ningún grupo — no es un cambio real.
 */
export function classifyDirtyPriceCells(
  edited: Map<string, string>,
  original: Map<string, number>
): PriceChangeClassification {
  const toSave: PriceCellToSave[] = [];
  const toClear: PriceCellToClear[] = [];
  const invalid: PriceCellInvalid[] = [];

  for (const [key, rawValue] of edited) {
    const originalAmount = original.get(key) ?? null;
    const parsed = normalizePriceInput(rawValue);

    if (parsed.kind === "invalid") {
      invalid.push({ key, rawValue });
      continue;
    }

    const normalizedCurrent = parsed.kind === "value" ? parsed.amount : null;
    if (normalizedCurrent === originalAmount) continue; // sin cambio real

    if (normalizedCurrent === null) {
      toClear.push({ key });
    } else {
      toSave.push({ key, amount: normalizedCurrent });
    }
  }

  return { toSave, toClear, invalid };
}
