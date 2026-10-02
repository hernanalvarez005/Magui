"use client";

import { useEffect, useState } from "react";
import { Loader2 } from "lucide-react";
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
import { computeEligibleAutoPricingRows, type EligibleAutoPricingRow } from "@/lib/pricing/activate-auto-pricing";

/**
 * "Activar automático" por condición (bootstrap de AUTO sobre lo histórico,
 * que la migración 74 dejó en MANUAL). Preview explícito, nunca escribe
 * nada hasta confirmar: carga, por cada producto activo con Lista vigente
 * y esta condición en MANUAL o sin precio, el precio AUTO resultante (misma
 * fórmula suggestDiscountedPrice que ya usa la Matriz — no se reimplementa
 * ningún cálculo nuevo acá). Confirmar manda SOLO los tildados como
 * p_reset_to_auto en una única llamada a save_price_matrix_changes — el
 * servidor recalcula con los valores vigentes en ese momento, nunca confía
 * en este preview. Cerrar/cancelar no escribe nada. Nunca toca otras
 * condiciones; los productos destildados quedan exactamente como estaban.
 */
export function ActivateAutoPricingDialog({
  conditionId,
  conditionName,
  discountPercent,
  open,
  onOpenChange,
  onActivated,
}: {
  conditionId: string;
  conditionName: string;
  /** Fracción 0-1, igual que price_conditions.discount_percent. */
  discountPercent: number;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onActivated: () => void;
}) {
  const [loading, setLoading] = useState(true);
  const [rows, setRows] = useState<EligibleAutoPricingRow[]>([]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    let cancelled = false;

    (async () => {
      setLoading(true);
      setRows([]);
      setSelected(new Set());

      const supabase = createClient();
      const [{ data: products }, { data: baseCondition }, { data: prices }] = await Promise.all([
        supabase.from("products").select("id, sku, name").eq("active", true).order("name"),
        supabase.from("price_conditions").select("id").eq("rule_type", "BASE").single(),
        supabase.from("product_prices").select("product_id, price_condition_id, amount, pricing_mode").eq("active", true),
      ]);
      if (cancelled) return;

      const eligible = computeEligibleAutoPricingRows(
        products ?? [],
        prices ?? [],
        baseCondition?.id,
        conditionId,
        discountPercent
      );

      setRows(eligible);
      setSelected(new Set(eligible.map((r) => r.product_id)));
      setLoading(false);
    })();

    return () => {
      cancelled = true;
    };
  }, [open, conditionId, discountPercent]);

  function toggle(productId: string) {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(productId)) next.delete(productId);
      else next.add(productId);
      return next;
    });
  }

  async function handleConfirm() {
    const chosen = rows.filter((r) => selected.has(r.product_id));
    if (chosen.length === 0) {
      toast.info("No seleccionaste ningún producto.");
      return;
    }
    setSaving(true);
    const supabase = createClient();
    const { error } = await supabase.rpc("save_price_matrix_changes", {
      p_reset_to_auto: chosen.map((r) => ({ product_id: r.product_id, price_condition_id: conditionId })),
    });
    setSaving(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    toast.success(`${chosen.length} producto${chosen.length === 1 ? "" : "s"} activado${chosen.length === 1 ? "" : "s"} en automático para "${conditionName}".`);
    onActivated();
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[85vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>Activar automático — {conditionName}</DialogTitle>
          <DialogDescription>
            Solo productos con Precio de Lista vigente y esta condición en Manual o sin configurar. Nada se
            guarda hasta que confirmes — podés destildar los productos que quieras dejar como están.
          </DialogDescription>
        </DialogHeader>

        {loading ? (
          <div className="flex justify-center py-8">
            <Loader2 className="animate-spin" />
          </div>
        ) : rows.length === 0 ? (
          <p className="py-6 text-center text-sm text-muted-foreground">
            No hay productos elegibles — todos ya están en AUTO bajo esta condición, o ninguno tiene Precio
            de Lista vigente.
          </p>
        ) : (
          <div className="rounded-xl border border-border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="w-10" />
                  <TableHead>Producto</TableHead>
                  <TableHead className="text-right">Lista vigente</TableHead>
                  <TableHead className="text-right">Precio actual</TableHead>
                  <TableHead className="text-right">Precio automático</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.product_id}>
                    <TableCell>
                      <input
                        type="checkbox"
                        checked={selected.has(row.product_id)}
                        onChange={() => toggle(row.product_id)}
                      />
                    </TableCell>
                    <TableCell>
                      <p className="font-medium">{row.name}</p>
                      <p className="text-xs text-muted-foreground">{row.sku}</p>
                    </TableCell>
                    <TableCell className="text-right">{row.list_amount}</TableCell>
                    <TableCell className="text-right">
                      {row.current_amount !== null ? (
                        <>
                          {row.current_amount} <Badge variant="secondary">Manual</Badge>
                        </>
                      ) : (
                        <span className="text-muted-foreground">Sin configurar</span>
                      )}
                    </TableCell>
                    <TableCell className="text-right font-medium">{row.auto_amount}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}

        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)} disabled={saving}>
            Cancelar
          </Button>
          <Button onClick={handleConfirm} disabled={saving || loading || rows.length === 0}>
            {saving ? <Loader2 className="animate-spin" /> : null}
            Confirmar activación ({selected.size})
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
