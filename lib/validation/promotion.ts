import { z } from "zod";

// Alta/edición de promociones en /admin/promociones. La composición
// (product_ids) se guarda aparte, vía la RPC set_promotion_products —
// acá solo se valida la forma antes de mandarla.
export const promotionTypeSchema = z.enum(["THREE_FOR_TWO", "DUO_PERCENT", "KIT_PERCENT", "QUANTITY_DISCOUNT"]);

export const promotionSchema = z
  .object({
    code: z
      .string()
      .trim()
      .min(2, "El código debe tener al menos 2 caracteres.")
      .max(40)
      .regex(/^[A-Za-z0-9._-]+$/, "El código solo puede tener letras, números, puntos y guiones."),
    name: z.string().trim().min(2, "Ingresá un nombre válido."),
    type: promotionTypeSchema,
    price_condition_id: z.string().uuid("Elegí la condición de precio base."),
    discount_percent: z.number().min(0.01).max(0.9).nullable(),
    group_size: z.number().int().min(2).max(20),
    // Exclusivo de QUANTITY_DISCOUNT: cantidad mínima de UNIDADES
    // participantes (sección 4 del pedido "QUANTITY -> Promociones") — nunca
    // hardcodeada a 2/3, completamente editable.
    minimum_quantity: z.number().int().min(1).nullable(),
    priority: z.number().int().min(1).max(999),
    stackable: z.boolean(),
    valid_from: z.string().min(1, "Elegí una fecha de inicio."),
    valid_until: z.string().optional().or(z.literal("")),
    notes: z.string().trim().max(300).optional().or(z.literal("")),
    product_ids: z.array(z.string().uuid()),
  })
  .superRefine((data, ctx) => {
    if (data.type === "THREE_FOR_TWO") {
      if (data.discount_percent !== null) {
        ctx.addIssue({ code: "custom", message: "El 3x2 no usa porcentaje: la unidad sale 100% gratis.", path: ["discount_percent"] });
      }
      if (data.product_ids.length < 1) {
        ctx.addIssue({ code: "custom", message: "Elegí al menos un producto elegible.", path: ["product_ids"] });
      }
    } else {
      if (data.discount_percent === null) {
        ctx.addIssue({ code: "custom", message: "Ingresá el porcentaje de descuento.", path: ["discount_percent"] });
      }
      if (data.type === "DUO_PERCENT") {
        // Duo sigue siendo una pareja exacta — mecanismo distinto (least(qty_a, qty_b)),
        // fuera del alcance del ajuste de selección múltiple.
        if (data.product_ids.length !== 2) {
          ctx.addIssue({ code: "custom", message: "Elegí exactamente 2 productos.", path: ["product_ids"] });
        }
      } else {
        // KIT_PERCENT/QUANTITY_DISCOUNT: uno o varios productos/kits — cada
        // uno participa de forma independiente (para QUANTITY_DISCOUNT, la
        // cantidad mínima se evalúa sobre la SUMA de todos ellos).
        if (data.product_ids.length < 1) {
          ctx.addIssue({ code: "custom", message: "Elegí al menos un producto o kit.", path: ["product_ids"] });
        }
      }
      if (data.type === "QUANTITY_DISCOUNT" && data.minimum_quantity === null) {
        ctx.addIssue({ code: "custom", message: "Ingresá la cantidad mínima.", path: ["minimum_quantity"] });
      }
      if (data.type !== "QUANTITY_DISCOUNT" && data.minimum_quantity !== null) {
        ctx.addIssue({
          code: "custom",
          message: "La cantidad mínima es exclusiva de Descuento por cantidad.",
          path: ["minimum_quantity"],
        });
      }
    }
    if (data.valid_until && data.valid_until <= data.valid_from) {
      ctx.addIssue({ code: "custom", message: "La fecha de fin debe ser posterior a la de inicio.", path: ["valid_until"] });
    }
  });

export type PromotionInput = z.infer<typeof promotionSchema>;
