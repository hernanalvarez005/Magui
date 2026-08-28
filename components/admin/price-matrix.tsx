"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Save, Wand2 } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { createClient } from "@/lib/supabase/client";
import { cn } from "@/lib/utils";

interface ProductRow {
  id: string;
  sku: string;
  name: string;
  active: boolean;
}
interface ConditionCol {
  id: string;
  code: string;
  name: string;
  priority: number;
}
interface PriceCell {
  id: string;
  product_id: string;
  price_condition_id: string;
  amount: string;
}

function cellKey(productId: string, conditionId: string) {
  return `${productId}:${conditionId}`;
}

export function PriceMatrix({
  products,
  conditions,
  prices,
}: {
  products: ProductRow[];
  conditions: ConditionCol[];
  prices: PriceCell[];
}) {
  const router = useRouter();

  const original = useMemo(() => {
    const map = new Map<string, number>();
    for (const p of prices) map.set(cellKey(p.product_id, p.price_condition_id), Number(p.amount));
    return map;
  }, [prices]);

  const [edited, setEdited] = useState<Map<string, string>>(new Map());
  const [saving, setSaving] = useState(false);

  const [proposeConditionId, setProposeConditionId] = useState(conditions.find((c) => c.code === "TRANSFER")?.id ?? "");
  const [proposePercent, setProposePercent] = useState("10");
  const listConditionId = conditions.find((c) => c.code === "LIST")?.id;

  function valueFor(productId: string, conditionId: string): string {
    const key = cellKey(productId, conditionId);
    if (edited.has(key)) return edited.get(key)!;
    const amount = original.get(key);
    return amount !== undefined ? String(amount) : "";
  }

  function setValue(productId: string, conditionId: string, value: string) {
    setEdited((prev) => {
      const next = new Map(prev);
      next.set(cellKey(productId, conditionId), value);
      return next;
    });
  }

  function isDirty(productId: string, conditionId: string) {
    const key = cellKey(productId, conditionId);
    if (!edited.has(key)) return false;
    const current = edited.get(key);
    const originalValue = original.get(key);
    return current !== (originalValue !== undefined ? String(originalValue) : "");
  }

  function applyProposal() {
    if (!listConditionId || !proposeConditionId) return;
    const pct = Number(proposePercent);
    if (Number.isNaN(pct)) {
      toast.error("Ingresá un porcentaje válido.");
      return;
    }
    setEdited((prev) => {
      const next = new Map(prev);
      for (const product of products) {
        const list = original.get(cellKey(product.id, listConditionId));
        if (list === undefined) continue;
        const proposed = Math.round(list * (1 - pct / 100) * 100) / 100;
        next.set(cellKey(product.id, proposeConditionId), String(proposed));
      }
      return next;
    });
    toast.info("Precios propuestos cargados. Revisalos y ajustá antes de guardar.");
  }

  async function handleSave() {
    const dirtyEntries = Array.from(edited.entries()).filter(([key, value]) => {
      const original_ = original.get(key);
      return value !== (original_ !== undefined ? String(original_) : "") && value.trim() !== "";
    });

    if (dirtyEntries.length === 0) {
      toast.info("No hay cambios para guardar.");
      return;
    }

    setSaving(true);
    const supabase = createClient();
    let successCount = 0;
    let errorMessage: string | null = null;

    for (const [key, value] of dirtyEntries) {
      const [productId, conditionId] = key.split(":");
      const amount = Number(value);
      if (Number.isNaN(amount) || amount <= 0) {
        errorMessage = `El precio "${value}" no es válido.`;
        continue;
      }
      const { error } = await supabase.rpc("set_product_price", {
        p_product_id: productId,
        p_price_condition_id: conditionId,
        p_amount: amount,
      });
      if (error) {
        errorMessage = error.message;
      } else {
        successCount++;
      }
    }

    setSaving(false);
    setEdited(new Map());

    if (successCount > 0) toast.success(`${successCount} precio(s) actualizados.`);
    if (errorMessage) toast.error(errorMessage);
    router.refresh();
  }

  const dirtyCount = Array.from(edited.entries()).filter(([key, value]) => {
    const original_ = original.get(key);
    return value !== (original_ !== undefined ? String(original_) : "");
  }).length;

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-end gap-2 rounded-xl border border-border bg-card p-3.5">
        <Wand2 className="mb-2 size-4 text-muted-foreground" />
        <div className="flex flex-col gap-1">
          <span className="text-xs text-muted-foreground">Aplicar porcentaje sobre lista a</span>
          <Select value={proposeConditionId} onValueChange={setProposeConditionId}>
            <SelectTrigger className="w-44">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {conditions
                .filter((c) => c.code !== "LIST")
                .map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {c.name}
                  </SelectItem>
                ))}
            </SelectContent>
          </Select>
        </div>
        <div className="flex flex-col gap-1">
          <span className="text-xs text-muted-foreground">% OFF</span>
          <Input
            type="number"
            className="w-24"
            value={proposePercent}
            onChange={(e) => setProposePercent(e.target.value)}
          />
        </div>
        <Button type="button" variant="outline" onClick={applyProposal}>
          Proponer precios
        </Button>
        <p className="basis-full text-xs text-muted-foreground">
          Ej: Lista $45.300 × 15% OFF = $38.505 — podés redondear a $38.500 antes de guardar.
        </p>
      </div>

      <div className="overflow-x-auto rounded-xl border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="sticky left-0 bg-card">Producto</TableHead>
              {conditions.map((c) => (
                <TableHead key={c.id} className="text-right">
                  {c.name}
                </TableHead>
              ))}
            </TableRow>
          </TableHeader>
          <TableBody>
            {products.map((product) => (
              <TableRow key={product.id}>
                <TableCell className="sticky left-0 bg-card font-medium">
                  {product.name}
                  {!product.active ? (
                    <Badge variant="outline" className="ml-2">
                      Inactivo
                    </Badge>
                  ) : null}
                  <p className="text-xs font-normal text-muted-foreground">{product.sku}</p>
                </TableCell>
                {conditions.map((c) => (
                  <TableCell key={c.id} className="text-right">
                    <Input
                      type="number"
                      className={cn(
                        "ml-auto h-8 w-28 text-right",
                        isDirty(product.id, c.id) && "border-primary ring-1 ring-primary"
                      )}
                      placeholder="—"
                      value={valueFor(product.id, c.id)}
                      onChange={(e) => setValue(product.id, c.id, e.target.value)}
                    />
                  </TableCell>
                ))}
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>

      <div className="sticky bottom-4 flex justify-end">
        <Button size="lg" onClick={handleSave} disabled={saving || dirtyCount === 0} className="shadow-lg">
          {saving ? <Loader2 className="animate-spin" /> : <Save />}
          Guardar cambios {dirtyCount > 0 ? `(${dirtyCount})` : ""}
        </Button>
      </div>
    </div>
  );
}
