import { NextResponse, type NextRequest } from "next/server";

import { createServiceRoleClient } from "@/lib/supabase/server";
import { resolveWebOrderFulfillmentType, webOrderSchema } from "@/lib/validation/web-order";

// Endpoint preparado para futuras integraciones (Shopify, Tiendanube, WooCommerce, etc.)
// sin asumir ninguna plataforma en particular (ver docs/architecture.md §31). Autenticación
// server-to-server vía Bearer token compartido (WEB_ORDERS_API_TOKEN). Idempotente:
// (external_source, external_order_id) tiene un unique index — un mismo pedido nunca crea
// dos ventas, incluso si esta ruta se llama dos veces.
//
// payment_status/payment_account_id (Checkpoint 2.1, migración 071): circuito
// de pago/facturación para integraciones que conocen el estado de pago del
// pedido — ver lib/validation/web-order.ts. Un payload sin estos campos ve el
// comportamiento histórico exacto (nunca se asume PENDING ni PAID).
// fulfillment_type NUNCA se expone acá — es un detalle interno de Magui
// (SHIPPING vs PICKUP, V1 solo soporta SHIPPING); se decide server-side.

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
    p_payment_status: parsed.data.payment_status ?? null,
    p_payment_account_id: parsed.data.payment_account_id ?? null,
    p_fulfillment_type: resolveWebOrderFulfillmentType(parsed.data),
  });

  if (error) {
    // Idempotencia: un reintento del mismo pedido no es un error del cliente real.
    const alreadyImported = error.message.includes("ya fue importado");
    return NextResponse.json({ error: error.message }, { status: alreadyImported ? 409 : 400 });
  }

  return NextResponse.json({ ok: true, sale: data }, { status: 201 });
}
