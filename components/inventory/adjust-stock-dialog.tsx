"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2, SlidersHorizontal } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { createClient } from "@/lib/supabase/client";
import { adjustStockSchema } from "@/lib/validation/sale";
import type { StockAdjustmentReason } from "@/types/database";

const REASON_LABELS: Record<StockAdjustmentReason, string> = {
  RECEPTION: "Recepción de mercadería",
  BREAKAGE: "Rotura",
  EXPIRATION: "Vencimiento",
  COUNT_DIFFERENCE: "Diferencia de conteo",
  RETURN: "Devolución",
  OTHER: "Otro",
};

export function AdjustStockDialog({
  locations,
  products,
  defaultLocationId,
}: {
  locations: { id: string; name: string }[];
  products: { id: string; name: string; sku: string }[];
  defaultLocationId?: string;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [locationId, setLocationId] = useState(defaultLocationId ?? locations[0]?.id ?? "");
  const [productId, setProductId] = useState("");
  const [direction, setDirection] = useState<"PLUS" | "MINUS">("PLUS");
  const [quantity, setQuantity] = useState("");
  const [reason, setReason] = useState<StockAdjustmentReason>("RECEPTION");
  const [notes, setNotes] = useState("");
  const [loading, setLoading] = useState(false);

  async function handleSubmit() {
    const qty = Number(quantity);
    const delta = direction === "PLUS" ? qty : -qty;
    const parsed = adjustStockSchema.safeParse({
      location_id: locationId,
      product_id: productId,
      quantity_delta: delta,
      reason,
      notes: notes || null,
    });
    if (!parsed.success) {
      toast.error(parsed.error.issues[0]?.message ?? "Revisá los datos del ajuste.");
      return;
    }

    setLoading(true);
    const supabase = createClient();
    const { error } = await supabase.rpc("adjust_stock", {
      p_location_id: parsed.data.location_id,
      p_product_id: parsed.data.product_id,
      p_quantity_delta: parsed.data.quantity_delta,
      p_reason: parsed.data.reason,
      p_notes: parsed.data.notes,
    });
    setLoading(false);

    if (error) {
      toast.error(error.message);
      return;
    }

    toast.success("Ajuste registrado.");
    setOpen(false);
    setQuantity("");
    setNotes("");
    router.refresh();
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline">
          <SlidersHorizontal /> Nuevo ajuste
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Nuevo ajuste de stock</DialogTitle>
          <DialogDescription>Todo ajuste queda registrado con usuario, fecha y motivo.</DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-3">
          <div className="flex flex-col gap-1.5">
            <Label>Sucursal</Label>
            <Select value={locationId} onValueChange={setLocationId}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {locations.map((l) => (
                  <SelectItem key={l.id} value={l.id}>
                    {l.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>Producto</Label>
            <Select value={productId} onValueChange={setProductId}>
              <SelectTrigger>
                <SelectValue placeholder="Seleccioná un producto" />
              </SelectTrigger>
              <SelectContent>
                {products.map((p) => (
                  <SelectItem key={p.id} value={p.id}>
                    {p.name} ({p.sku})
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="flex flex-col gap-1.5">
              <Label>Tipo</Label>
              <Select value={direction} onValueChange={(v) => setDirection(v as "PLUS" | "MINUS")}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="PLUS">Ingreso (+)</SelectItem>
                  <SelectItem value="MINUS">Egreso (−)</SelectItem>
                </SelectContent>
              </Select>
            </div>
            <div className="flex flex-col gap-1.5">
              <Label>Cantidad</Label>
              <Input
                type="number"
                min={0}
                step="1"
                value={quantity}
                onChange={(e) => setQuantity(e.target.value)}
              />
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>Motivo</Label>
            <Select value={reason} onValueChange={(v) => setReason(v as StockAdjustmentReason)}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {Object.entries(REASON_LABELS).map(([value, label]) => (
                  <SelectItem key={value} value={value}>
                    {label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>Observaciones (opcional)</Label>
            <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} rows={2} />
          </div>
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={() => setOpen(false)}>
            Cancelar
          </Button>
          <Button onClick={handleSubmit} disabled={loading || !productId || !quantity}>
            {loading ? <Loader2 className="animate-spin" /> : null}
            Registrar ajuste
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
