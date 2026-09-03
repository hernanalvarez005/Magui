"use client";

import { useMemo, useState } from "react";
import { Trophy } from "lucide-react";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { PromotionPerformanceFilters } from "@/components/admin/promotion-performance-filters";
import { PromotionPerformanceDetailDialog } from "@/components/admin/promotion-performance-detail-dialog";
import { formatCurrency } from "@/lib/utils";
import type { PromotionPerformanceRow, PromotionType } from "@/types/database";

const TYPE_LABELS: Record<PromotionType, string> = {
  THREE_FOR_TWO: "3x2",
  DUO_PERCENT: "Duo %",
  KIT_PERCENT: "Kit %",
  QUANTITY_DISCOUNT: "Cantidad %",
};

type SortKey = "revenue" | "sales_count" | "units_sold" | "average_ticket";

const SORT_LABELS: Record<SortKey, string> = {
  revenue: "Facturación",
  sales_count: "Ventas",
  units_sold: "Unidades",
  average_ticket: "Ticket promedio",
};

interface PromotionMeta {
  id: string;
  active: boolean;
  valid_from: string;
  valid_until: string | null;
}

// Activa / finalizada / desactivada es puramente informativo — Analytics
// NUNCA filtra por esto (todas las filas de `rows` ya vienen con actividad
// neta > 0 en el rango, sea cual sea su estado actual: sección 30 del
// pedido, "queda consultable para siempre").
function classify(meta: PromotionMeta | undefined, now: Date): "activa" | "finalizada" | "desactivada" {
  if (!meta) return "desactivada";
  const until = meta.valid_until ? new Date(meta.valid_until) : null;
  if (until && until <= now) return "finalizada";
  if (!meta.active) return "desactivada";
  return "activa";
}

const STATUS_STYLE: Record<string, string> = {
  activa: "bg-primary/10 text-primary",
  finalizada: "bg-muted text-muted-foreground",
  desactivada: "bg-destructive/10 text-destructive",
};

export function PromotionPerformanceView({
  rows,
  promotionsMeta,
  from,
  to,
}: {
  rows: PromotionPerformanceRow[];
  promotionsMeta: PromotionMeta[];
  from: string;
  to: string;
}) {
  const [sortKey, setSortKey] = useState<SortKey>("revenue");
  const [selected, setSelected] = useState<PromotionPerformanceRow | null>(null);

  const metaById = useMemo(() => new Map(promotionsMeta.map((m) => [m.id, m])), [promotionsMeta]);
  const now = useMemo(() => new Date(), []);

  const sorted = useMemo(() => [...rows].sort((a, b) => b[sortKey] - a[sortKey]), [rows, sortKey]);

  const kpis = useMemo(() => {
    const totalRevenue = rows.reduce((sum, r) => sum + r.revenue, 0);
    const totalSales = rows.reduce((sum, r) => sum + r.sales_count, 0);
    const top = [...rows].sort((a, b) => b.revenue - a.revenue)[0] ?? null;
    return { totalRevenue, totalSales, promoCount: rows.length, top };
  }, [rows]);

  return (
    <div className="flex flex-col gap-4">
      <PromotionPerformanceFilters />

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Kpi label="Promociones con ventas" value={String(kpis.promoCount)} />
        <Kpi label="Facturación total" value={formatCurrency(kpis.totalRevenue)} />
        <Kpi label="Ventas totales" value={String(kpis.totalSales)} />
        <Kpi
          label="Promoción líder"
          value={kpis.top ? kpis.top.name : "—"}
          icon={kpis.top ? Trophy : undefined}
        />
      </div>

      <Card>
        <CardHeader className="flex flex-row items-center justify-between gap-2">
          <CardTitle className="text-base">Ranking de promociones</CardTitle>
          <Select value={sortKey} onValueChange={(v) => setSortKey(v as SortKey)}>
            <SelectTrigger className="w-44">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {(Object.keys(SORT_LABELS) as SortKey[]).map((k) => (
                <SelectItem key={k} value={k}>
                  Ordenar por {SORT_LABELS[k]}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </CardHeader>
        <CardContent>
          {sorted.length === 0 ? (
            <p className="py-6 text-center text-sm text-muted-foreground">
              Ninguna promoción tuvo actividad en este período.
            </p>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Promoción</TableHead>
                    <TableHead>Tipo</TableHead>
                    <TableHead>Estado</TableHead>
                    <TableHead className="text-right">Ventas</TableHead>
                    <TableHead className="text-right">Unidades</TableHead>
                    <TableHead className="text-right">Facturación</TableHead>
                    <TableHead className="text-right">Ticket prom.</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {sorted.map((row) => {
                    const status = classify(metaById.get(row.promotion_id), now);
                    return (
                      <TableRow
                        key={row.promotion_id}
                        className="cursor-pointer"
                        onClick={() => setSelected(row)}
                      >
                        <TableCell className="font-medium">{row.name}</TableCell>
                        <TableCell>{TYPE_LABELS[row.type]}</TableCell>
                        <TableCell>
                          <span className={`rounded-full px-2 py-0.5 text-xs ${STATUS_STYLE[status]}`}>{status}</span>
                        </TableCell>
                        <TableCell className="text-right tabular-nums">{row.sales_count}</TableCell>
                        <TableCell className="text-right tabular-nums">{row.units_sold}</TableCell>
                        <TableCell className="text-right tabular-nums">{formatCurrency(row.revenue)}</TableCell>
                        <TableCell className="text-right tabular-nums">{formatCurrency(row.average_ticket)}</TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>

      <PromotionPerformanceDetailDialog
        row={selected}
        from={from}
        to={to}
        onOpenChange={(open) => !open && setSelected(null)}
      />
    </div>
  );
}

function Kpi({ label, value, icon: Icon }: { label: string; value: string; icon?: React.ElementType }) {
  return (
    <Card>
      <CardContent className="flex items-center gap-3 p-4">
        {Icon ? (
          <div className="flex size-9 shrink-0 items-center justify-center rounded-full bg-primary/10">
            <Icon className="size-4 text-primary" />
          </div>
        ) : null}
        <div className="min-w-0">
          <p className="text-xs text-muted-foreground">{label}</p>
          <p className="truncate text-lg font-semibold">{value}</p>
        </div>
      </CardContent>
    </Card>
  );
}
