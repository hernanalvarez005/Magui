"use client";

import { useRef, useState } from "react";
import { ImageOff, Loader2, Upload, X } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { createClient } from "@/lib/supabase/client";

/**
 * Foto de producto/kit: sube al bucket público product-images (RLS
 * admin-only para insert/update/delete, ver 20260201000016_product_images.sql)
 * y devuelve la URL pública para guardar en products.image_url. No hay RPC
 * dedicada — el guardado del producto/kit ya persiste esta columna igual
 * que el resto de sus campos.
 */
export function ProductImageUpload({
  productId,
  imageUrl,
  onChange,
}: {
  /** null cuando todavía se está dando de alta el producto/kit */
  productId: string | null;
  imageUrl: string | null;
  onChange: (url: string | null) => void;
}) {
  const [uploading, setUploading] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  async function handleFile(file: File) {
    if (!file.type.startsWith("image/")) {
      toast.error("Elegí un archivo de imagen.");
      return;
    }
    if (file.size > 5 * 1024 * 1024) {
      toast.error("La imagen no puede pesar más de 5 MB.");
      return;
    }

    setUploading(true);
    const supabase = createClient();
    const ext = file.name.split(".").pop()?.toLowerCase().replace(/[^a-z0-9]/g, "") || "jpg";
    const path = `${productId ?? "nuevo"}-${Date.now()}.${ext}`;
    const { error } = await supabase.storage.from("product-images").upload(path, file, { upsert: true });

    if (error) {
      setUploading(false);
      toast.error("No pudimos subir la imagen.");
      return;
    }

    const { data } = supabase.storage.from("product-images").getPublicUrl(path);
    setUploading(false);
    onChange(data.publicUrl);
  }

  return (
    <div className="flex items-center gap-3">
      <div className="flex size-20 shrink-0 items-center justify-center overflow-hidden rounded-lg border border-border bg-muted">
        {imageUrl ? (
          // Foto en un bucket externo (Supabase Storage) — no un asset local
          // de public/, así que next/image no aplica acá sin conocer de
          // antemano el dominio del proyecto.
          // eslint-disable-next-line @next/next/no-img-element
          <img src={imageUrl} alt="" className="size-full object-cover" />
        ) : (
          <ImageOff className="size-6 text-muted-foreground" />
        )}
      </div>
      <div className="flex flex-col gap-1.5">
        <input
          ref={inputRef}
          type="file"
          accept="image/*"
          className="hidden"
          onChange={(e) => {
            const file = e.target.files?.[0];
            if (file) void handleFile(file);
            e.target.value = "";
          }}
        />
        <Button
          type="button"
          variant="outline"
          size="sm"
          disabled={uploading}
          onClick={() => inputRef.current?.click()}
        >
          {uploading ? <Loader2 className="animate-spin" /> : <Upload />}
          {imageUrl ? "Cambiar foto" : "Subir foto"}
        </Button>
        {imageUrl ? (
          <Button type="button" variant="ghost" size="sm" onClick={() => onChange(null)}>
            <X /> Quitar
          </Button>
        ) : null}
      </div>
    </div>
  );
}
