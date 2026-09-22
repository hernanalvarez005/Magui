import { readFile } from "node:fs/promises";
import path from "node:path";

import type { NextRequest } from "next/server";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { buildComisionesPdf, comisionesPdfFilename } from "@/lib/pdf-comisiones";
import { todayInBuenosAires } from "@/lib/utils";
import type { DoctorSalesDetail } from "@/types/database";

// Comisiones por Dra. -> Exportar PDF. Misma fuente de verdad que la
// pantalla (doctor_sales_detail, migración 68) — este endpoint no calcula
// nada, solo llama la RPC con los mismos from/to/location que ya trae la
// URL de /dashboard/comisiones/[doctorId] y arma el PDF a partir de eso.
//
// Seguridad (auditado antes de implementar): el chequeo de rol acá es solo
// un fast-fail de UX — la autoridad real es el propio chequeo interno de
// doctor_sales_detail (security definer, valida admin/can_view_financial_reports
// contra el perfil real de auth.uid(), no contra nada que mande el cliente).
// No se hace ninguna consulta cruda adicional a sale_items/sale_item_net acá
// — todo, incluido el detalle de productos por venta, sale de esta única
// llamada a la RPC, así que no hay ventana para que la autorización quede
// inconsistente entre lo que ve la pantalla y lo que arma el PDF.
export async function GET(request: NextRequest, context: RouteContext<"/api/export/comisiones-doctora/[doctorId]/pdf">) {
  const { doctorId } = await context.params;
  const profile = await getCurrentProfile();
  if (!(profile.role === "admin" || profile.canViewFinancialReports)) {
    return new Response("No autorizado.", { status: 403 });
  }

  const supabase = await createClient();
  const params = request.nextUrl.searchParams;

  const to = params.get("to") ?? todayInBuenosAires();
  const from =
    params.get("from") ??
    (() => {
      const d = new Date();
      d.setDate(d.getDate() - 29);
      return d.toISOString().slice(0, 10);
    })();
  const location = params.get("location");

  const { data: report, error } = await supabase.rpc("doctor_sales_detail", {
    p_doctor_id: doctorId,
    p_from: from,
    p_to: to,
    p_location_id: location,
  });
  if (error) return new Response(error.message, { status: 400 });

  const data = report as DoctorSalesDetail;
  if (!data.sales || data.sales.length === 0) {
    return Response.json({ error: "No hay comisiones para exportar en el período seleccionado." }, { status: 422 });
  }

  // El logo es cosmético — si por algún motivo no se puede leer, el PDF se
  // genera igual sin logo (buildComisionesPdf ya contempla logoPng undefined).
  let logoPng: Uint8Array | undefined;
  try {
    logoPng = await readFile(path.join(process.cwd(), "public/brand/logo.png"));
  } catch {
    logoPng = undefined;
  }

  const doc = buildComisionesPdf(data, { from, to, logoPng });
  const buffer = doc.output("arraybuffer");
  const filename = comisionesPdfFilename(data.doctor.full_name, from, to);

  return new Response(buffer, {
    headers: {
      "Content-Type": "application/pdf",
      "Content-Disposition": `attachment; filename="${filename}"`,
    },
  });
}
