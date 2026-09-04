import type { Metadata } from "next";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { NotificacionesView } from "@/components/notificaciones/notificaciones-view";

export const metadata: Metadata = { title: "Notificaciones" };

export default async function NotificacionesPage() {
  const profile = await getCurrentProfile();
  const supabase = await createClient();

  // Misma RPC que alimenta el contador del layout — acá se vuelve a llamar
  // (server component propio, sin estado compartido entre requests) pero es
  // el mismo filtro admin/sede resuelto una sola vez, del lado del server.
  const [{ data: pickups }, { data: paymentMethods }, { data: paymentAccounts }] = await Promise.all([
    supabase.rpc("web_pending_pickups"),
    supabase.from("payment_methods").select("id, code, name").eq("active", true).order("sort_order"),
    supabase.from("payment_accounts").select("id, code, name, alias").eq("active", true).order("sort_order"),
  ]);

  return (
    <NotificacionesView
      pickups={pickups ?? []}
      paymentMethods={paymentMethods ?? []}
      paymentAccounts={paymentAccounts ?? []}
      // Viewer (solo lectura) ve la bandeja igual que todo lo demás, pero
      // sin acciones — mark_web_order_paid/deliver_web_pickup lo rechazan
      // en el backend igual, esto solo evita mostrar botones que van a
      // fallar al confirmar (mismo criterio que canCancel en sale-detail-view).
      canAct={profile.role !== "viewer"}
    />
  );
}
