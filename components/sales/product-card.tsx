"use client";

import { Minus, Plus, PackageX } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { cn, formatCurrency } from "@/lib/utils";

export interface ProductCardData {
  id: string;
  sku: string;
  name: string;
  category: string | null;
  isKit: boolean;
  stock: number | null; // null = no trackeado / desconocido
  lowStock: boolean;
  unitPrice: number | null; // precio estimado bajo la condición actual (puede ser null si no cotizó todavía)
  imageUrl: string | null;
  kitContents: string[] | null; // ej. ["2× Sérum Vitamina C", "1× Crema Hidratante"] — null si no es kit
}

export function ProductCard({
  product,
  quantity,
  onChange,
}: {
  product: ProductCardData;
  quantity: number;
  onChange: (nextQuantity: number) => void;
}) {
  const outOfStock = product.stock !== null && product.stock <= 0;
  const atStockLimit = product.stock !== null && quantity >= product.stock;

  return (
    <div
      className={cn(
        "flex flex-col gap-2 rounded-xl border border-border bg-card p-3.5 shadow-sm transition-opacity",
        outOfStock && "opacity-60"
      )}
    >
      <div className="flex items-start gap-2.5">
        {product.imageUrl ? (
          <div className="size-11 shrink-0 overflow-hidden rounded-lg border border-border bg-muted">
            {/* Foto en Supabase Storage — dominio no conocido de antemano, no next/image */}
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={product.imageUrl} alt="" loading="lazy" className="size-full object-cover" />
          </div>
        ) : null}
        <div className="min-w-0 flex-1">
          <div className="flex items-start justify-between gap-2">
            <p className="truncate text-sm font-medium leading-tight">{product.name}</p>
            {product.isKit ? (
              <Badge variant="secondary" className="shrink-0">
                Kit
              </Badge>
            ) : null}
          </div>
          <p className="text-xs text-muted-foreground">{product.category ?? product.sku}</p>
          {product.isKit && product.kitContents && product.kitContents.length > 0 ? (
            <p
              className="mt-0.5 line-clamp-2 text-xs text-muted-foreground"
              title={`Incluye: ${product.kitContents.join(", ")}`}
            >
              Incluye: {product.kitContents.join(", ")}
            </p>
          ) : null}
        </div>
      </div>

      <div className="flex items-center justify-between gap-2">
        <span className="font-semibold">
          {product.unitPrice !== null ? formatCurrency(product.unitPrice) : "—"}
        </span>
        {outOfStock ? (
          <Badge variant="destructive" className="gap-1">
            <PackageX className="size-3" /> Sin stock
          </Badge>
        ) : product.lowStock ? (
          <Badge variant="warning">Stock bajo</Badge>
        ) : product.stock !== null ? (
          <span className="text-xs text-muted-foreground">{product.stock} disp.</span>
        ) : null}
      </div>

      {outOfStock ? (
        <Button size="sm" variant="outline" disabled className="w-full">
          Sin stock
        </Button>
      ) : quantity > 0 ? (
        <div className="flex items-center justify-between rounded-md bg-secondary">
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="size-9"
            onClick={() => onChange(quantity - 1)}
          >
            <Minus className="size-4" />
          </Button>
          <span className="min-w-6 text-center text-sm font-semibold tabular-nums">{quantity}</span>
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="size-9"
            disabled={atStockLimit}
            onClick={() => onChange(quantity + 1)}
          >
            <Plus className="size-4" />
          </Button>
        </div>
      ) : (
        <Button type="button" size="sm" className="w-full" onClick={() => onChange(1)}>
          <Plus /> Agregar
        </Button>
      )}
    </div>
  );
}
