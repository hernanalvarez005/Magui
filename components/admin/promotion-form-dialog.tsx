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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { createClient } from "@/lib/supabase/client";
import { promotionSchema } from "@/lib/validation/promotion";
import { todayInBuenosAires } from "@/lib/utils";
import type { PromotionType } from "@/types/database";

export interface ProductCandidate {
  id: string;
  sku: string;
  name: string;
  product_type: string;
}

export interface EditablePromotion {
  id: string;
  code: string;
  name: string;
  type: PromotionType;
  discount_percent: string | null;
  group_size: number;
  priority: number;
  stackable: boolean;
  valid_from: string;
  valid_until: string | null;
  notes: string | null;
  productIds: string[];
}

const TYPE_LABELS: Record<PromotionType, string> = {
  THREE_FOR_TWO: "3x2 (la más barata gratis)",
  DUO_PERCENT: "Duo — % en un par de productos",
  KIT_PERCENT: "% de descuento en un kit",
};

function toDateInput(iso: string | null) {
  if (!iso) return "";
  return iso.slice(0, 10);
}

export function PromotionFormDialog({
  promotion,
  products,
  open,
  onOpenChange,
  onSaved,
}: {
  /** null = alta de una promoción nueva */
  promotion: EditablePromotion | null;
  products: ProductCandidate[];
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
}) {
  const [form, setForm] = useState({
    code: promotion?.code ?? "",
    name: promotion?.name ?? "",
    type: (promotion?.type ?? "THREE_FOR_TWO") as PromotionType,
    discountPercent: promotion?.discount_percent ? String(Number(promotion.discount_percent) * 100) : "",
    groupSize: promotion?.group_size ?? 3,
    priority: promotion?.priority ?? 100,
    stackable: promotion?.stackable ?? false,
    validFrom: toDateInput(promotion?.valid_from ?? null) || todayInBuenosAires(),
    validUntil: toDateInput(promotion?.valid_until ?? null),
    notes: promotion?.notes ?? "",
  });
  const [productIds, setProductIds] = useState<string[]>(promotion?.productIds ?? []);
  const [saving, setSaving] = useState(false);

  const maxProducts = form.type === "DUO_PERCENT" ? 2 : form.type === "KIT_PERCENT" ? 1 : Infinity;
  const candidates = form.type === "KIT_PERCENT" ? products.filter((p) => p.product_type === "kit") : products;

  function toggleProduct(id: string) {
    setProductIds((prev) => {
      if (prev.includes(id)) return prev.filter((p) => p !== id);
      if (form.type !== "THREE_FOR_TWO") return [...prev.slice(0, maxProducts - 1), id];
      return [...prev, id];
    });
  }

  async function handleSave() {
    const parsed = promotionSchema.safeParse({
      code: form.code,
      name: form.name,
      type: form.type,
      discount_percent: form.type === "THREE_FOR_TWO" ? null : Number(form.discountPercent) / 100,
      group_size: Number(form.groupSize),
      priority: Number(form.priority),
      stackable: form.stackable,
      valid_from: form.validFrom,
      valid_until: form.validUntil,
      notes: form.notes,
      product_ids: productIds,
    });
    if (!parsed.success) {
      toast.error(parsed.error.issues[0]?.message ?? "Revisá los datos de la promoción.");
      return;
    }

    setSaving(true);
    const supabase = createClient();
    const payload = {
      code: parsed.data.code,
      name: parsed.data.name,
      discount_percent: parsed.data.discount_percent === null ? null : String(parsed.data.discount_percent),
      group_size: parsed.data.group_size,
      priority: parsed.data.priority,
      stackable: parsed.data.stackable,
      valid_from: `${parsed.data.valid_from}T00:00:00-03:00`,
      valid_until: parsed.data.valid_until ? `${parsed.data.valid_until}T23:59:59-03:00` : null,
      notes: parsed.data.notes || null,
    };

    let promotionId = promotion?.id ?? null;

    if (promotionId) {
      const { error } = await supabase.from("promotions").update(payload).eq("id", promotionId);
      if (error) {
        setSaving(false);
        toast.error(error.message.includes("promotions_code_key") ? "Ya existe una promoción con ese código." : error.message);
        return;
      }
    } else {
      const { data, error } = await supabase
        .from("promotions")
        .insert({ ...payload, type: parsed.data.type })
        .select("id")
        .single();
      if (error || !data) {
        setSaving(false);
        toast.error(
          error?.message.includes("promotions_code_key") ? "Ya existe una promoción con ese código." : "No pudimos crear la promoción."
        );
        return;
      }
      promotionId = data.id;
    }

    const { error: productsError } = await supabase.rpc("set_promotion_products", {
      p_promotion_id: promotionId,
      p_product_ids: parsed.data.product_ids,
    });

    setSaving(false);

    if (productsError) {
      toast.error(productsError.message);
      return;
    }

    toast.success(promotion ? "Promoción actualizada." : "Promoción creada.");
    onSaved();
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{promotion ? "Editar promoción" : "Nueva promoción"}</DialogTitle>
          <DialogDescription>
            Se evalúa después de resolver el precio por medio de pago/cantidad. Un producto solo
            puede estar en una promoción activa a la vez.
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-3">
          <div className="flex flex-col gap-1.5">
            <Label>Tipo</Label>
            {promotion ? (
              <Input value={TYPE_LABELS[form.type]} disabled />
            ) : (
              <Select
                value={form.type}
                onValueChange={(v: PromotionType) => {
                  setForm((f) => ({ ...f, type: v }));
                  setProductIds([]);
                }}
              >
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="THREE_FOR_TWO">{TYPE_LABELS.THREE_FOR_TWO}</SelectItem>
                  <SelectItem value="DUO_PERCENT">{TYPE_LABELS.DUO_PERCENT}</SelectItem>
                  <SelectItem value="KIT_PERCENT">{TYPE_LABELS.KIT_PERCENT}</SelectItem>
                </SelectContent>
              </Select>
            )}
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="promo-code">Código</Label>
              <Input id="promo-code" value={form.code} onChange={(e) => setForm((f) => ({ ...f, code: e.target.value }))} />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="promo-priority">Prioridad</Label>
              <Input
                id="promo-priority"
                type="number"
                value={form.priority}
                onChange={(e) => setForm((f) => ({ ...f, priority: Number(e.target.value) }))}
              />
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="promo-name">Nombre</Label>
            <Input id="promo-name" value={form.name} onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))} />
          </div>

          {form.type === "THREE_FOR_TWO" ? (
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="promo-group">Cada cuántas unidades hay 1 gratis</Label>
              <Input
                id="promo-group"
                type="number"
                min={2}
                value={form.groupSize}
                onChange={(e) => setForm((f) => ({ ...f, groupSize: Number(e.target.value) }))}
              />
            </div>
          ) : (
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="promo-discount">% de descuento</Label>
              <Input
                id="promo-discount"
                type="number"
                min={1}
                max={90}
                value={form.discountPercent}
                onChange={(e) => setForm((f) => ({ ...f, discountPercent: e.target.value }))}
              />
            </div>
          )}

          <div className="grid grid-cols-2 gap-3">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="promo-from">Vigente desde</Label>
              <Input
                id="promo-from"
                type="date"
                value={form.validFrom}
                onChange={(e) => setForm((f) => ({ ...f, validFrom: e.target.value }))}
              />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="promo-until">Hasta (opcional)</Label>
              <Input
                id="promo-until"
                type="date"
                value={form.validUntil}
                onChange={(e) => setForm((f) => ({ ...f, validUntil: e.target.value }))}
              />
            </div>
          </div>

          <label className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={form.stackable}
              onChange={(e) => setForm((f) => ({ ...f, stackable: e.target.checked }))}
            />
            Combinable con otras promociones (si no, y matchea, gana ella sola)
          </label>

          <div className="flex flex-col gap-2">
            <Label>
              Productos {form.type === "DUO_PERCENT" ? "(exactamente 2)" : form.type === "KIT_PERCENT" ? "(1 kit)" : "elegibles"}
            </Label>
            <div className="flex max-h-40 flex-col gap-1 overflow-y-auto rounded-md border border-border p-2">
              {candidates.map((p) => (
                <label key={p.id} className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={productIds.includes(p.id)}
                    disabled={!productIds.includes(p.id) && productIds.length >= maxProducts}
                    onChange={() => toggleProduct(p.id)}
                  />
                  {p.name} ({p.sku})
                </label>
              ))}
              {candidates.length === 0 ? (
                <p className="py-2 text-center text-xs text-muted-foreground">No hay kits activos.</p>
              ) : null}
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="promo-notes">Notas</Label>
            <Textarea
              id="promo-notes"
              rows={2}
              value={form.notes}
              onChange={(e) => setForm((f) => ({ ...f, notes: e.target.value }))}
            />
          </div>
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
