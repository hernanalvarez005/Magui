import { z } from "zod";

// Alta y edición de productos simples/accesorios desde /admin/productos. Los
// kits se crean y editan en /admin/kits (Bloque 5) porque necesitan su propia
// composición — acá el tipo queda restringido a product|accessory.
export const productSchema = z.object({
  sku: z
    .string()
    .trim()
    .min(2, "El SKU debe tener al menos 2 caracteres.")
    .max(40)
    .regex(/^[A-Za-z0-9._-]+$/, "El SKU solo puede tener letras, números, puntos y guiones."),
  name: z.string().trim().min(2, "Ingresá un nombre válido."),
  product_type: z.enum(["product", "accessory"]),
  category: z.string().trim().max(60).optional().or(z.literal("")),
  unit: z.string().trim().min(1, "Indicá la unidad (ej: unidad, ml).").max(20),
  track_stock: z.boolean(),
  commissionable: z.boolean(),
  promo_eligible: z.boolean(),
  default_min_stock: z
    .number({ error: "Ingresá un mínimo de stock válido." })
    .min(0, "El mínimo de stock no puede ser negativo."),
  notes: z.string().trim().max(300).optional().or(z.literal("")),
});

export type ProductInput = z.infer<typeof productSchema>;
