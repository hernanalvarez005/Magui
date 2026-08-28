import { z } from "zod";

// Validación de defensa en profundidad en el cliente, ANTES de llamar a la RPC.
// La autoridad real (precio, stock, permisos) siempre es create_sale() en el servidor.

export const cartItemSchema = z.object({
  product_id: z.string().uuid(),
  quantity: z.number().positive("La cantidad debe ser mayor a cero."),
});

export const newSaleSchema = z.object({
  items: z.array(cartItemSchema).min(1, "Agregá al menos un producto."),
  location_id: z.string().uuid("Seleccioná una sucursal."),
  sales_channel_id: z.string().uuid("Seleccioná un canal de venta."),
  payment_method_id: z.string().uuid("Seleccioná un medio de pago."),
  customer_id: z.string().uuid().nullable().optional(),
  doctor_id: z.string().uuid().nullable().optional(),
  notes: z.string().max(500).nullable().optional(),
});

export type NewSaleInput = z.infer<typeof newSaleSchema>;

export const newCustomerSchema = z.object({
  full_name: z.string().trim().min(2, "Ingresá un nombre válido."),
  dni: z
    .string()
    .trim()
    .regex(/^\d{6,9}$/, "El DNI debe tener entre 6 y 9 dígitos.")
    .optional()
    .or(z.literal("")),
  whatsapp: z.string().trim().max(30).optional().or(z.literal("")),
  email: z.string().trim().email("Ese email no es válido.").optional().or(z.literal("")),
  notes: z.string().trim().max(300).optional().or(z.literal("")),
});

export type NewCustomerInput = z.infer<typeof newCustomerSchema>;

export const cancelSaleSchema = z.object({
  sale_id: z.string().uuid(),
  reason: z.string().trim().min(5, "Contá brevemente el motivo de la cancelación."),
});

export const adjustStockSchema = z.object({
  location_id: z.string().uuid("Seleccioná una sucursal."),
  product_id: z.string().uuid("Seleccioná un producto."),
  quantity_delta: z
    .number()
    .refine((n) => n !== 0, "La cantidad no puede ser cero."),
  reason: z.enum([
    "RECEPTION",
    "BREAKAGE",
    "EXPIRATION",
    "COUNT_DIFFERENCE",
    "RETURN",
    "OTHER",
  ]),
  notes: z.string().trim().max(300).nullable().optional(),
});

export const transferStockSchema = z.object({
  from_location_id: z.string().uuid("Seleccioná la sucursal de origen."),
  to_location_id: z.string().uuid("Seleccioná la sucursal de destino."),
  items: z.array(cartItemSchema).min(1, "Agregá al menos un producto a transferir."),
  notes: z.string().trim().max(300).nullable().optional(),
});
