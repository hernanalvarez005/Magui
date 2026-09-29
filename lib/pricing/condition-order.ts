/**
 * Orden visual de columnas en la Matriz de precios (/admin/precios).
 * Checkpoint Final, Hallazgo C: reemplaza CONDITION_ORDER (lista de codes
 * hardcodeada) — una condición no listada ahí daba indexOf === -1, que
 * ordena ANTES que "Lista" (bug real, ya había pasado una vez con CARD_1,
 * ver comentario histórico en admin/precios/page.tsx).
 *
 * Data-driven: "Lista" (rule_type='BASE', a lo sumo una fila —
 * price_conditions_one_base es un UNIQUE constraint real) siempre ancla
 * primera, por ser la referencia — es la única condición con un rol
 * estructuralmente distinto, no un code especial. El resto se ordena por
 * priority ascendente, la misma columna que ya usa fn_pricing_quote para
 * resolver precedencia — ninguna lista de codes que mantener a mano.
 * Aislado en su propio archivo para poder testearlo sin levantar
 * admin/precios/page.tsx.
 */
export function sortConditionsForMatrix<T extends { rule_type: string; priority: number }>(conditions: T[]): T[] {
  return [...conditions].sort((a, b) => {
    if (a.rule_type === "BASE") return -1;
    if (b.rule_type === "BASE") return 1;
    return a.priority - b.priority;
  });
}
