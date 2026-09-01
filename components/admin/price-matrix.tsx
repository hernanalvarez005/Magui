"use client";

import { Fragment, useMemo, useState } from "react";
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
import { suggestDiscountedPrice } from "@/lib/pricing/discount-suggestion";
import { classifyDirtyPriceCells, isPriceCellDirty } from "@/lib/pricing/price-matrix-changes";
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
  discount_percent: string | null;
}
interface PriceCell {
  id: string;
  product_id: string;
  price_condition_id: string;
  amount: string;
}

// Bloque E: Efectivo y Transferencia tienen además un % configurable
// (price_conditions.discount_percent, ya existía como campo "informativo" —
// acá pasa a alimentar de verdad la sugerencia) que sugiere el precio al
// tocar la Lista o el propio %. El precio final SIEMPRE queda editable a
// mano — el % nunca es la fuente de verdad de una venta, product_prices.amount
// sí lo es (fn_pricing_quote/fn_apply_promotions no leen discount_percent).
const SUGGESTABLE_CODES = ["CASH", "TRANSFER"];

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

  const originalPercent = useMemo(() => {
    const map = new Map<string, number>();
    for (const c of conditions) map.set(c.id, c.discount_percent ? Number(c.discount_percent) * 100 : 0);
    return map;
  }, [conditions]);

  const [edited, setEdited] = useState<Map<string, string>>(new Map());
  const [percentEdited, setPercentEdited] = useState<Map<string, string>>(new Map());
  const [saving, setSaving] = useState(false);

  const [proposeConditionId, setProposeConditionId] = useState(conditions.find((c) => c.code === "TRANSFER")?.id ?? "");
  const [proposePercent, setProposePercent] = useState("10");
  const listConditionId = conditions.find((c) => c.code === "LIST")?.id;
  const suggestableConditions = conditions.filter((c) => SUGGESTABLE_CODES.includes(c.code));

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

  function percentValueFor(conditionId: string): string {
    if (percentEdited.has(conditionId)) return percentEdited.get(conditionId)!;
    const pct = originalPercent.get(conditionId) ?? 0;
    return pct ? String(pct) : "";
  }

  /**
   * Sugiere (sobrescribe, sin bloquear la edición posterior) el precio de
   * cada condición "suggestable" para un producto puntual, a partir de su
   * Lista actual (editada o persistida) y el % actual (editado o
   * persistido) de cada condición — sección 4/5 del pedido: se dispara al
   * cambiar la Lista o el % correspondiente, nunca solo por tipear en el
   * propio campo de precio final.
   */
  function suggestForProduct(productId: string, listAmount: number) {
    if (!Number.isFinite(listAmount) || listAmount < 0) return;
    setEdited((prev) => {
      const next = new Map(prev);
      for (const cond of suggestableConditions) {
        const pct = Number(percentValueFor(cond.id) || 0);
        if (!Number.isFinite(pct)) continue;
        next.set(cellKey(productId, cond.id), String(suggestDiscountedPrice(listAmount, pct)));
      }
      return next;
    });
  }

  function handleListChange(productId: string, value: string) {
    setValue(productId, listConditionId!, value);
    const listAmount = Number(value);
    if (value.trim() !== "" && Number.isFinite(listAmount)) suggestForProduct(productId, listAmount);
  }

  function handlePercentChange(conditionId: string, value: string) {
    setPercentEdited((prev) => {
      const next = new Map(prev);
      next.set(conditionId, value);
      return next;
    });
    const pct = Number(value);
    if (!listConditionId || value.trim() === "" || !Number.isFinite(pct)) return;
    // Recalcula esta condición para TODOS los productos, usando la Lista
    // actual (editada o persistida) de cada uno.
    setEdited((prev) => {
      const next = new Map(prev);
      for (const product of products) {
        const listRaw = prev.get(cellKey(product.id, listConditionId));
        const listAmount = listRaw !== undefined ? Number(listRaw) : original.get(cellKey(product.id, listConditionId));
        if (listAmount === undefined || !Number.isFinite(listAmount)) continue;
        next.set(cellKey(product.id, conditionId), String(suggestDiscountedPrice(listAmount, pct)));
      }
      return next;
    });
  }

  function isDirty(productId: string, conditionId: string) {
    const key = cellKey(productId, conditionId);
    if (!edited.has(key)) return false;
    // Misma normalización que classifyDirtyPriceCells (bugfix: "no hay
    // cambios para guardar" pasaba porque acá se comparaba distinto que en
    // el guardado — ver lib/pricing/price-matrix-changes.ts).
    return isPriceCellDirty(edited.get(key)!, original.get(key));
  }

  function isPercentDirty(conditionId: string) {
    if (!percentEdited.has(conditionId)) return false;
    const current = percentEdited.get(conditionId);
    const originalValue = originalPercent.get(conditionId) ?? 0;
    return current !== (originalValue ? String(originalValue) : "");
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
        const proposed = suggestDiscountedPrice(list, pct);
        next.set(cellKey(product.id, proposeConditionId), String(proposed));
      }
      return next;
    });
    toast.info("Precios propuestos cargados. Revisalos y ajustá antes de guardar.");
  }

  async function handleSave() {
    // Única fuente de verdad para "qué cambió" — el mismo cálculo que
    // alimenta dirtyCount/isDirty más abajo, así que ya no pueden divergir
    // (esa era la causa raíz del "No hay cambios para guardar" a pesar de
    // haber una edición real: acá se usaba un filtro, dirtyCount otro).
    const { toSave, toClear, invalid } = classifyDirtyPriceCells(edited, original);
    const dirtyPercents = suggestableConditions.filter((c) => isPercentDirty(c.id));

    if (toSave.length === 0 && toClear.length === 0 && invalid.length === 0 && dirtyPercents.length === 0) {
      toast.info("No hay cambios para guardar.");
      return;
    }

    setSaving(true);
    const supabase = createClient();
    let successCount = 0;
    let errorMessage: string | null = null;
    // Solo se limpian del estado local las celdas que efectivamente se
    // guardaron — si algo falla (RPC, error de red, validación), esa
    // edición queda escrita para poder reintentar en vez de perderse.
    const succeededKeys = new Set<string>();
    const succeededPercentIds = new Set<string>();

    // Los % se guardan primero (columna simple en price_conditions, sin
    // versionado — no son la fuente de verdad de ninguna venta, solo la
    // sugerencia para la próxima edición).
    for (const cond of dirtyPercents) {
      const pct = Number(percentValueFor(cond.id));
      if (Number.isNaN(pct) || pct < 0 || pct > 100) {
        errorMessage = `El porcentaje "${percentValueFor(cond.id)}" de ${cond.name} tiene que estar entre 0 y 100.`;
        continue;
      }
      const { error } = await supabase
        .from("price_conditions")
        .update({ discount_percent: String(pct / 100) })
        .eq("id", cond.id);
      if (error) errorMessage = error.message;
      else {
        successCount++;
        succeededPercentIds.add(cond.id);
      }
    }

    for (const { key, amount } of toSave) {
      const [productId, conditionId] = key.split(":");
      const { error } = await supabase.rpc("set_product_price", {
        p_product_id: productId,
        p_price_condition_id: conditionId,
        p_amount: amount,
      });
      if (error) {
        errorMessage = error.message;
      } else {
        successCount++;
        succeededKeys.add(key);
      }
    }

    // Precio existente que se dejó vacío: se desactiva la vigencia (nunca
    // se guarda $0) — ver 20260201000029_clear_product_price.sql.
    for (const { key } of toClear) {
      const [productId, conditionId] = key.split(":");
      const { error } = await supabase.rpc("clear_product_price", {
        p_product_id: productId,
        p_price_condition_id: conditionId,
      });
      if (error) {
        errorMessage = error.message;
      } else {
        successCount++;
        succeededKeys.add(key);
      }
    }

    setSaving(false);
    setEdited((prev) => {
      const next = new Map(prev);
      for (const key of succeededKeys) next.delete(key);
      return next;
    });
    setPercentEdited((prev) => {
      const next = new Map(prev);
      for (const id of succeededPercentIds) next.delete(id);
      return next;
    });

    if (successCount > 0) toast.success(`${successCount} cambio(s) guardados.`);
    if (invalid.length > 0) {
      toast.error(
        invalid.length === 1
          ? `El precio "${invalid[0].rawValue}" no es válido — tiene que ser un número mayor a 0.`
          : `${invalid.length} precios no son válidos — tienen que ser un número mayor a 0.`
      );
    }
    if (errorMessage) toast.error(errorMessage);
    router.refresh();
  }

  const { toSave: dirtyToSave, toClear: dirtyToClear, invalid: dirtyInvalid } = classifyDirtyPriceCells(
    edited,
    original
  );
  const dirtyCount =
    dirtyToSave.length + dirtyToClear.length + dirtyInvalid.length + suggestableConditions.filter((c) => isPercentDirty(c.id)).length;

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
          Aplica este % una sola vez a todos los productos de la condición elegida (útil para una carga
          inicial). Para Efectivo y Transferencia también podés dejar el % fijo abajo: ahí se vuelve a
          sugerir automáticamente cada vez que cambiés la Lista de un producto.
        </p>
      </div>

      <div className="overflow-x-auto rounded-xl border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="sticky left-0 bg-card">Producto</TableHead>
              {conditions.map((c) =>
                SUGGESTABLE_CODES.includes(c.code) ? (
                  <Fragment key={c.id}>
                    <TableHead className="text-right">{c.name} %</TableHead>
                    <TableHead className="text-right">{c.name}</TableHead>
                  </Fragment>
                ) : (
                  <TableHead key={c.id} className="text-right">
                    {c.name}
                  </TableHead>
                )
              )}
            </TableRow>
          </TableHeader>
          <TableBody>
            {/* Fila del % por condición — Efectivo y Transferencia únicamente
                (sección 1/7 del pedido). Es una única fila porque el % es
                global por condición, no por producto. */}
            <TableRow className="bg-muted/40">
              <TableCell className="sticky left-0 bg-muted/40 text-xs text-muted-foreground">
                % OFF sobre Lista (aplica a todos los productos)
              </TableCell>
              {conditions.map((c) =>
                SUGGESTABLE_CODES.includes(c.code) ? (
                  <Fragment key={c.id}>
                    <TableCell className="text-right">
                      <div className="ml-auto flex w-28 items-center justify-end gap-1">
                        <Input
                          type="number"
                          min={0}
                          max={100}
                          className={cn("h-8 text-right", isPercentDirty(c.id) && "border-primary ring-1 ring-primary")}
                          value={percentValueFor(c.id)}
                          onChange={(e) => handlePercentChange(c.id, e.target.value)}
                        />
                        <span className="text-xs text-muted-foreground">%</span>
                      </div>
                    </TableCell>
                    <TableCell />
                  </Fragment>
                ) : (
                  <TableCell key={c.id} />
                )
              )}
            </TableRow>

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
                {conditions.map((c) => {
                  const isList = c.id === listConditionId;
                  const cell = (
                    <Input
                      type="number"
                      className={cn(
                        "ml-auto h-8 w-28 text-right",
                        isDirty(product.id, c.id) && "border-primary ring-1 ring-primary"
                      )}
                      placeholder="—"
                      value={valueFor(product.id, c.id)}
                      onChange={(e) =>
                        isList ? handleListChange(product.id, e.target.value) : setValue(product.id, c.id, e.target.value)
                      }
                    />
                  );
                  return SUGGESTABLE_CODES.includes(c.code) ? (
                    <Fragment key={c.id}>
                      <TableCell />
                      <TableCell className="text-right">{cell}</TableCell>
                    </Fragment>
                  ) : (
                    <TableCell key={c.id} className="text-right">
                      {cell}
                    </TableCell>
                  );
                })}
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
