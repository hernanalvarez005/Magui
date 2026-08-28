import { z } from "zod";

// Alta y edición de kits en /admin/kits: datos base del producto-kit +
// composición dinámica. El stock del kit nunca es un contador propio —
// siempre se deriva de kit_components (ver fn_kit_buildable_qty) — por eso
// acá no hay ningún campo de stock del kit en sí, solo de sus componentes.
export const kitComponentSchema = z.object({
  component_product_id: z.string().uuid("Elegí un producto para cada componente."),
  quantity: z.number().positive("La cantidad debe ser mayor a cero."),
});

export const kitSchema = z.object({
  sku: z
    .string()
    .trim()
    .min(2, "El SKU debe tener al menos 2 caracteres.")
    .max(40)
    .regex(/^[A-Za-z0-9._-]+$/, "El SKU solo puede tener letras, números, puntos y guiones."),
  name: z.string().trim().min(2, "Ingresá un nombre válido."),
  category: z.string().trim().max(60).optional().or(z.literal("")),
  commissionable: z.boolean(),
  promo_eligible: z.boolean(),
  notes: z.string().trim().max(300).optional().or(z.literal("")),
  components: z
    .array(kitComponentSchema)
    .min(1, "Un kit necesita al menos un componente.")
    .refine(
      (items) => new Set(items.map((i) => i.component_product_id)).size === items.length,
      "No repitas el mismo producto como componente."
    ),
});

export type KitInput = z.infer<typeof kitSchema>;
