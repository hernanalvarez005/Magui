"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Save } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { createClient } from "@/lib/supabase/client";
import { isDiscountConfigurable, suggestDiscountedPrice } from "@/lib/pricing/discount-suggestion";
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
  rule_type: string;
  priority: number;
  discount_percent: string | null;
}
interface PriceCell {
  id: string;
  product_id: string;
  price_condition_id: string;
  amount: string;
  pricing_mode: "AUTO" | "MANUAL";
}

// rule_type === "PAYMENT_METHOD" exacto (isDiscountConfigurable) puede
// configurar su discount_percent, que ahora SÍ alimenta el precio real:
// Precio de Lista es el maestro — Lista o % cambian -> los precios AUTO de
// cada condición se recalculan solos (migración 74, Precio de Lista
// maestro). Un precio nunca se pisa si fue editado a mano (pricing_mode
// MANUAL, acá o preexistente): queda congelado hasta "Volver a automático",
// acción explícita por celda. Todo el guardado es una sola llamada atómica
// a save_price_matrix_changes — nunca N llamadas independientes.

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

  const originalMode = useMemo(() => {
    const map = new Map<string, "AUTO" | "MANUAL">();
    for (const p of prices) map.set(cellKey(p.product_id, p.price_condition_id), p.pricing_mode);
    return map;
  }, [prices]);

  const originalPercent = useMemo(() => {
    const map = new Map<string, number>();
    for (const c of conditions) map.set(c.id, c.discount_percent ? Number(c.discount_percent) * 100 : 0);
    return map;
  }, [conditions]);

  const [edited, setEdited] = useState<Map<string, string>>(new Map());
  const [percentEdited, setPercentEdited] = useState<Map<string, string>>(new Map());
  // Celdas que el admin tipeó directamente (no por el ripple de Lista/%) —
  // al guardar se mandan como manual_overrides, pasan a MANUAL. Nunca se
  // llenan por el cálculo automático, solo por el onChange del propio input.
  const [manuallyTouched, setManuallyTouched] = useState<Set<string>>(new Set());
  // "Volver a automático" — al guardar se manda como reset_to_auto; el
  // servidor recalcula con Lista/% vigentes en ese momento, nunca confía en
  // el preview local.
  const [resetToAuto, setResetToAuto] = useState<Set<string>>(new Set());
  const [saving, setSaving] = useState(false);

  const listConditionId = conditions.find((c) => c.code === "LIST")?.id;
  const suggestableConditions = conditions.filter(isDiscountConfigurable);

  /**
   * Única fuente de verdad para "¿tiene este producto un Precio de Lista
   * usable, y cuál es?" — Lista editada (preview) si existe, si no la
   * persistida. "" (campo Lista vaciado a mano) nunca cuenta como 0: debe
   * dar `undefined`, igual que "nunca tuvo Lista". Reusado por
   * handlePercentChange (elegibilidad de la cascada) y por hasListAmount
   * (acá abajo) — un solo criterio, nunca dos interpretaciones distintas.
   */
  function listAmountFor(productId: string): number | undefined {
    if (!listConditionId) return undefined;
    const key = cellKey(productId, listConditionId);
    const raw = edited.has(key) ? edited.get(key)! : original.has(key) ? String(original.get(key)) : undefined;
    if (raw === undefined || raw.trim() === "") return undefined;
    const amount = Number(raw);
    return Number.isFinite(amount) ? amount : undefined;
  }

  function hasListAmount(productId: string): boolean {
    return listAmountFor(productId) !== undefined;
  }

  /**
   * true si hay un % nuevo pendiente para esta condición que sea un número
   * válido y NO vacío — a propósito distinto de isPercentDirty (que da true
   * también al BORRAR el %, y sigue usándose para el resaltado del input y
   * el payload de guardado). Semántica 074/075: % -> valor no nulo (0
   * incluido) resetea toda la columna a AUTO; % -> vacío/NULL cierra los
   * AUTO pero preserva MANUAL — son dos casos distintos, nunca el mismo
   * flag.
   */
  function isPercentSetToValue(conditionId: string): boolean {
    if (!percentEdited.has(conditionId)) return false;
    const raw = percentEdited.get(conditionId)!;
    return raw.trim() !== "" && Number.isFinite(Number(raw));
  }

  /** true si esta celda es (o va a pasar a ser) MANUAL. El ripple de Lista nunca la toca (preserva la excepción); un % global válido (no vacío) sí la pisa, porque al guardar la 075 la resetea a AUTO — por eso handlePercentChange limpia manuallyTouched/resetToAuto de las celdas elegibles antes de que se llegue a leer este estado. */
  function isCellManual(productId: string, conditionId: string): boolean {
    const key = cellKey(productId, conditionId);
    if (resetToAuto.has(key)) return false;
    if (manuallyTouched.has(key)) return true;
    if (isPercentSetToValue(conditionId) && hasListAmount(productId)) return false;
    return originalMode.get(key) === "MANUAL";
  }

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
   * Sugiere (preview local, nunca persiste por sí solo) el precio de cada
   * condición configurable para un producto puntual, a partir de su Lista
   * actual y el % actual de cada condición — nunca pisa una celda MANUAL,
   * ni en este preview: el admin la ve congelada hasta tocar el badge
   * "Manual" o cambiar el % global de esa condición.
   */
  function suggestForProduct(productId: string, listAmount: number) {
    if (!Number.isFinite(listAmount) || listAmount < 0) return;
    setEdited((prev) => {
      const next = new Map(prev);
      for (const cond of suggestableConditions) {
        const key = cellKey(productId, cond.id);
        if (isCellManual(productId, cond.id)) continue;
        const pct = Number(percentValueFor(cond.id) || 0);
        if (!Number.isFinite(pct)) continue;
        next.set(key, String(suggestDiscountedPrice(listAmount, pct)));
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
    // Vacío/NULL: cierra los AUTO pero preserva MANUAL (semántica sin
    // cambios de 074/075, ver save_price_matrix_changes) — no hay nada que
    // recalcular ni ninguna excepción manual que invalidar acá, se corta
    // antes de tocar edited/manuallyTouched/resetToAuto.
    if (!listConditionId || value.trim() === "" || !Number.isFinite(pct)) return;

    // Productos elegibles para ESTE cambio de %: los que tienen Lista
    // (mismo criterio que fn_recalculate_auto_prices — "producto sin Lista
    // no participa"). Un solo cálculo, reusado para el preview de precio Y
    // para decidir qué celdas dejan de mostrarse como Manual.
    const eligibleProductIds = products.filter((p) => hasListAmount(p.id)).map((p) => p.id);

    // Recalcula esta condición para todos los elegibles, incluidos los
    // MANUAL: guardar un % no nulo (0 incluido) resetea toda la columna a
    // AUTO (migración 075), así que el preview tiene que anticiparlo — a
    // diferencia de Lista (suggestForProduct), que sí preserva las
    // excepciones MANUAL.
    setEdited((prev) => {
      const next = new Map(prev);
      for (const productId of eligibleProductIds) {
        next.set(cellKey(productId, conditionId), String(suggestDiscountedPrice(listAmountFor(productId)!, pct)));
      }
      return next;
    });

    // Este % global ya invalidó cualquier excepción manual/reset individual
    // previo de los elegibles — la acción más reciente (este cambio de %)
    // gana. Si el admin edita una celda puntual después, handleManualPriceChange
    // la vuelve a marcar Manual — última acción gana, sin prioridades fijas.
    setManuallyTouched((prev) => {
      const next = new Set(prev);
      let changed = false;
      for (const productId of eligibleProductIds) {
        if (next.delete(cellKey(productId, conditionId))) changed = true;
      }
      return changed ? next : prev;
    });
    setResetToAuto((prev) => {
      const next = new Set(prev);
      let changed = false;
      for (const productId of eligibleProductIds) {
        if (next.delete(cellKey(productId, conditionId))) changed = true;
      }
      return changed ? next : prev;
    });
  }

  /** Edición directa de una celda no-Lista: pasa (o queda) MANUAL. */
  function handleManualPriceChange(productId: string, conditionId: string, value: string) {
    setValue(productId, conditionId, value);
    const key = cellKey(productId, conditionId);
    setManuallyTouched((prev) => (prev.has(key) ? prev : new Set(prev).add(key)));
    setResetToAuto((prev) => {
      if (!prev.has(key)) return prev;
      const next = new Set(prev);
      next.delete(key);
      return next;
    });
  }

  /** "Volver a automático": el valor final lo calcula el servidor al guardar — esto solo actualiza el preview. */
  function handleResetToAuto(productId: string, conditionId: string) {
    const key = cellKey(productId, conditionId);
    setResetToAuto((prev) => new Set(prev).add(key));
    setManuallyTouched((prev) => {
      if (!prev.has(key)) return prev;
      const next = new Set(prev);
      next.delete(key);
      return next;
    });
    const preview = autoPreviewFor(productId, conditionId);
    if (preview !== null) setValue(productId, conditionId, preview);
  }

  /** Preview informativo ("Automático sugiere: $X") para una celda MANUAL — nunca se persiste solo. */
  function autoPreviewFor(productId: string, conditionId: string): string | null {
    if (!listConditionId) return null;
    const listAmount = Number(valueFor(productId, listConditionId));
    const pct = Number(percentValueFor(conditionId) || 0);
    if (!Number.isFinite(listAmount) || !Number.isFinite(pct)) return null;
    return String(suggestDiscountedPrice(listAmount, pct));
  }

  function isDirty(productId: string, conditionId: string) {
    const key = cellKey(productId, conditionId);
    if (!edited.has(key)) return false;
    return isPriceCellDirty(edited.get(key)!, original.get(key));
  }

  function isPercentDirty(conditionId: string) {
    if (!percentEdited.has(conditionId)) return false;
    const current = percentEdited.get(conditionId);
    const originalValue = originalPercent.get(conditionId) ?? 0;
    return current !== (originalValue ? String(originalValue) : "");
  }

  async function handleSave() {
    const { toSave, toClear, invalid } = classifyDirtyPriceCells(edited, original);
    const dirtyPercents = suggestableConditions.filter((c) => isPercentDirty(c.id));

    if (invalid.length > 0) {
      toast.error(
        invalid.length === 1
          ? `El precio "${invalid[0].rawValue}" no es válido — tiene que ser un número mayor a 0.`
          : `${invalid.length} precios no son válidos — tienen que ser un número mayor a 0.`
      );
      return;
    }

    const listPriceChanges: { product_id: string; amount: number }[] = [];
    const manualOverrides: { product_id: string; price_condition_id: string; amount: number }[] = [];
    const clears: { product_id: string; price_condition_id: string }[] = [];

    for (const { key, amount } of toSave) {
      const [productId, conditionId] = key.split(":");
      if (conditionId === listConditionId) {
        listPriceChanges.push({ product_id: productId, amount });
      } else if (manuallyTouched.has(key)) {
        manualOverrides.push({ product_id: productId, price_condition_id: conditionId, amount });
      }
      // Si no es Lista y no fue tocada a mano, es solo el preview del ripple
      // (AUTO) — no se manda: el servidor recalcula solo vía la cascada de
      // Lista/%, nunca confiando en lo que el cliente tenía dibujado.
    }
    for (const { key } of toClear) {
      const [productId, conditionId] = key.split(":");
      clears.push({ product_id: productId, price_condition_id: conditionId });
    }

    const resets: { product_id: string; price_condition_id: string }[] = [];
    for (const key of resetToAuto) {
      const [productId, conditionId] = key.split(":");
      resets.push({ product_id: productId, price_condition_id: conditionId });
    }

    const percentChanges: { price_condition_id: string; discount_percent: number | null }[] = [];
    for (const cond of dirtyPercents) {
      const raw = percentValueFor(cond.id).trim();
      if (raw === "") {
        percentChanges.push({ price_condition_id: cond.id, discount_percent: null });
        continue;
      }
      const pct = Number(raw);
      if (Number.isNaN(pct) || pct < 0 || pct > 100) {
        toast.error(`El porcentaje "${raw}" de ${cond.name} tiene que estar entre 0 y 100.`);
        return;
      }
      percentChanges.push({ price_condition_id: cond.id, discount_percent: pct / 100 });
    }

    if (
      listPriceChanges.length === 0 &&
      manualOverrides.length === 0 &&
      clears.length === 0 &&
      resets.length === 0 &&
      percentChanges.length === 0
    ) {
      toast.info("No hay cambios para guardar.");
      return;
    }

    setSaving(true);
    const supabase = createClient();
    const { error } = await supabase.rpc("save_price_matrix_changes", {
      p_list_price_changes: listPriceChanges,
      p_percent_changes: percentChanges,
      p_manual_overrides: manualOverrides,
      p_reset_to_auto: resets,
      p_clears: clears,
    });
    setSaving(false);

    if (error) {
      // Atómico: si falló, no se guardó NADA — se deja todo el estado local
      // tal cual para que el admin pueda corregir y reintentar.
      toast.error(error.message);
      return;
    }

    setEdited(new Map());
    setPercentEdited(new Map());
    setManuallyTouched(new Set());
    setResetToAuto(new Set());
    toast.success("Cambios guardados.");
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
      <div className="overflow-x-auto rounded-xl border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="sticky left-0 w-56 max-w-56 bg-card">Producto</TableHead>
              {conditions.map((c) => (
                <TableHead key={c.id} className="w-24 max-w-24 px-1.5 text-right align-top">
                  <div className="flex flex-col items-end gap-1">
                    <span className="whitespace-normal break-words leading-tight">{c.name}</span>
                    {/* % informativo dentro del propio encabezado de la
                        condición — toda condición PAYMENT_METHOD puede
                        configurarlo (isDiscountConfigurable), nunca un
                        allowlist de codes. Alimenta el recálculo automático
                        en backend (migración 74): el precio final de una
                        celda AUTO siempre sigue a Lista/% hasta que se
                        edite a mano. */}
                    {isDiscountConfigurable(c) ? (
                      <div className="flex items-center justify-end gap-1 font-normal">
                        <Input
                          type="number"
                          min={0}
                          max={100}
                          className={cn("h-7 w-16 text-right text-xs", isPercentDirty(c.id) && "border-primary ring-1 ring-primary")}
                          value={percentValueFor(c.id)}
                          onChange={(e) => handlePercentChange(c.id, e.target.value)}
                        />
                        <span className="text-xs text-muted-foreground">%</span>
                      </div>
                    ) : null}
                  </div>
                </TableHead>
              ))}
            </TableRow>
          </TableHeader>
          <TableBody>
            {products.map((product) => (
              <TableRow key={product.id}>
                <TableCell className="sticky left-0 w-56 max-w-56 whitespace-normal break-words bg-card font-medium">
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
                  // Puramente visual: el badge "Manual" es feedback de una
                  // edición directa EN ESTA SESIÓN, nunca una lectura del
                  // pricing_mode persistido — ver isCellManual (más abajo)
                  // para la lógica funcional (preview/ripple), que no cambia.
                  const showManualBadge = manuallyTouched.has(cellKey(product.id, c.id));
                  return (
                    <TableCell key={c.id} className="px-1.5 text-right">
                      <div className="ml-auto flex w-24 flex-col items-end gap-0.5">
                        <Input
                          type="number"
                          className={cn(
                            "h-8 w-24 px-1.5 text-right",
                            isDirty(product.id, c.id) && "border-primary ring-1 ring-primary",
                            showManualBadge && "border-amber-500"
                          )}
                          placeholder="—"
                          value={valueFor(product.id, c.id)}
                          onChange={(e) =>
                            isList
                              ? handleListChange(product.id, e.target.value)
                              : handleManualPriceChange(product.id, c.id, e.target.value)
                          }
                        />
                        {showManualBadge ? (
                          <Badge
                            variant="secondary"
                            className="text-[10px] cursor-pointer select-none hover:bg-secondary/70"
                            title="Volver a automático"
                            onClick={() => handleResetToAuto(product.id, c.id)}
                          >
                            Manual
                          </Badge>
                        ) : null}
                      </div>
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
