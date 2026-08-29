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
import { ProductImageUpload } from "@/components/admin/product-image-upload";
import { createClient } from "@/lib/supabase/client";
import { productSchema } from "@/lib/validation/product";

export interface EditableProduct {
  id: string;
  sku: string;
  name: string;
  product_type: string;
  category: string | null;
  unit: string;
  track_stock: boolean;
  commissionable: boolean;
  promo_eligible: boolean;
  default_min_stock: string;
  notes: string | null;
  image_url: string | null;
}

export function ProductFormDialog({
  product,
  open,
  onOpenChange,
  onSaved,
}: {
  /** null = alta de un producto nuevo */
  product: EditableProduct | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
}) {
  const isKit = product?.product_type === "kit";
  const [form, setForm] = useState({
    sku: product?.sku ?? "",
    name: product?.name ?? "",
    product_type: (product?.product_type === "accessory" ? "accessory" : "product") as
      | "product"
      | "accessory",
    category: product?.category ?? "",
    unit: product?.unit ?? "unidad",
    track_stock: product?.track_stock ?? true,
    commissionable: product?.commissionable ?? true,
    promo_eligible: product?.promo_eligible ?? true,
    default_min_stock: product?.default_min_stock ?? "0",
    notes: product?.notes ?? "",
  });
  const [imageUrl, setImageUrl] = useState(product?.image_url ?? null);
  const [saving, setSaving] = useState(false);

  async function handleSave() {
    const parsed = productSchema.safeParse({
      ...form,
      default_min_stock: Number(form.default_min_stock),
    });
    if (!parsed.success) {
      toast.error(parsed.error.issues[0]?.message ?? "Revisá los datos.");
      return;
    }

    setSaving(true);
    const supabase = createClient();
    const payload = {
      sku: parsed.data.sku,
      name: parsed.data.name,
      // Un kit existente nunca cambia de tipo ni de track_stock acá — su
      // composición y su modalidad se administran en /admin/kits.
      ...(isKit ? {} : { product_type: parsed.data.product_type, track_stock: parsed.data.track_stock }),
      category: parsed.data.category || null,
      unit: parsed.data.unit,
      commissionable: parsed.data.commissionable,
      promo_eligible: parsed.data.promo_eligible,
      default_min_stock: String(parsed.data.default_min_stock),
      notes: parsed.data.notes || null,
      image_url: imageUrl,
    };

    const { error } = product
      ? await supabase.from("products").update(payload).eq("id", product.id)
      : await supabase.from("products").insert(payload);

    setSaving(false);

    if (error) {
      toast.error(
        error.message.includes("products_sku_key") ? "Ya existe un producto con ese SKU." : error.message
      );
      return;
    }

    toast.success(product ? "Producto actualizado." : "Producto creado.");
    onSaved();
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{product ? "Editar producto" : "Nuevo producto"}</DialogTitle>
          <DialogDescription>
            {product
              ? "Los precios se administran aparte, en Precios."
              : "Se crea activo. Cargá el precio después, en Precios."}
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-3">
          <div className="flex flex-col gap-1.5">
            <Label>Foto</Label>
            <ProductImageUpload productId={product?.id ?? null} imageUrl={imageUrl} onChange={setImageUrl} />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="sku">SKU</Label>
              <Input id="sku" value={form.sku} onChange={(e) => setForm((f) => ({ ...f, sku: e.target.value }))} />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="unit">Unidad</Label>
              <Input id="unit" value={form.unit} onChange={(e) => setForm((f) => ({ ...f, unit: e.target.value }))} />
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="name">Nombre</Label>
            <Input id="name" value={form.name} onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))} />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="flex flex-col gap-1.5">
              <Label>Tipo</Label>
              {isKit ? (
                <Input value="Kit (se edita en Kits)" disabled />
              ) : (
                <Select
                  value={form.product_type}
                  onValueChange={(v: "product" | "accessory") => setForm((f) => ({ ...f, product_type: v }))}
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="product">Producto</SelectItem>
                    <SelectItem value="accessory">Accesorio</SelectItem>
                  </SelectContent>
                </Select>
              )}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="category">Categoría</Label>
              <Input
                id="category"
                value={form.category}
                onChange={(e) => setForm((f) => ({ ...f, category: e.target.value }))}
              />
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="min_stock">Mínimo de stock para alerta</Label>
            <Input
              id="min_stock"
              type="number"
              min={0}
              value={form.default_min_stock}
              onChange={(e) => setForm((f) => ({ ...f, default_min_stock: e.target.value }))}
            />
          </div>

          {!isKit ? (
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={form.track_stock}
                onChange={(e) => setForm((f) => ({ ...f, track_stock: e.target.checked }))}
              />
              Maneja stock propio
            </label>
          ) : null}

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="notes">Notas</Label>
            <Textarea
              id="notes"
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
