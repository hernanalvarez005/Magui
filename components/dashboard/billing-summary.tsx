"use client";

import { useState } from "react";
import { Eye, EyeOff, Percent, Receipt, TrendingUp } from "lucide-react";

import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { formatCurrency } from "@/lib/utils";
import { displayAmount, readHideBillingAmounts, writeHideBillingAmounts } from "@/lib/dashboard/billing-privacy";

/**
 * "Resumen de Facturación" del Dashboard (Inicio de admin/viewer) — los 3
 * KPIs monetarios (Facturación, Ticket promedio, Comisión generada), con un
 * ícono de ojo para ocultar/mostrar todos los importes de este bloque a la
 * vez. Los KPIs no monetarios (Ventas, Unidades vendidas, Ventas web, Stock
 * crítico) quedan fuera de este componente — la pantalla los sigue
 * renderizando aparte, sin cambios.
 *
 * Puramente visual: no toca fn_pricing_quote, dashboard_report, ni ningún
 * otro cálculo — misma data que ya llegaba por props, solo cambia cómo se
 * pinta. Preferencia guardada en localStorage (ver billing-privacy.ts), no
 * en Supabase — es del navegador, no del usuario.
 */
export function BillingSummary({
  revenue,
  avgTicket,
  commissionTotal,
}: {
  revenue: number;
  avgTicket: number;
  commissionTotal: number;
}) {
  const [hidden, setHidden] = useState(() =>
    typeof window === "undefined" ? false : readHideBillingAmounts(window.localStorage)
  );

  function toggle() {
    setHidden((prev) => {
      const next = !prev;
      writeHideBillingAmounts(typeof window === "undefined" ? undefined : window.localStorage, next);
      return next;
    });
  }

  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-semibold text-muted-foreground">Resumen de Facturación</h2>
        <Button
          variant="ghost"
          size="icon"
          className="size-8"
          onClick={toggle}
          aria-label={hidden ? "Mostrar importes" : "Ocultar importes"}
          title={hidden ? "Mostrar importes" : "Ocultar importes"}
        >
          {hidden ? <EyeOff className="size-4" /> : <Eye className="size-4" />}
        </Button>
      </div>
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-3">
        <MoneyKpi icon={TrendingUp} label="Facturación" amount={revenue} hidden={hidden} />
        <MoneyKpi icon={Receipt} label="Ticket promedio" amount={avgTicket} hidden={hidden} />
        <MoneyKpi icon={Percent} label="Comisión generada" amount={commissionTotal} hidden={hidden} />
      </div>
    </div>
  );
}

function MoneyKpi({
  icon: Icon,
  label,
  amount,
  hidden,
}: {
  icon: React.ElementType;
  label: string;
  amount: number;
  hidden: boolean;
}) {
  return (
    <Card>
      <CardContent className="flex items-center gap-3 p-4">
        <div className="flex size-9 shrink-0 items-center justify-center rounded-full bg-primary/10">
          <Icon className="size-4 text-primary" />
        </div>
        <div className="min-w-0">
          <p className="text-xs text-muted-foreground">{label}</p>
          <p className="truncate text-lg font-semibold">{displayAmount(formatCurrency(amount), hidden)}</p>
        </div>
      </CardContent>
    </Card>
  );
}
