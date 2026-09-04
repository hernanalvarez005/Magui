"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import {
  ArrowLeft,
  Banknote,
  CheckCircle2,
  CreditCard,
  Landmark,
  Loader2,
  Minus,
  PackageX,
  Plus,
  Repeat,
  Search,
  UserRound,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Separator } from "@/components/ui/separator";
import { Textarea } from "@/components/ui/textarea";
import { EmptyState } from "@/components/shared/empty-state";
import { createClient } from "@/lib/supabase/client";
import { cn, formatCurrency, formatDateTime, normalizeDni } from "@/lib/utils";
import type {
  CreateSaleExchangeResult,
  ExchangeableSale,
  ExchangeableSaleItem,
  ExchangeNewItemPriceResult,
} from "@/types/database";

interface ProductOption {
  id: string;
  sku: string;
  name: string;
  product_type: string;
  category: string | null;
  track_stock: boolean;
  image_url: string | null;
  kitContents: string[] | null;
}

const PAYMENT_ICONS: Record<string, React.ElementType> = {
  CASH: Banknote,
  TRANSFER: Landmark,
  CARD_3: CreditCard,
  CARD_1: CreditCard,
};

type Step = "dni" | "sales" | "detail" | "new-item" | "confirm" | "success";

export function CambiosClient({ products }: { products: ProductOption[] }) {
  const supabase = useMemo(() => createClient(), []);

  const [step, setStep] = useState<Step>("dni");

  // Paso 1: búsqueda por DNI — mismo patrón (debounce, normalizeDni) que
  // CustomerPickerDialog, pero acá NUNCA se ofrece crear un cliente nuevo:
  // sin una venta original identificada no hay nada que cambiar.
  const [dni, setDni] = useState("");
  const [dniStatus, setDniStatus] = useState<"idle" | "searching" | "found" | "not_found">("idle");
  const [customer, setCustomer] = useState<{ id: string; full_name: string; dni: string | null } | null>(null);

  // Paso 2: ventas elegibles del cliente.
  const [sales, setSales] = useState<ExchangeableSale[] | null>(null);
  const [loadingSales, setLoadingSales] = useState(false);

  // Paso 3: venta seleccionada + línea a devolver + cantidad.
  const [selectedSale, setSelectedSale] = useState<ExchangeableSale | null>(null);
  const [returnItem, setReturnItem] = useState<ExchangeableSaleItem | null>(null);
  const [returnQty, setReturnQty] = useState(1);

  // Paso 4: producto nuevo + cantidad + precio (recalculado siempre server-side).
  const [productQuery, setProductQuery] = useState("");
  const [stock, setStock] = useState<Record<string, number>>({});
  const [kitAvailability, setKitAvailability] = useState<Record<string, number>>({});
  const [newProduct, setNewProduct] = useState<ProductOption | null>(null);
  const [newQty, setNewQty] = useState(1);
  const [priceQuote, setPriceQuote] = useState<ExchangeNewItemPriceResult | null>(null);
  const [pricing, setPricing] = useState(false);

  const [notes, setNotes] = useState("");
  const [confirming, setConfirming] = useState(false);
  const [result, setResult] = useState<CreateSaleExchangeResult | null>(null);

  // ---------------------------------------------------------------------
  // DNI: autobúsqueda debounced. Nunca ofrece crear cliente — si no
  // aparece, se corta acá (sección 4 del pedido).
  // ---------------------------------------------------------------------
  useEffect(() => {
    const normalized = normalizeDni(dni);
    if (normalized.length < 6) {
      void Promise.resolve().then(() => {
        setDniStatus("idle");
        setCustomer(null);
      });
      return;
    }
    let cancelled = false;
    void Promise.resolve().then(() => {
      if (!cancelled) setDniStatus("searching");
    });
    const timeout = setTimeout(async () => {
      const { data } = await supabase
        .from("customers")
        .select("id, full_name, dni")
        .eq("active", true)
        .eq("dni", normalized)
        .maybeSingle();
      if (cancelled) return;
      if (data) {
        setCustomer(data);
        setDniStatus("found");
      } else {
        setCustomer(null);
        setDniStatus("not_found");
      }
    }, 400);
    return () => {
      cancelled = true;
      clearTimeout(timeout);
    };
  }, [dni, supabase]);

  async function handleUseCustomer() {
    if (!customer) return;
    setLoadingSales(true);
    setStep("sales");
    const { data, error } = await supabase.rpc("customer_sales_for_exchange", { p_customer_id: customer.id });
    setLoadingSales(false);
    if (error) {
      toast.error(error.message);
      setSales([]);
      return;
    }
    setSales(data ?? []);
  }

  function handleSelectSale(sale: ExchangeableSale) {
    setSelectedSale(sale);
    setReturnItem(null);
    setReturnQty(1);
    setStep("detail");
  }

  function handleSelectReturnItem(item: ExchangeableSaleItem) {
    setReturnItem(item);
    setReturnQty(1);
  }

  function handleContinueToNewProduct() {
    if (!selectedSale || !returnItem) return;
    setProductQuery("");
    setNewProduct(null);
    setNewQty(1);
    setPriceQuote(null);
    setStep("new-item");
  }

  // Stock del producto nuevo — SIEMPRE en la sede de la venta original (es
  // inmutable, no elegible acá), igual patrón que Nueva Venta. BLOQUE F
  // (20260201000061): disponible (available), no físico crudo — el backend
  // (create_sale_exchange) ya valida contra reservas ACTIVE antes de
  // descontar el producto nuevo, así que mostrar disponible acá evita
  // ofrecer una cantidad que el backend después va a rechazar.
  useEffect(() => {
    if (step !== "new-item" || !selectedSale) return;
    let cancelled = false;
    async function loadStock() {
      if (!selectedSale) return;
      const [{ data: stockRows }, { data: kitRows }] = await Promise.all([
        supabase.from("product_stock_status").select("product_id, available").eq("location_id", selectedSale.location_id),
        supabase.from("kit_availability").select("kit_product_id, buildable_qty").eq("location_id", selectedSale.location_id),
      ]);
      if (cancelled) return;
      const nextStock: Record<string, number> = {};
      for (const row of stockRows ?? []) nextStock[row.product_id] = Number(row.available);
      setStock(nextStock);
      const nextKits: Record<string, number> = {};
      for (const row of kitRows ?? []) nextKits[row.kit_product_id] = row.buildable_qty;
      setKitAvailability(nextKits);
    }
    loadStock();
    return () => {
      cancelled = true;
    };
  }, [step, selectedSale, supabase]);

  // Precio del producto nuevo — recalculado en el servidor cada vez que
  // cambia el producto o la cantidad, bajo la forma de pago de la venta
  // original (nunca elegible acá) y sin promociones (decisión ya cerrada).
  useEffect(() => {
    if (!newProduct || !selectedSale) {
      void Promise.resolve().then(() => setPriceQuote(null));
      return;
    }
    let cancelled = false;
    void Promise.resolve().then(() => {
      if (!cancelled) setPricing(true);
    });
    const timeout = setTimeout(async () => {
      const { data, error } = await supabase.rpc("fn_exchange_new_item_price", {
        p_product_id: newProduct.id,
        p_quantity: newQty,
        p_payment_method_id: selectedSale.payment_method_id,
      });
      if (cancelled) return;
      setPricing(false);
      if (error) {
        toast.error(error.message);
        setPriceQuote(null);
        return;
      }
      setPriceQuote(data);
    }, 250);
    return () => {
      cancelled = true;
      clearTimeout(timeout);
    };
  }, [newProduct, newQty, selectedSale, supabase]);

  const recognizedValue = returnItem ? Number(returnItem.sale_unit_price) * returnQty : 0;
  const newItemTotal = priceQuote?.ok ? priceQuote.line_total : null;
  const difference = newItemTotal !== null ? Math.round((newItemTotal - recognizedValue) * 100) / 100 : null;

  async function handleConfirm() {
    if (!selectedSale || !returnItem || !newProduct || !priceQuote?.ok) return;
    setConfirming(true);
    const { data, error } = await supabase.rpc("create_sale_exchange", {
      p_original_sale_id: selectedSale.sale_id,
      p_returned_sale_item_id: returnItem.sale_item_id,
      p_returned_quantity: returnQty,
      p_new_product_id: newProduct.id,
      p_new_quantity: newQty,
      p_notes: notes.trim() || null,
    });
    setConfirming(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    setResult(data);
    setStep("success");
    toast.success("Cambio confirmado.");
  }

  function handleReset() {
    setStep("dni");
    setDni("");
    setDniStatus("idle");
    setCustomer(null);
    setSales(null);
    setSelectedSale(null);
    setReturnItem(null);
    setReturnQty(1);
    setNewProduct(null);
    setNewQty(1);
    setPriceQuote(null);
    setNotes("");
    setResult(null);
  }

  return (
    <div className="mx-auto flex max-w-2xl flex-col gap-5 p-4 md:p-6">
      <div className="flex items-center gap-2">
        {step !== "dni" && step !== "success" ? (
          <Button variant="ghost" size="icon" onClick={() => goBack()}>
            <ArrowLeft className="size-4" />
          </Button>
        ) : null}
        <div>
          <h1 className="flex items-center gap-2 text-xl font-semibold">
            <Repeat className="size-5" /> Cambios / Devoluciones
          </h1>
          <p className="text-sm text-muted-foreground">
            {customer ? `Cliente: ${customer.full_name}` : "Buscá al cliente por DNI para empezar."}
          </p>
        </div>
      </div>

      {step === "dni" ? (
        <Card>
          <CardContent className="flex flex-col gap-3 p-5">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="dni-cambio">DNI del cliente</Label>
              <div className="relative">
                <Input
                  id="dni-cambio"
                  autoFocus
                  inputMode="numeric"
                  placeholder="Ej: 32123456"
                  value={dni}
                  onChange={(e) => setDni(normalizeDni(e.target.value))}
                />
                {dniStatus === "searching" ? (
                  <Loader2 className="pointer-events-none absolute right-3 top-1/2 size-4 -translate-y-1/2 animate-spin text-muted-foreground" />
                ) : null}
              </div>
            </div>

            {dniStatus === "found" && customer ? (
              <div className="flex flex-col gap-2 rounded-lg border border-emerald-600/30 bg-emerald-600/10 p-3">
                <div className="flex items-center gap-2 text-sm font-medium text-emerald-700 dark:text-emerald-400">
                  <CheckCircle2 className="size-4" /> Cliente encontrado
                </div>
                <p className="text-sm">{customer.full_name}</p>
                <Button type="button" onClick={handleUseCustomer}>
                  Ver sus ventas
                </Button>
              </div>
            ) : null}

            {dniStatus === "not_found" ? (
              <p className="rounded-lg border border-border bg-muted px-3 py-3 text-sm text-muted-foreground">
                No encontramos un cliente con este DNI. Un cambio siempre necesita partir de una venta original
                identificada — si el cliente todavía no está cargado, buscalo o creálo primero desde Clientes.
              </p>
            ) : null}
          </CardContent>
        </Card>
      ) : null}

      {step === "sales" ? (
        <div className="flex flex-col gap-3">
          {loadingSales ? (
            <p className="py-8 text-center text-sm text-muted-foreground">Buscando ventas…</p>
          ) : !sales || sales.length === 0 ? (
            <EmptyState
              title="Sin ventas para cambiar"
              description="Este cliente no tiene ventas confirmadas en tus sedes que puedan usarse como origen de un cambio."
            />
          ) : (
            sales.map((sale) => {
              const Icon = PAYMENT_ICONS[sale.payment_method_code] ?? Banknote;
              return (
                <button
                  key={sale.sale_id}
                  type="button"
                  disabled={sale.is_free_sale}
                  onClick={() => handleSelectSale(sale)}
                  className={cn(
                    "flex flex-col gap-1 rounded-xl border border-border bg-card p-4 text-left shadow-sm transition-colors hover:border-primary",
                    sale.is_free_sale && "cursor-not-allowed opacity-50 hover:border-border"
                  )}
                >
                  <div className="flex items-center justify-between">
                    <span className="font-medium">{sale.sale_number}</span>
                    <span className="font-semibold">{formatCurrency(sale.total)}</span>
                  </div>
                  <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground">
                    <span>{formatDateTime(sale.sold_at)}</span>
                    <span>{sale.location_name}</span>
                    <span className="inline-flex items-center gap-1">
                      <Icon className="size-3" /> {sale.payment_method_name}
                    </span>
                    {sale.is_free_sale ? <Badge variant="secondary">Sin costo — no admite cambios</Badge> : null}
                  </div>
                  <p className="line-clamp-1 text-xs text-muted-foreground">
                    {sale.items.map((i) => `${i.quantity}× ${i.name}`).join(" · ")}
                  </p>
                </button>
              );
            })
          )}
        </div>
      ) : null}

      {step === "detail" && selectedSale ? (
        <div className="flex flex-col gap-4">
          <Card>
            <CardContent className="grid grid-cols-2 gap-3 p-4 text-sm">
              <Field label="Cliente" value={customer?.full_name ?? "—"} />
              <Field label="Fecha" value={formatDateTime(selectedSale.sold_at)} />
              <Field label="Sucursal" value={selectedSale.location_name} />
              <Field label="Medio de pago" value={selectedSale.payment_method_name} />
              <Field label="Total" value={formatCurrency(selectedSale.total)} />
            </CardContent>
          </Card>

          <div>
            <p className="mb-2 text-sm font-medium">¿Qué producto devuelve?</p>
            <div className="flex flex-col gap-2">
              {selectedSale.items.map((item) => {
                const selected = returnItem?.sale_item_id === item.sale_item_id;
                return (
                  <button
                    key={item.sale_item_id}
                    type="button"
                    onClick={() => handleSelectReturnItem(item)}
                    className={cn(
                      "flex items-center justify-between gap-3 rounded-lg border border-border bg-card p-3 text-left text-sm transition-colors hover:border-primary",
                      selected && "border-primary ring-1 ring-primary"
                    )}
                  >
                    <div>
                      <div className="flex items-center gap-1.5">
                        <span className="font-medium">{item.name}</span>
                        {item.product_type === "kit" ? (
                          <Badge variant="secondary" className="font-normal">
                            Kit
                          </Badge>
                        ) : null}
                      </div>
                      <span className="text-xs text-muted-foreground">
                        {item.quantity} × {formatCurrency(item.sale_unit_price)} (precio pagado)
                      </span>
                    </div>
                    <span className="font-semibold">{formatCurrency(item.line_total)}</span>
                  </button>
                );
              })}
            </div>
          </div>

          {returnItem ? (
            <Card>
              <CardContent className="flex flex-col gap-3 p-4">
                <div className="flex items-center justify-between">
                  <Label>Cantidad a devolver</Label>
                  <div className="flex items-center gap-2 rounded-md bg-secondary">
                    <Button
                      type="button"
                      variant="ghost"
                      size="icon"
                      className="size-8"
                      disabled={returnQty <= 1}
                      onClick={() => setReturnQty((q) => Math.max(1, q - 1))}
                    >
                      <Minus className="size-4" />
                    </Button>
                    <span className="min-w-6 text-center text-sm font-semibold tabular-nums">{returnQty}</span>
                    <Button
                      type="button"
                      variant="ghost"
                      size="icon"
                      className="size-8"
                      disabled={returnQty >= returnItem.quantity}
                      onClick={() => setReturnQty((q) => Math.min(returnItem.quantity, q + 1))}
                    >
                      <Plus className="size-4" />
                    </Button>
                  </div>
                </div>
                <p className="text-xs text-muted-foreground">
                  Disponible para devolver: {returnItem.quantity} — valor reconocido:{" "}
                  {formatCurrency(returnItem.sale_unit_price * returnQty)} (precio realmente pagado, nunca el
                  vigente hoy)
                </p>
                <Button type="button" onClick={handleContinueToNewProduct}>
                  Continuar — elegir producto nuevo
                </Button>
              </CardContent>
            </Card>
          ) : null}
        </div>
      ) : null}

      {step === "new-item" && selectedSale ? (
        <div className="flex flex-col gap-4">
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              autoFocus
              placeholder="Buscar producto o kit…"
              className="pl-9"
              value={productQuery}
              onChange={(e) => setProductQuery(e.target.value)}
            />
          </div>

          <div className="grid grid-cols-2 gap-2.5 sm:grid-cols-3">
            {products
              .filter(
                (p) =>
                  !productQuery ||
                  p.name.toLowerCase().includes(productQuery.toLowerCase()) ||
                  p.sku.toLowerCase().includes(productQuery.toLowerCase())
              )
              .map((p) => {
                const isKit = p.product_type === "kit";
                const availableStock = isKit ? kitAvailability[p.id] : stock[p.id];
                const outOfStock = p.track_stock && availableStock !== undefined && availableStock <= 0;
                const selected = newProduct?.id === p.id;
                return (
                  <button
                    key={p.id}
                    type="button"
                    disabled={outOfStock}
                    onClick={() => {
                      setNewProduct(p);
                      setNewQty(1);
                    }}
                    className={cn(
                      "flex flex-col gap-1 rounded-xl border border-border bg-card p-3 text-left shadow-sm transition-colors hover:border-primary",
                      selected && "border-primary ring-1 ring-primary",
                      outOfStock && "opacity-60"
                    )}
                  >
                    <div className="flex items-start justify-between gap-1">
                      <p className="truncate text-sm font-medium leading-tight">{p.name}</p>
                      {isKit ? (
                        <Badge variant="secondary" className="shrink-0">
                          Kit
                        </Badge>
                      ) : null}
                    </div>
                    <p className="text-xs text-muted-foreground">{p.category ?? p.sku}</p>
                    {outOfStock ? (
                      <Badge variant="destructive" className="w-fit gap-1">
                        <PackageX className="size-3" /> Sin stock
                      </Badge>
                    ) : availableStock !== undefined ? (
                      <span className="text-xs text-muted-foreground">{availableStock} disp.</span>
                    ) : null}
                  </button>
                );
              })}
          </div>

          {newProduct ? (
            <Card>
              <CardContent className="flex flex-col gap-3 p-4">
                <div className="flex items-center justify-between">
                  <div>
                    <p className="font-medium">{newProduct.name}</p>
                    <p className="text-xs text-muted-foreground">Se lleva</p>
                  </div>
                  <div className="flex items-center gap-2 rounded-md bg-secondary">
                    <Button
                      type="button"
                      variant="ghost"
                      size="icon"
                      className="size-8"
                      disabled={newQty <= 1}
                      onClick={() => setNewQty((q) => Math.max(1, q - 1))}
                    >
                      <Minus className="size-4" />
                    </Button>
                    <span className="min-w-6 text-center text-sm font-semibold tabular-nums">{newQty}</span>
                    <Button type="button" variant="ghost" size="icon" className="size-8" onClick={() => setNewQty((q) => q + 1)}>
                      <Plus className="size-4" />
                    </Button>
                  </div>
                </div>

                {pricing ? (
                  <p className="text-sm text-muted-foreground">Calculando precio…</p>
                ) : priceQuote && !priceQuote.ok ? (
                  <p className="text-sm text-destructive">{priceQuote.error_message}</p>
                ) : priceQuote?.ok ? (
                  <div className="flex flex-col gap-1 text-sm">
                    <div className="flex justify-between">
                      <span className="text-muted-foreground">Precio ({priceQuote.applied_price_condition_name})</span>
                      <span className="font-semibold">{formatCurrency(priceQuote.line_total)}</span>
                    </div>
                  </div>
                ) : null}

                <Button type="button" disabled={!priceQuote?.ok} onClick={() => setStep("confirm")}>
                  Continuar — revisar y confirmar
                </Button>
              </CardContent>
            </Card>
          ) : null}
        </div>
      ) : null}

      {step === "confirm" && selectedSale && returnItem && newProduct && priceQuote?.ok ? (
        <div className="flex flex-col gap-4">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Resumen del cambio</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-col gap-2.5 p-5 pt-0 text-sm">
              <Row label="Cliente" value={customer?.full_name ?? "—"} icon={UserRound} />
              <Row label="Venta original" value={selectedSale.sale_number} />
              <Separator />
              <Row label="Devuelve" value={`${returnQty} × ${returnItem.name}`} />
              <Row label="Valor reconocido" value={formatCurrency(recognizedValue)} muted />
              <Row label="Se lleva" value={`${newQty} × ${newProduct.name}`} />
              <Row label="Nuevo producto" value={formatCurrency(newItemTotal ?? 0)} muted />
              <Separator />
              <Row
                label="Resultado"
                value={
                  difference === null
                    ? "—"
                    : difference > 0
                      ? `Cliente debe abonar ${formatCurrency(difference)}`
                      : difference < 0
                        ? `Magui Rejuve debe devolver ${formatCurrency(Math.abs(difference))}`
                        : "Sin diferencia"
                }
                strong
              />
              <Separator />
              <Row label="Forma de pago" value={selectedSale.payment_method_name} />
            </CardContent>
          </Card>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="notes">Observaciones (opcional)</Label>
            <Textarea id="notes" rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} />
          </div>

          <Button size="lg" disabled={confirming} onClick={handleConfirm}>
            {confirming ? <Loader2 className="animate-spin" /> : null}
            Confirmar cambio
          </Button>
        </div>
      ) : null}

      {step === "success" && result ? (
        <Card>
          <CardContent className="flex flex-col items-center gap-3 p-8 text-center">
            <CheckCircle2 className="size-10 text-success" />
            <p className="text-lg font-semibold">Cambio confirmado</p>
            <p className="text-sm text-muted-foreground">
              La venta original quedó reemplazada. La nueva operación es {result.sale_number}.
            </p>
            <div className="flex gap-2">
              <Button asChild>
                <Link href={`/ventas/${result.sale_id}`}>Ver operación nueva</Link>
              </Button>
              <Button variant="outline" onClick={handleReset}>
                Hacer otro cambio
              </Button>
            </div>
          </CardContent>
        </Card>
      ) : null}
    </div>
  );

  function goBack() {
    if (step === "sales") setStep("dni");
    else if (step === "detail") setStep("sales");
    else if (step === "new-item") setStep("detail");
    else if (step === "confirm") setStep("new-item");
  }
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className="font-medium">{value}</p>
    </div>
  );
}

function Row({
  label,
  value,
  muted,
  strong,
  icon: Icon,
}: {
  label: string;
  value: string;
  muted?: boolean;
  strong?: boolean;
  icon?: React.ElementType;
}) {
  return (
    <div className="flex items-center justify-between gap-2">
      <span className="flex items-center gap-1.5 text-muted-foreground">
        {Icon ? <Icon className="size-3.5" /> : null}
        {label}
      </span>
      <span className={cn(muted && "text-muted-foreground", strong && "text-base font-semibold")}>{value}</span>
    </div>
  );
}
