import { NextResponse, type NextRequest } from "next/server";
import { z } from "zod";

import { createServiceRoleClient } from "@/lib/supabase/server";

// Endpoint preparado para futuras integraciones (Shopify, Tiendanube, WooCommerce, etc.)
// sin asumir ninguna plataforma en particular (ver docs/architecture.md §31). Autenticación
// server-to-server vía Bearer token compartido (WEB_ORDERS_API_TOKEN). Idempotente:
// (external_source, external_order_id) tiene un unique index — un mismo pedido nunca crea
// dos ventas, incluso si esta ruta se llama dos veces.

const webOrderSchema = z.object({
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
});

export async function POST(request: NextRequest) {
  const expectedToken = process.env.WEB_ORDERS_API_TOKEN;
  if (!expectedToken) {
    return NextResponse.json(
      { error: "El servidor no tiene configurado WEB_ORDERS_API_TOKEN." },
      { status: 500 }
    );
  }

  const authHeader = request.headers.get("authorization");
  if (authHeader !== `Bearer ${expectedToken}`) {
    return NextResponse.json({ error: "No autorizado." }, { status: 401 });
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "El cuerpo debe ser JSON válido." }, { status: 400 });
  }

  const parsed = webOrderSchema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json(
      { error: parsed.error.issues[0]?.message ?? "Datos inválidos.", issues: parsed.error.issues },
      { status: 422 }
    );
  }

  const supabase = createServiceRoleClient();
  const { data, error } = await supabase.rpc("create_web_order", {
    p_items: parsed.data.items,
    p_location_id: parsed.data.location_id,
    p_payment_method_id: parsed.data.payment_method_id,
    p_external_source: parsed.data.external_source,
    p_external_order_id: parsed.data.external_order_id,
    p_customer_id: parsed.data.customer_id ?? null,
    p_doctor_id: parsed.data.doctor_id ?? null,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    // Idempotencia: un reintento del mismo pedido no es un error del cliente real.
    const alreadyImported = error.message.includes("ya fue importado");
    return NextResponse.json({ error: error.message }, { status: alreadyImported ? 409 : 400 });
  }

  return NextResponse.json({ ok: true, sale: data }, { status: 201 });
}
