import { z } from "zod";

// Contrato de POST /api/integrations/web-orders. Extraído a un módulo propio
// (Checkpoint 2.1) para poder testear la validación con Vitest sin pasar por
// la capa HTTP — mismo criterio que lib/sales/web-fulfillment.ts.
//
// payment_status/payment_account_id (migración 71, create_web_order): un
// payload que NO los manda ve el comportamiento histórico exacto — nunca se
// asume PENDING ni PAID. fulfillment_type NUNCA se expone acá — es un detalle
// interno de Magui (SHIPPING vs PICKUP); el route handler decide 'SHIPPING'
// internamente solo cuando payment_status viene informado (ver route.ts).
// PICKUP no está soportado por este contrato (fuera de alcance del
// Checkpoint 2.1).
export const webOrderSchema = z
  .object({
    external_source: z.string().trim().min(1, "external_source es obligatorio."),
    external_order_id: z.string().trim().min(1, "external_order_id es obligatorio."),
    location_id: z.string().uuid("location_id debe ser un UUID válido."),
    payment_method_id: z.string().uuid("payment_method_id debe ser un UUID válido."),
    items: z
      .array(z.object({ product_id: z.string().uuid(), quantity: z.number().positive() }))
      .min(1, "El pedido no tiene productos."),
    customer_id: z.string().uuid().nullable().optional(),
    doctor_id: z.string().uuid().nullable().optional(),
    notes: z.string().max(500).nullable().optional(),
    raw_reference: z.unknown().optional(), // se guarda solo en notes/logs, no en columna dedicada del MVP
    payment_status: z.enum(["PAID", "PENDING"]).optional(),
    payment_account_id: z.string().uuid("payment_account_id debe ser un UUID válido.").nullable().optional(),
  })
  .superRefine((data, ctx) => {
    // Validación clara acá — no hace falta esperar el error de Postgres si
    // el contrato ya lo puede determinar (fn_create_sale_core exige cuenta
    // de todos modos, pero un 422 con mensaje claro es mejor DX que un 400
    // genérico salido de la RPC). PENDING con payment_account_id informado
    // es válido tal cual — fn_create_sale_core ya lo acepta sin exigirlo
    // (se guarda si se conoce, se completa después si no).
    if (data.payment_status === "PAID" && !data.payment_account_id) {
      ctx.addIssue({
        code: "custom",
        message: "payment_status=PAID requiere indicar payment_account_id (la cuenta donde ingresó el dinero).",
        path: ["payment_account_id"],
      });
    }
  });

export type WebOrderInput = z.infer<typeof webOrderSchema>;

// El route handler nunca expone fulfillment_type en el contrato público —
// esta es la única regla que decide el valor interno que se le pasa a la RPC.
export function resolveWebOrderFulfillmentType(payload: Pick<WebOrderInput, "payment_status">): "SHIPPING" | null {
  return payload.payment_status ? "SHIPPING" : null;
}
