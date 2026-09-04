"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { CheckCircle2, Loader2 } from "lucide-react";
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
import { createClient } from "@/lib/supabase/client";

/**
 * Pedido ya PAID: la única acción posible es entregar. Llama únicamente a
 * deliver_web_pickup (mismo patrón que cancel-sale-dialog.tsx) — nunca toca
 * stock desde el frontend, eso lo hace la RPC (fn_apply_stock_movement por
 * dentro, sobre las reservas ACTIVE del pedido).
 */
export function DeliverPickupDialog({ saleId, saleNumber }: { saleId: string; saleNumber: string }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);

  async function handleConfirm() {
    setLoading(true);
    const supabase = createClient();
    const { error } = await supabase.rpc("deliver_web_pickup", { p_sale_id: saleId });
    setLoading(false);

    if (error) {
      toast.error(error.message);
      return;
    }

    toast.success("Pedido entregado. El stock reservado ya se descontó.");
    setOpen(false);
    router.refresh();
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button size="sm">
          <CheckCircle2 /> Marcar como entregado
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Entregar {saleNumber}</DialogTitle>
          <DialogDescription>
            Se descuenta el stock reservado de la sede y el pedido queda registrado como entregado. No se puede
            deshacer.
          </DialogDescription>
        </DialogHeader>

        <DialogFooter>
          <Button variant="ghost" onClick={() => setOpen(false)}>
            Volver
          </Button>
          <Button onClick={handleConfirm} disabled={loading}>
            {loading ? <Loader2 className="animate-spin" /> : null}
            Confirmar entrega
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
