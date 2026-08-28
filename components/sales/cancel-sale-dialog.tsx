"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Ban, Loader2 } from "lucide-react";
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
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { createClient } from "@/lib/supabase/client";
import { cancelSaleSchema } from "@/lib/validation/sale";

export function CancelSaleDialog({ saleId, saleNumber }: { saleId: string; saleNumber: string }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [loading, setLoading] = useState(false);

  async function handleConfirm() {
    const parsed = cancelSaleSchema.safeParse({ sale_id: saleId, reason });
    if (!parsed.success) {
      toast.error(parsed.error.issues[0]?.message ?? "Contá el motivo de la cancelación.");
      return;
    }

    setLoading(true);
    const supabase = createClient();
    const { error } = await supabase.rpc("cancel_sale", {
      p_sale_id: parsed.data.sale_id,
      p_reason: parsed.data.reason,
    });
    setLoading(false);

    if (error) {
      toast.error(error.message);
      return;
    }

    toast.success("Venta cancelada. El stock fue repuesto.");
    setOpen(false);
    router.refresh();
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="destructive">
          <Ban /> Cancelar venta
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Cancelar {saleNumber}</DialogTitle>
          <DialogDescription>
            Esta acción repone el stock descontado y queda registrada. No se puede deshacer.
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-1.5">
          <Label htmlFor="reason">Motivo (obligatorio)</Label>
          <Textarea
            id="reason"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={3}
            placeholder="Ej: la clienta se arrepintió, error de carga, producto vencido…"
          />
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={() => setOpen(false)}>
            Volver
          </Button>
          <Button variant="destructive" onClick={handleConfirm} disabled={loading}>
            {loading ? <Loader2 className="animate-spin" /> : null}
            Confirmar cancelación
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
