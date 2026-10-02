import { z } from "zod";

// Alta/edición de condiciones de precio en /admin/condiciones-precio (Condiciones
// de precio administrables, migración 69/70). Un único formulario para el admin
// — nunca expone la separación técnica payment_method + price_condition como dos
// pasos (create_price_condition/update_price_condition ya hacen esa composición
// atómica del lado del servidor, acá solo se valida la forma antes de mandarla).
//
// priority: fn_pricing_quote resuelve por "order by priority asc limit 1" — un
// valor mayor o igual al de la condición Lista/BASE deja la condición nueva
// silenciosamente invisible (Lista siempre gana el empate/la comparación). Por
// eso el schema se arma con un factory que recibe la prioridad vigente de Lista
// y la valida en el momento, en vez de una constante hardcodeada.
export function makePriceConditionSchema(listPriority: number) {
  return z
    .object({
      name: z.string().trim().min(2, "Ingresá un nombre válido.").max(80),
      discount_percent: z.number().min(0).max(100),
      requires_billing: z.boolean(),
      active: z.boolean(),
      priority: z
        .number()
        .int()
        .min(1, "La prioridad tiene que ser un número positivo.")
        .max(9999),
      location_codes: z.array(z.string()),
      available_web: z.boolean(),
      visible_in_price_lookup: z.boolean(),
    })
    .superRefine((data, ctx) => {
      if (data.priority >= listPriority) {
        ctx.addIssue({
          code: "custom",
          message: `La prioridad tiene que ser menor a ${listPriority} (la de "Lista", precio de referencia) — si no, esta condición nunca se aplicaría, Lista siempre le gana.`,
          path: ["priority"],
        });
      }
      if (data.location_codes.length === 0 && !data.available_web) {
        ctx.addIssue({
          code: "custom",
          message: "Elegí al menos una sucursal o habilitá Web — si no, esta condición no se puede usar en ninguna venta.",
          path: ["location_codes"],
        });
      }
    });
}

export type PriceConditionInput = z.infer<ReturnType<typeof makePriceConditionSchema>>;
