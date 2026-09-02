import { redirect } from "next/navigation";
import Link from "next/link";
import { AlertTriangle, ArrowRight, Plus, ShoppingBag } from "lucide-react";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { activePromotionsQuery, resolvePromotionParticipants } from "@/lib/promotions/active-promotions";
import { ActivePromotionsStrip } from "@/components/home/active-promotions-strip";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { formatCurrency, formatDateTime, todayInBuenosAires } from "@/lib/utils";

export default async function HomePage() {
  const profile = await getCurrentProfile();

  // El observador (viewer) quiere ver la gestión agregada, no "mis ventas de
  // hoy" (no tiene ventas propias) — mismo destino que admin.
  if (profile.role === "admin" || profile.role === "viewer") {
    redirect("/dashboard");
  }

  const supabase = await createClient();
  const today = todayInBuenosAires();

  const [{ data: todaySales }, { data: recentSales }, { data: lowStock }, { data: promotions }] = await Promise.all([
    supabase
      .from("sales")
      .select("id, total")
      .eq("seller_id", profile.id)
      .eq("status", "confirmed")
      .gte("sold_at", `${today}T00:00:00-03:00`),
    supabase
      .from("sales")
      .select("id, sale_number, total, sold_at, status")
      .eq("seller_id", profile.id)
      .order("sold_at", { ascending: false })
      .limit(5),
    supabase
      .from("product_stock_status")
      .select("sku, name, location_code, quantity, status")
      // IMPORTANTE: la vista hace CROSS JOIN con todas las sedes; sin este
      // filtro explícito, una vendedora ve alertas falsas de sedes a las que
      // ni siquiera tiene acceso (RLS oculta la fila del LEFT JOIN, pero no
      // la sede "fantasma" del cross join, así que el stock aparece en 0).
      .in("location_id", profile.locationIds.length > 0 ? profile.locationIds : ["00000000-0000-0000-0000-000000000000"])
      .in("status", ["bajo", "sin_stock"])
      // Un producto inactivo no es una alerta operativa real — ver
      // 20260201000030_product_lifecycle.sql (columna product_active).
      .eq("product_active", true)
      .limit(6),
    // Misma fuente/regla de vigencia que /precios (activePromotionsQuery) —
    // ajuste "promociones en Home", sección 4: ninguna copia de datos.
    activePromotionsQuery(supabase),
  ]);

  const participantsByPromotion = await resolvePromotionParticipants(
    supabase,
    (promotions ?? []).map((p) => p.id)
  );

  const salesCount = todaySales?.length ?? 0;
  const revenueToday = (todaySales ?? []).reduce((acc, s) => acc + Number(s.total), 0);

  return (
    <div className="mx-auto flex max-w-2xl flex-col gap-6 p-4 md:p-6">
      <div>
        <h1 className="text-2xl font-semibold">Hola, {profile.fullName.split(" ")[0]} 👋</h1>
        <p className="text-sm text-muted-foreground">Así viene tu día hoy.</p>
      </div>

      <Button asChild size="xl" className="w-full shadow-md">
        <Link href="/ventas/nueva">
          <Plus /> Nueva venta
        </Link>
      </Button>

      <ActivePromotionsStrip promotions={promotions ?? []} participantsByPromotion={participantsByPromotion} />

      <div className="grid grid-cols-2 gap-3">
        <Card>
          <CardContent className="p-4">
            <p className="text-xs text-muted-foreground">Ventas hoy</p>
            <p className="mt-1 text-2xl font-semibold">{salesCount}</p>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="p-4">
            <p className="text-xs text-muted-foreground">Facturación hoy</p>
            <p className="mt-1 text-2xl font-semibold">{formatCurrency(revenueToday)}</p>
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader className="flex-row items-center justify-between space-y-0">
          <CardTitle className="text-base">Últimas ventas</CardTitle>
          <Link href="/ventas" className="flex items-center gap-1 text-sm text-primary">
            Ver todas <ArrowRight className="size-3.5" />
          </Link>
        </CardHeader>
        <CardContent className="flex flex-col gap-1 p-0 pb-2">
          {!recentSales || recentSales.length === 0 ? (
            <p className="px-5 pb-4 text-sm text-muted-foreground">
              Todavía no registraste ventas.
            </p>
          ) : (
            recentSales.map((sale) => (
              <Link
                key={sale.id}
                href={`/ventas/${sale.id}`}
                className="flex items-center justify-between px-5 py-2.5 text-sm hover:bg-accent"
              >
                <div>
                  <p className="font-medium">{sale.sale_number}</p>
                  <p className="text-xs text-muted-foreground">{formatDateTime(sale.sold_at)}</p>
                </div>
                <div className="flex items-center gap-2">
                  {sale.status === "cancelled" ? <Badge variant="destructive">Cancelada</Badge> : null}
                  {sale.status === "replaced" ? <Badge variant="outline">Reemplazada</Badge> : null}
                  <span className="font-medium">{formatCurrency(sale.total)}</span>
                </div>
              </Link>
            ))
          )}
        </CardContent>
      </Card>

      {lowStock && lowStock.length > 0 ? (
        <Card className="border-warning/40 bg-warning/10">
          <CardHeader className="flex-row items-center gap-2 space-y-0">
            <AlertTriangle className="size-4 text-warning-foreground" />
            <CardTitle className="text-base">Alertas de stock</CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-2 pt-0">
            {lowStock.map((item) => (
              <div
                key={`${item.sku}-${item.location_code}`}
                className="flex items-center justify-between text-sm"
              >
                <span>
                  {item.name} <span className="text-muted-foreground">· {item.location_code}</span>
                </span>
                <Badge variant={item.status === "sin_stock" ? "destructive" : "warning"}>
                  {item.status === "sin_stock" ? "Sin stock" : `${item.quantity} u.`}
                </Badge>
              </div>
            ))}
          </CardContent>
        </Card>
      ) : null}

      <Button asChild variant="outline" size="lg">
        <Link href="/ventas/nueva">
          <ShoppingBag /> Ir a Nueva venta
        </Link>
      </Button>
    </div>
  );
}
