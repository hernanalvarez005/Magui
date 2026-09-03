"use client";

import { useEffect, useState } from "react";

import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { RevenueByDayChart } from "@/components/dashboard/revenue-by-day-chart";
import { createClient } from "@/lib/supabase/client";
import { formatCurrency } from "@/lib/utils";
import type { PromotionPerformanceDetail, PromotionPerformanceRow } from "@/types/database";

/**
 * Drill-down de una promoción puntual: metadata vigente + métricas del
 * rango + ranking de productos/kits dentro de ella + evolución diaria.
 * Se abre desde una fila del ranking (promotion-performance-view) — pide
 * promotion_performance_detail recién al abrirse, nunca precargado para
 * cada fila del ranking (evitaría N+1 innecesario si nadie hace click).
 */
export function PromotionPerformanceDetailDialog({
  row,
  from,
  to,
  onOpenChange,
}: {
  row: PromotionPerformanceRow | null;
  from: string;
  to: string;
  onOpenChange: (open: boolean) => void;
}) {
  return (
    <Dialog open={row !== null} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>{row?.name ?? "Promoción"}</DialogTitle>
        </DialogHeader>
        {/* key por promotion_id: cada promoción abierta arranca con estado
            propio (sin esto habría que resetear "detail" a mano dentro de
            un efecto al cambiar de fila, un setState síncrono en el cuerpo
            del efecto que el linter de hooks rechaza). */}
        {row ? <PromotionDetailBody key={row.promotion_id} promotionId={row.promotion_id} from={from} to={to} /> : null}
      </DialogContent>
    </Dialog>
  );
}

function PromotionDetailBody({ promotionId, from, to }: { promotionId: string; from: string; to: string }) {
  const [detail, setDetail] = useState<PromotionPerformanceDetail | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    const supabase = createClient();
    supabase
      .rpc("promotion_performance_detail", { p_promotion_id: promotionId, p_from: from, p_to: to })
      .then(({ data }) => {
        if (!cancelled) {
          setDetail(data as PromotionPerformanceDetail | null);
          setLoading(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [promotionId, from, to]);

  if (loading || !detail) {
    return <p className="py-6 text-center text-sm text-muted-foreground">Cargando…</p>;
  }

  return (
    <div className="flex flex-col gap-5">
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Metric label="Ventas" value={String(detail.metrics.sales_count)} />
        <Metric label="Unidades" value={String(detail.metrics.units_sold)} />
        <Metric label="Facturación" value={formatCurrency(detail.metrics.revenue)} />
        <Metric label="Ticket promedio" value={formatCurrency(detail.metrics.average_ticket)} />
      </div>

      <div>
        <h3 className="mb-2 text-sm font-medium">Facturación por día</h3>
        <RevenueByDayChart data={detail.daily_evolution} />
      </div>

      <div>
        <h3 className="mb-2 text-sm font-medium">Productos/kits dentro de esta promoción</h3>
        {detail.top_products.length === 0 ? (
          <p className="text-sm text-muted-foreground">Sin datos en este período.</p>
        ) : (
          <ul className="flex flex-col gap-2">
            {detail.top_products.map((p) => (
              <li key={p.product_id} className="flex items-center justify-between gap-2 text-sm">
                <span className="truncate">{p.name}</span>
                <span className="shrink-0 tabular-nums text-muted-foreground">
                  {p.units} u. · {formatCurrency(p.revenue)}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border border-border p-3">
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className="truncate text-base font-semibold">{value}</p>
    </div>
  );
}
