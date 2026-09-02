"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Receipt, RotateCcw } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { createClient } from "@/lib/supabase/client";
import { formatCurrency, formatDateTime } from "@/lib/utils";
import type { SaleBillingStatus } from "@/types/database";

interface BillingItem {
  name: string;
  quantity: number;
}
interface BillingRow {
  id: string;
  sale_number: string;
  sold_at: string;
  total: string;
  billing_status: SaleBillingStatus;
  invoiced_at: string | null;
  customer?: { full_name: string; dni: string | null };
  accountName?: string;
  paymentName?: string;
  invoicedByName?: string;
  items: BillingItem[];
}

// Hasta acá se muestra completo; con más ítems se corta y se puede expandir
// ("Ver más"), nunca obligando a abrir el detalle completo de la venta
// aparte (sección 8 del pedido).
const DETAIL_VISIBLE_LIMIT = 3;

function DetailCell({ items }: { items: BillingItem[] }) {
  const [expanded, setExpanded] = useState(false);

  if (items.length === 0) return <span className="text-xs text-muted-foreground">—</span>;

  const visible = expanded ? items : items.slice(0, DETAIL_VISIBLE_LIMIT);
  const hidden = items.length - visible.length;

  return (
    <div className="flex flex-col gap-0.5 text-xs">
      {visible.map((item, i) => (
        <span key={i} className="break-words">
          {item.name} × {item.quantity}
        </span>
      ))}
      {hidden > 0 ? (
        <button
          type="button"
          onClick={() => setExpanded(true)}
          className="text-left font-medium text-primary hover:underline"
        >
          Ver más (+{hidden})
        </button>
      ) : null}
    </div>
  );
}

const STATUS_LABEL: Record<SaleBillingStatus, string> = {
  NOT_REQUIRED: "No requiere",
  PENDING: "Pendiente de facturación",
  INVOICED: "Facturada",
};
const STATUS_VARIANT: Record<SaleBillingStatus, "secondary" | "warning" | "success"> = {
  NOT_REQUIRED: "secondary",
  PENDING: "warning",
  INVOICED: "success",
};

export function BillingTable({ rows, showInvoicedColumns }: { rows: BillingRow[]; showInvoicedColumns: boolean }) {
  const router = useRouter();
  const [target, setTarget] = useState<BillingRow | null>(null);
  const [reverting, setReverting] = useState<string | null>(null);

  async function handleRevert(saleId: string) {
    if (!window.confirm("¿Volver esta operación a pendiente de facturación? Se registra en la auditoría.")) return;
    setReverting(saleId);
    const supabase = createClient();
    const { error } = await supabase.rpc("mark_sale_pending", { p_sale_id: saleId });
    setReverting(null);

    if (error) {
      toast.error(error.message);
      return;
    }
    toast.success("La operación vuelve a quedar pendiente de facturación.");
    router.refresh();
  }

  return (
    <>
      <div className="overflow-x-auto rounded-xl border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Fecha</TableHead>
              <TableHead>Cliente</TableHead>
              <TableHead>DNI</TableHead>
              <TableHead>Detalle</TableHead>
              <TableHead className="text-right">Importe</TableHead>
              <TableHead>Cuenta</TableHead>
              <TableHead>Pago</TableHead>
              <TableHead>Estado</TableHead>
              {showInvoicedColumns ? <TableHead>Facturada</TableHead> : null}
              <TableHead className="text-right">Acción</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow key={row.id}>
                <TableCell className="text-sm">{formatDateTime(row.sold_at)}</TableCell>
                <TableCell className="text-sm font-medium">{row.customer?.full_name ?? "—"}</TableCell>
                <TableCell className="text-sm text-muted-foreground">{row.customer?.dni ?? "—"}</TableCell>
                <TableCell className="max-w-56 whitespace-normal align-top">
                  <DetailCell items={row.items} />
                </TableCell>
                <TableCell className="text-right text-sm font-medium tabular-nums">
                  {formatCurrency(Number(row.total))}
                </TableCell>
                <TableCell className="text-sm">{row.accountName ?? "—"}</TableCell>
                <TableCell className="text-sm">{row.paymentName ?? "—"}</TableCell>
                <TableCell>
                  <Badge variant={STATUS_VARIANT[row.billing_status]}>{STATUS_LABEL[row.billing_status]}</Badge>
                </TableCell>
                {showInvoicedColumns ? (
                  <TableCell className="text-xs text-muted-foreground">
                    {row.invoiced_at ? (
                      <>
                        {formatDateTime(row.invoiced_at)}
                        {row.invoicedByName ? <div>{row.invoicedByName}</div> : null}
                      </>
                    ) : (
                      "—"
                    )}
                  </TableCell>
                ) : null}
                <TableCell className="text-right">
                  {row.billing_status === "PENDING" ? (
                    <Button size="sm" onClick={() => setTarget(row)}>
                      <Receipt /> Marcar facturada
                    </Button>
                  ) : row.billing_status === "INVOICED" ? (
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={reverting === row.id}
                      onClick={() => handleRevert(row.id)}
                    >
                      {reverting === row.id ? <Loader2 className="animate-spin" /> : <RotateCcw />}
                      Volver a pendiente
                    </Button>
                  ) : null}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>

      {target ? <MarkInvoicedDialog row={target} onClose={() => setTarget(null)} /> : null}
    </>
  );
}

function MarkInvoicedDialog({ row, onClose }: { row: BillingRow; onClose: () => void }) {
  const router = useRouter();
  const [saving, setSaving] = useState(false);

  async function handleConfirm() {
    setSaving(true);
    const supabase = createClient();
    const { error } = await supabase.rpc("mark_sale_invoiced", { p_sale_id: row.id });
    setSaving(false);

    if (error) {
      toast.error(error.message);
      return;
    }

    toast.success("Operación marcada como facturada.");
    onClose();
    router.refresh();
  }

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>¿Confirmás que esta operación ya fue facturada?</DialogTitle>
          <DialogDescription>{row.sale_number}</DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-1.5 rounded-lg border border-border bg-muted/40 p-3 text-sm">
          <div className="flex justify-between">
            <span className="text-muted-foreground">Cliente</span>
            <span className="font-medium">{row.customer?.full_name ?? "—"}</span>
          </div>
          <div className="flex justify-between">
            <span className="text-muted-foreground">DNI</span>
            <span className="font-medium">{row.customer?.dni ?? "—"}</span>
          </div>
          <div className="flex justify-between">
            <span className="text-muted-foreground">Importe</span>
            <span className="font-semibold">{formatCurrency(Number(row.total))}</span>
          </div>
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>
            Cancelar
          </Button>
          <Button onClick={handleConfirm} disabled={saving}>
            {saving ? <Loader2 className="animate-spin" /> : null}
            Marcar como facturada
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
