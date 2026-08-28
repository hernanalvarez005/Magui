"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2, PenLine } from "lucide-react";
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

const REASON_LABELS: Record<string, string> = {
  RECEPTION: "Recepción de mercadería",
  BREAKAGE: "Rotura",
  EXPIRATION: "Vencimiento",
  COUNT_DIFFERENCE: "Diferencia de conteo",
  RETURN: "Devolución",
  OTHER: "Otro",
};

export function SetStockDialog({
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
  const [currentStock, setCurrentStock] = useState<number | null>(null);
  const [newQuantity, setNewQuantity] = useState("");
  const [reason, setReason] = useState("COUNT_DIFFERENCE");
  const [notes, setNotes] = useState("");
  const [loading, setLoading] = useState(false);
  const [confirmStep, setConfirmStep] = useState(false);

  useEffect(() => {
    let cancelled = false;

    if (!locationId || !productId) {
      // Se difiere via microtask (no se llama a setState en forma sincrónica
      // dentro del cuerpo del efecto).
      Promise.resolve().then(() => {
        if (!cancelled) setCurrentStock(null);
      });
      return () => {
        cancelled = true;
      };
    }

    const supabase = createClient();
    supabase
      .from("product_stock_status")
      .select("quantity")
      .eq("location_id", locationId)
      .eq("product_id", productId)
      .maybeSingle()
      .then(({ data }) => {
        if (!cancelled) setCurrentStock(data ? Number(data.quantity) : 0);
      });
    return () => {
      cancelled = true;
    };
  }, [locationId, productId]);

  const diff = currentStock !== null && newQuantity !== "" ? Number(newQuantity) - currentStock : null;

  async function handleConfirm() {
    const qty = Number(newQuantity);
    if (Number.isNaN(qty) || qty < 0) {
      toast.error("Ingresá un stock final válido (0 o mayor).");
      return;
    }

    setLoading(true);
    const supabase = createClient();
    const { data, error } = await supabase.rpc("set_stock", {
      p_location_id: locationId,
      p_product_id: productId,
      p_new_quantity: qty,
      p_reason: reason as never,
      p_notes: notes || null,
    });
    setLoading(false);

    if (error) {
      toast.error(error.message);
      return;
    }

    if (!data?.changed) {
      toast.info("El stock ya estaba en ese valor, no se registró ningún movimiento.");
    } else {
      toast.success(`Stock actualizado: ${data.stock_before} → ${data.stock_after}.`);
    }
    setOpen(false);
    setConfirmStep(false);
    setProductId("");
    setNewQuantity("");
    setNotes("");
    router.refresh();
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(o) => {
        setOpen(o);
        if (!o) setConfirmStep(false);
      }}
    >
      <DialogTrigger asChild>
        <Button variant="outline">
          <PenLine /> Establecer stock
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Establecer stock final</DialogTitle>
          <DialogDescription>
            Solo administradores. Se calcula la diferencia contra el stock actual y queda un
            movimiento auditable — no es un ajuste &quot;a ciegas&quot;.
          </DialogDescription>
        </DialogHeader>

        {!confirmStep ? (
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
              {productId && currentStock !== null ? (
                <p className="text-sm text-muted-foreground">Stock actual: {currentStock}</p>
              ) : null}
            </div>

            <div className="flex flex-col gap-1.5">
              <Label>Stock final</Label>
              <Input
                type="number"
                min={0}
                step="1"
                value={newQuantity}
                onChange={(e) => setNewQuantity(e.target.value)}
              />
              {diff !== null && diff !== 0 ? (
                <p className={diff > 0 ? "text-sm text-success-foreground" : "text-sm text-destructive"}>
                  Movimiento: {diff > 0 ? "+" : ""}
                  {diff}
                </p>
              ) : null}
            </div>

            <div className="flex flex-col gap-1.5">
              <Label>Motivo</Label>
              <Select value={reason} onValueChange={setReason}>
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
        ) : (
          <div className="rounded-lg bg-warning/15 p-4 text-sm">
            <p className="font-medium">Vas a registrar este movimiento:</p>
            <p className="mt-2">
              {products.find((p) => p.id === productId)?.name} en{" "}
              {locations.find((l) => l.id === locationId)?.name}
            </p>
            <p className="mt-1">
              Stock actual: <strong>{currentStock}</strong> → Stock nuevo: <strong>{newQuantity}</strong>{" "}
              ({diff !== null && diff > 0 ? "+" : ""}
              {diff})
            </p>
            <p className="mt-2 text-muted-foreground">Esta acción no se puede deshacer.</p>
          </div>
        )}

        <DialogFooter>
          {!confirmStep ? (
            <>
              <Button variant="ghost" onClick={() => setOpen(false)}>
                Cancelar
              </Button>
              <Button
                onClick={() => setConfirmStep(true)}
                disabled={!productId || newQuantity === "" || diff === 0}
              >
                Continuar
              </Button>
            </>
          ) : (
            <>
              <Button variant="ghost" onClick={() => setConfirmStep(false)}>
                Volver
              </Button>
              <Button onClick={handleConfirm} disabled={loading}>
                {loading ? <Loader2 className="animate-spin" /> : null}
                Confirmar
              </Button>
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
