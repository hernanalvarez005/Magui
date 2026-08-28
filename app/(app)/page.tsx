import { redirect } from "next/navigation";
import Link from "next/link";
import { AlertTriangle, ArrowRight, Plus, ShoppingBag } from "lucide-react";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { formatCurrency, formatDateTime, todayInBuenosAires } from "@/lib/utils";

export default async function HomePage() {
  const profile = await getCurrentProfile();

  if (profile.role === "admin") {
    redirect("/dashboard");
  }

  const supabase = await createClient();
  const today = todayInBuenosAires();

  const [{ data: todaySales }, { data: recentSales }, { data: lowStock }] = await Promise.all([
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
      .in("status", ["bajo", "sin_stock"])
      .limit(6),
  ]);

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
                  {sale.status === "cancelled" ? (
                    <Badge variant="destructive">Cancelada</Badge>
                  ) : null}
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
