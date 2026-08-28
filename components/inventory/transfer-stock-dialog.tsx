"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { ArrowRightLeft, Loader2, Plus, X } from "lucide-react";
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
import { createClient } from "@/lib/supabase/client";
import { transferStockSchema } from "@/lib/validation/sale";

interface TransferItem {
  product_id: string;
  quantity: string;
}

export function TransferStockDialog({
  locations,
  products,
}: {
  locations: { id: string; name: string }[];
  products: { id: string; name: string; sku: string }[];
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [fromLocationId, setFromLocationId] = useState(locations[0]?.id ?? "");
  const [toLocationId, setToLocationId] = useState(locations[1]?.id ?? locations[0]?.id ?? "");
  const [items, setItems] = useState<TransferItem[]>([{ product_id: "", quantity: "" }]);
  const [loading, setLoading] = useState(false);

  function updateItem(index: number, patch: Partial<TransferItem>) {
    setItems((prev) => prev.map((it, i) => (i === index ? { ...it, ...patch } : it)));
  }

  async function handleSubmit() {
    const parsed = transferStockSchema.safeParse({
      from_location_id: fromLocationId,
      to_location_id: toLocationId,
      items: items
        .filter((i) => i.product_id && i.quantity)
        .map((i) => ({ product_id: i.product_id, quantity: Number(i.quantity) })),
    });
    if (!parsed.success) {
      toast.error(parsed.error.issues[0]?.message ?? "Revisá los datos de la transferencia.");
      return;
    }
    if (parsed.data.from_location_id === parsed.data.to_location_id) {
      toast.error("La sucursal de origen y destino no pueden ser la misma.");
      return;
    }

    setLoading(true);
    const supabase = createClient();
    const { error } = await supabase.rpc("transfer_stock", {
      p_from_location_id: parsed.data.from_location_id,
      p_to_location_id: parsed.data.to_location_id,
      p_items: parsed.data.items,
      p_notes: parsed.data.notes ?? null,
    });
    setLoading(false);

    if (error) {
      toast.error(error.message);
      return;
    }

    toast.success("Transferencia registrada.");
    setOpen(false);
    setItems([{ product_id: "", quantity: "" }]);
    router.refresh();
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline">
          <ArrowRightLeft /> Transferir stock
        </Button>
      </DialogTrigger>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>Transferir stock entre sucursales</DialogTitle>
          <DialogDescription>La operación es atómica: descuenta en origen y suma en destino.</DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-3">
          <div className="grid grid-cols-2 gap-3">
            <div className="flex flex-col gap-1.5">
              <Label>Desde</Label>
              <Select value={fromLocationId} onValueChange={setFromLocationId}>
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
              <Label>Hacia</Label>
              <Select value={toLocationId} onValueChange={setToLocationId}>
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
          </div>

          <Label>Productos</Label>
          <div className="flex flex-col gap-2">
            {items.map((item, index) => (
              <div key={index} className="flex items-center gap-2">
                <Select value={item.product_id} onValueChange={(v) => updateItem(index, { product_id: v })}>
                  <SelectTrigger className="flex-1">
                    <SelectValue placeholder="Producto" />
                  </SelectTrigger>
                  <SelectContent>
                    {products.map((p) => (
                      <SelectItem key={p.id} value={p.id}>
                        {p.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <Input
                  type="number"
                  min={0}
                  className="w-20"
                  placeholder="Cant."
                  value={item.quantity}
                  onChange={(e) => updateItem(index, { quantity: e.target.value })}
                />
                <Button
                  variant="ghost"
                  size="icon"
                  onClick={() => setItems((prev) => prev.filter((_, i) => i !== index))}
                  disabled={items.length === 1}
                >
                  <X className="size-4" />
                </Button>
              </div>
            ))}
            <Button
              type="button"
              variant="ghost"
              size="sm"
              className="w-fit"
              onClick={() => setItems((prev) => [...prev, { product_id: "", quantity: "" }])}
            >
              <Plus className="size-4" /> Agregar producto
            </Button>
          </div>
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={() => setOpen(false)}>
            Cancelar
          </Button>
          <Button onClick={handleSubmit} disabled={loading}>
            {loading ? <Loader2 className="animate-spin" /> : null}
            Confirmar transferencia
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
