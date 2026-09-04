"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { CircleDollarSign, Loader2 } from "lucide-react";
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
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { createClient } from "@/lib/supabase/client";
import { paymentMethodRequiresBilling } from "@/lib/sales/web-fulfillment";

interface PaymentMethodOption {
  id: string;
  code: string;
  name: string;
}

interface PaymentAccountOption {
  id: string;
  code: string;
  name: string;
  alias: string | null;
}

/**
 * Pedido PENDING de cobro: "Cobrar y entregar" en una sola acción, sin
 * ninguna RPC nueva — llama mark_web_order_paid y, si sale bien,
 * deliver_web_pickup a continuación (dos llamadas secuenciales del
 * frontend, cada una atómica de por sí en el backend). Si el cobro falla,
 * nunca se intenta entregar. Si el cobro sale bien pero la entrega falla
 * (caso raro — otra usuaria entregó/canceló justo en el medio), el pedido
 * queda PAID y la tarjeta, al refrescar, pasa a mostrar "Marcar como
 * entregado" sola — no se pierde nada, se reintenta desde ahí.
 */
export function MarkPaidAndDeliverDialog({
  saleId,
  saleNumber,
  currentPaymentMethodId,
  currentPaymentAccountId,
  paymentMethods,
  paymentAccounts,
}: {
  saleId: string;
  saleNumber: string;
  currentPaymentMethodId: string;
  currentPaymentAccountId: string | null;
  paymentMethods: PaymentMethodOption[];
  paymentAccounts: PaymentAccountOption[];
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [paymentMethodId, setPaymentMethodId] = useState(currentPaymentMethodId);
  const [paymentAccountId, setPaymentAccountId] = useState(currentPaymentAccountId ?? "");

  const selectedMethod = paymentMethods.find((pm) => pm.id === paymentMethodId);
  const requiresAccount = paymentMethodRequiresBilling(selectedMethod?.code);

  function handlePaymentMethodChange(id: string) {
    setPaymentMethodId(id);
    if (!paymentMethodRequiresBilling(paymentMethods.find((pm) => pm.id === id)?.code)) {
      setPaymentAccountId("");
    }
  }

  async function handleConfirm() {
    if (requiresAccount && !paymentAccountId) {
      toast.error("Elegí la cuenta donde ingresó el dinero.");
      return;
    }

    setLoading(true);
    const supabase = createClient();

    const { error: paidError } = await supabase.rpc("mark_web_order_paid", {
      p_sale_id: saleId,
      p_payment_method_id: paymentMethodId,
      p_payment_account_id: paymentAccountId || null,
    });
    if (paidError) {
      setLoading(false);
      toast.error(paidError.message);
      return;
    }

    const { error: deliverError } = await supabase.rpc("deliver_web_pickup", { p_sale_id: saleId });
    setLoading(false);

    if (deliverError) {
      toast.error(`Se registró el cobro, pero la entrega falló: ${deliverError.message}`);
      setOpen(false);
      router.refresh();
      return;
    }

    toast.success("Cobro registrado y pedido entregado.");
    setOpen(false);
    router.refresh();
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button size="sm">
          <CircleDollarSign /> Cobrar y entregar
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Cobrar {saleNumber}</DialogTitle>
          <DialogDescription>
            Confirmá cómo se cobró este pedido. Si corresponde, el pedido se entrega automáticamente a continuación.
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-3">
          <div className="flex flex-col gap-1.5">
            <Label>Medio de pago</Label>
            <Select value={paymentMethodId} onValueChange={handlePaymentMethodChange}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {paymentMethods.map((pm) => (
                  <SelectItem key={pm.id} value={pm.id}>
                    {pm.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          {requiresAccount ? (
            <div className="flex flex-col gap-1.5">
              <Label>Cuenta donde ingresó el dinero</Label>
              <Select value={paymentAccountId} onValueChange={setPaymentAccountId}>
                <SelectTrigger>
                  <SelectValue placeholder="Elegí la cuenta" />
                </SelectTrigger>
                <SelectContent>
                  {paymentAccounts.map((pa) => (
                    <SelectItem key={pa.id} value={pa.id}>
                      {pa.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          ) : null}
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={() => setOpen(false)}>
            Volver
          </Button>
          <Button onClick={handleConfirm} disabled={loading}>
            {loading ? <Loader2 className="animate-spin" /> : null}
            Confirmar cobro
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
