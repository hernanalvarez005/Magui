"use client";

import { useState } from "react";
import { Loader2 } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { createClient } from "@/lib/supabase/client";
import { makePriceConditionSchema } from "@/lib/validation/price-condition";
import type { CreatePriceConditionResult } from "@/types/database";

export interface EditablePriceCondition {
  id: string;
  name: string;
  discount_percent: string | null;
  requires_billing: boolean;
  active: boolean;
  priority: number;
  location_codes: string[];
  available_web: boolean;
}

export interface BranchLocationOption {
  code: string;
  name: string;
}

export function PriceConditionFormDialog({
  condition,
  branchLocations,
  listPriority,
  open,
  onOpenChange,
  onSaved,
}: {
  /** null = alta de una condición nueva */
  condition: EditablePriceCondition | null;
  branchLocations: BranchLocationOption[];
  listPriority: number;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
}) {
  const [name, setName] = useState(condition?.name ?? "");
  const [discountPercent, setDiscountPercent] = useState(
    condition?.discount_percent ? String(Math.round(Number(condition.discount_percent) * 100)) : "0"
  );
  const [requiresBilling, setRequiresBilling] = useState(condition?.requires_billing ?? false);
  const [active, setActive] = useState(condition?.active ?? true);
  // Default: un lugar justo arriba de Lista — mismo criterio que el
  // auto-cálculo de create_price_condition cuando no se pasa prioridad
  // explícita, pero acá SIEMPRE se manda un valor (el admin puede tocarlo).
  const [priority, setPriority] = useState(condition?.priority ?? Math.max(1, listPriority - 1));
  const [locationCodes, setLocationCodes] = useState<string[]>(condition?.location_codes ?? []);
  const [availableWeb, setAvailableWeb] = useState(condition?.available_web ?? false);
  const [saving, setSaving] = useState(false);

  function toggleLocation(code: string) {
    setLocationCodes((prev) => (prev.includes(code) ? prev.filter((c) => c !== code) : [...prev, code]));
  }

  async function handleSave() {
    const schema = makePriceConditionSchema(listPriority);
    const parsed = schema.safeParse({
      name,
      discount_percent: Number(discountPercent),
      requires_billing: requiresBilling,
      active,
      priority: Number(priority),
      location_codes: locationCodes,
      available_web: availableWeb,
    });
    if (!parsed.success) {
      toast.error(parsed.error.issues[0]?.message ?? "Revisá los datos de la condición.");
      return;
    }

    setSaving(true);
    const supabase = createClient();
    const discountFraction = parsed.data.discount_percent / 100;

    if (condition) {
      const { error } = await supabase.rpc("update_price_condition", {
        p_price_condition_id: condition.id,
        p_name: parsed.data.name,
        p_discount_percent: discountFraction,
        p_requires_billing: parsed.data.requires_billing,
        p_priority: parsed.data.priority,
        p_active: parsed.data.active,
        p_location_codes: parsed.data.location_codes,
        p_available_web: parsed.data.available_web,
      });
      setSaving(false);
      if (error) {
        toast.error(error.message);
        return;
      }
      toast.success("Condición actualizada.");
      onSaved();
      return;
    }

    const { data, error } = await supabase.rpc("create_price_condition", {
      p_name: parsed.data.name,
      p_discount_percent: discountFraction,
      p_requires_billing: parsed.data.requires_billing,
      p_location_codes: parsed.data.location_codes,
      p_available_web: parsed.data.available_web,
      p_active: parsed.data.active,
      p_copy_prices_from_code: "LIST",
      p_priority: parsed.data.priority,
    });
    setSaving(false);
    if (error) {
      toast.error(error.message);
      return;
    }

    const result = data as CreatePriceConditionResult;
    if (result.skipped_products.length > 0) {
      toast.warning(
        `Condición creada, pero ${result.skipped_products.length} producto${result.skipped_products.length === 1 ? "" : "s"} quedaron sin precio propio (sin precio Lista vigente para copiar): ${result.skipped_products
          .slice(0, 3)
          .map((p) => p.sku)
          .join(", ")}${result.skipped_products.length > 3 ? "…" : ""}. Cargalos manualmente desde la Matriz de precios.`,
        { duration: 8000 }
      );
    } else {
      toast.success(`Condición creada. Se copiaron ${result.copied_prices_count} precios desde "Lista".`);
    }
    onSaved();
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{condition ? "Editar condición de precio" : "Nueva condición de precio"}</DialogTitle>
          <DialogDescription>
            {condition
              ? "Editar nunca modifica los precios ya cargados en la Matriz — eso se administra aparte."
              : 'Los precios iniciales se COPIAN, una sola vez, desde "Lista" al crear — quedan editables desde la Matriz de precios como cualquier otro. No es un vínculo dinámico: si "Lista" cambia después, esta condición no se actualiza sola.'}
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-3">
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="pc-name">Nombre</Label>
            <Input id="pc-name" value={name} onChange={(e) => setName(e.target.value)} placeholder="Ej: 9 cuotas sin interés" />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="pc-discount">% informativo (ajuste)</Label>
              <Input
                id="pc-discount"
                type="number"
                min={0}
                max={100}
                value={discountPercent}
                onChange={(e) => setDiscountPercent(e.target.value)}
              />
              <p className="text-xs text-muted-foreground">Solo informativo — nunca calcula el precio, eso lo define cada precio cargado en la Matriz.</p>
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="pc-priority">Prioridad</Label>
              <Input
                id="pc-priority"
                type="number"
                min={1}
                value={priority}
                onChange={(e) => setPriority(Number(e.target.value))}
              />
              <p className="text-xs text-muted-foreground">Tiene que ser menor a {listPriority} (la de &quot;Lista&quot;) para que esta condición aplique.</p>
            </div>
          </div>

          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" checked={requiresBilling} onChange={(e) => setRequiresBilling(e.target.checked)} />
            Requiere facturación (exige cliente con DNI + cuenta de ingreso al vender)
          </label>

          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" checked={active} onChange={(e) => setActive(e.target.checked)} />
            Activa (una condición desactivada deja de ofrecerse en ventas nuevas; nunca se borra ni afecta ventas ya hechas)
          </label>

          <div className="flex flex-col gap-2">
            <Label>Sucursales habilitadas</Label>
            <div className="flex flex-col gap-1 rounded-md border border-border p-2">
              {branchLocations.map((loc) => (
                <label key={loc.code} className="flex items-center gap-2 pl-1 text-sm">
                  <input type="checkbox" checked={locationCodes.includes(loc.code)} onChange={() => toggleLocation(loc.code)} />
                  {loc.name}
                </label>
              ))}
              {branchLocations.length === 0 ? (
                <p className="py-2 text-center text-xs text-muted-foreground">No hay sucursales activas.</p>
              ) : null}
            </div>
          </div>

          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" checked={availableWeb} onChange={(e) => setAvailableWeb(e.target.checked)} />
            Disponible para Ventas Web
          </label>
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancelar
          </Button>
          <Button onClick={handleSave} disabled={saving}>
            {saving ? <Loader2 className="animate-spin" /> : null}
            Guardar
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
