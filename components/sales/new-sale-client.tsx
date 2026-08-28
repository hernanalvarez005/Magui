"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import {
  Banknote,
  CheckCircle2,
  ClipboardCopy,
  CreditCard,
  Gift,
  Landmark,
  Loader2,
  Search,
  ShoppingCart,
  User,
  UserRound,
  WifiOff,
  X,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Separator } from "@/components/ui/separator";
import { Switch } from "@/components/ui/switch";
import {
  Sheet,
  SheetContent,
  SheetFooter,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from "@/components/ui/sheet";
import { Textarea } from "@/components/ui/textarea";
import { EmptyState } from "@/components/shared/empty-state";
import { ProductCard, type ProductCardData } from "@/components/sales/product-card";
import { CustomerPickerDialog, type CustomerOption } from "@/components/sales/customer-picker-dialog";
import { createClient } from "@/lib/supabase/client";
import { cn, formatCurrency } from "@/lib/utils";
import { newSaleSchema } from "@/lib/validation/sale";
import type { CreateSaleResult, PricingQuoteResult } from "@/types/database";

interface LocationOption {
  id: string;
  code: string;
  name: string;
}
interface ChannelOption {
  id: string;
  code: string;
  name: string;
}
interface PaymentMethodOption {
  id: string;
  code: string;
  name: string;
}
interface DoctorOption {
  id: string;
  code: string;
  full_name: string;
}
interface ProductOption {
  id: string;
  sku: string;
  name: string;
  product_type: string;
  category: string | null;
  track_stock: boolean;
}

const PAYMENT_ICONS: Record<string, React.ElementType> = {
  CASH: Banknote,
  TRANSFER: Landmark,
  CARD_3: CreditCard,
  CARD_1: CreditCard,
};

const FREE_SALE_REASONS: { value: "GIFT" | "SAMPLE" | "EXCHANGE" | "COURTESY" | "OTHER"; label: string }[] = [
  { value: "GIFT", label: "Regalo" },
  { value: "SAMPLE", label: "Muestra" },
  { value: "EXCHANGE", label: "Canje" },
  { value: "COURTESY", label: "Cortesía" },
  { value: "OTHER", label: "Otro" },
];

export function NewSaleClient({
  seller,
  locations,
  channels,
  paymentMethods,
  doctors,
  products,
}: {
  seller: { id: string; fullName: string };
  locations: LocationOption[];
  channels: ChannelOption[];
  paymentMethods: PaymentMethodOption[];
  doctors: DoctorOption[];
  products: ProductOption[];
}) {
  const supabase = useMemo(() => createClient(), []);

  const branchChannel = channels.find((c) => c.code === "BRANCH") ?? channels[0];
  const [channelId, setChannelId] = useState(branchChannel?.id ?? "");
  const [locationId, setLocationId] = useState(locations[0]?.id ?? "");
  const [paymentMethodId, setPaymentMethodId] = useState(paymentMethods[0]?.id ?? "");
  const [cart, setCart] = useState<Record<string, number>>({});
  const [search, setSearch] = useState("");
  const [customer, setCustomer] = useState<CustomerOption | null>(null);
  const [customerDialogOpen, setCustomerDialogOpen] = useState(false);
  const [doctorId, setDoctorId] = useState<string>("none");
  const [notes, setNotes] = useState("");
  const [externalSource, setExternalSource] = useState("");
  const [externalOrderId, setExternalOrderId] = useState("");
  const [isFreeSale, setIsFreeSale] = useState(false);
  const [freeSaleReason, setFreeSaleReason] = useState<"GIFT" | "SAMPLE" | "EXCHANGE" | "COURTESY" | "OTHER" | "">("");
  const [freeSaleNotes, setFreeSaleNotes] = useState("");

  const [stock, setStock] = useState<Record<string, number>>({});
  const [lowStock, setLowStock] = useState<Record<string, boolean>>({});
  const [kitAvailability, setKitAvailability] = useState<Record<string, number>>({});

  const [quote, setQuote] = useState<PricingQuoteResult | null>(null);
  const [quoting, setQuoting] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [receipt, setReceipt] = useState<CreateSaleResult | null>(null);
  const [online, setOnline] = useState(() => (typeof navigator === "undefined" ? true : navigator.onLine));
  const [cartOpen, setCartOpen] = useState(false);

  const selectedChannel = channels.find((c) => c.id === channelId);
  const isWeb = selectedChannel?.code === "WEB";

  useEffect(() => {
    const goOnline = () => setOnline(true);
    const goOffline = () => setOnline(false);
    window.addEventListener("online", goOnline);
    window.addEventListener("offline", goOffline);
    return () => {
      window.removeEventListener("online", goOnline);
      window.removeEventListener("offline", goOffline);
    };
  }, []);

  // Stock de la sede seleccionada (productos trackeables + disponibilidad de kits).
  useEffect(() => {
    if (!locationId) return;
    let cancelled = false;

    async function loadStock() {
      const [{ data: stockRows }, { data: kitRows }] = await Promise.all([
        supabase
          .from("product_stock_status")
          .select("product_id, quantity, status")
          .eq("location_id", locationId),
        supabase.from("kit_availability").select("kit_product_id, buildable_qty").eq("location_id", locationId),
      ]);
      if (cancelled) return;

      const nextStock: Record<string, number> = {};
      const nextLow: Record<string, boolean> = {};
      for (const row of stockRows ?? []) {
        nextStock[row.product_id] = Number(row.quantity);
        nextLow[row.product_id] = row.status === "bajo";
      }
      setStock(nextStock);
      setLowStock(nextLow);

      const nextKits: Record<string, number> = {};
      for (const row of kitRows ?? []) {
        nextKits[row.kit_product_id] = row.buildable_qty;
      }
      setKitAvailability(nextKits);
    }

    loadStock();
    return () => {
      cancelled = true;
    };
  }, [locationId, supabase]);

  const cartItems = useMemo(
    () => Object.entries(cart).filter(([, qty]) => qty > 0).map(([product_id, quantity]) => ({ product_id, quantity })),
    [cart]
  );
  const cartCount = cartItems.reduce((acc, i) => acc + i.quantity, 0);

  // Recalcula el precio en el servidor (RPC de solo lectura) cada vez que cambia el carrito
  // o el medio de pago. Esto es una ESTIMACIÓN: create_sale() vuelve a calcular todo al confirmar.
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current);

    debounceRef.current = setTimeout(async () => {
      if (cartItems.length === 0 || !paymentMethodId) {
        setQuote(null);
        setQuoting(false);
        return;
      }

      setQuoting(true);
      const { data, error } = await supabase.rpc("quote_sale", {
        p_items: cartItems,
        p_payment_method_id: paymentMethodId,
        p_is_free_sale: isFreeSale,
      });
      if (error) {
        setQuote({ ok: false, error_message: "No pudimos calcular el precio. Probá de nuevo." });
      } else {
        setQuote(data as PricingQuoteResult);
      }
      setQuoting(false);
    }, 300);

    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [JSON.stringify(cartItems), paymentMethodId, isFreeSale]);

  function setQuantity(productId: string, quantity: number) {
    setCart((prev) => {
      const next = { ...prev };
      if (quantity <= 0) {
        delete next[productId];
      } else {
        next[productId] = quantity;
      }
      return next;
    });
  }

  const filteredProducts = products.filter((p) =>
    search.trim().length === 0
      ? true
      : p.name.toLowerCase().includes(search.toLowerCase()) || p.sku.toLowerCase().includes(search.toLowerCase())
  );

  function productCardData(p: ProductOption): ProductCardData {
    const isKit = p.product_type === "kit" || !p.track_stock;
    const stockQty = isKit ? (kitAvailability[p.id] ?? 0) : (stock[p.id] ?? null);
    const line = quote?.ok ? quote.lines.find((l) => l.product_id === p.id) : undefined;
    return {
      id: p.id,
      sku: p.sku,
      name: p.name,
      category: p.category,
      isKit,
      stock: stockQty,
      lowStock: lowStock[p.id] ?? false,
      unitPrice: line?.sale_unit_price ?? null,
    };
  }

  async function handleConfirm() {
    const payload = {
      items: cartItems,
      location_id: locationId,
      sales_channel_id: channelId,
      payment_method_id: paymentMethodId,
      customer_id: customer?.id ?? null,
      doctor_id: doctorId === "none" ? null : doctorId,
      notes: notes.trim() || null,
      is_free_sale: isFreeSale,
      free_sale_reason: isFreeSale ? freeSaleReason || null : null,
      free_sale_notes: isFreeSale ? freeSaleNotes.trim() || null : null,
    };
    const parsed = newSaleSchema.safeParse(payload);
    if (!parsed.success) {
      toast.error(parsed.error.issues[0]?.message ?? "Revisá los datos de la venta.");
      return;
    }

    setConfirming(true);
    const { data, error } = await supabase.rpc("create_sale", {
      p_items: parsed.data.items,
      p_location_id: parsed.data.location_id,
      p_sales_channel_id: parsed.data.sales_channel_id,
      p_payment_method_id: parsed.data.payment_method_id,
      p_customer_id: parsed.data.customer_id,
      p_doctor_id: parsed.data.doctor_id,
      p_notes: parsed.data.notes,
      p_external_source: isWeb ? externalSource.trim() || null : null,
      p_external_order_id: isWeb ? externalOrderId.trim() || null : null,
      p_is_free_sale: parsed.data.is_free_sale,
      p_free_sale_reason: parsed.data.free_sale_reason,
      p_free_sale_notes: parsed.data.free_sale_notes,
    });
    setConfirming(false);

    if (error) {
      toast.error(humanizeSaleError(error.message));
      return;
    }

    setReceipt(data as CreateSaleResult);
    setCartOpen(false);
  }

  function resetForNewSale() {
    setCart({});
    setCustomer(null);
    setDoctorId("none");
    setNotes("");
    setQuote(null);
    setReceipt(null);
    setIsFreeSale(false);
    setFreeSaleReason("");
    setFreeSaleNotes("");
  }

  if (receipt) {
    return <ReceiptView receipt={receipt} onNewSale={resetForNewSale} />;
  }

  return (
    <div className="flex flex-col gap-4 pb-4">
      <div className="sticky top-14 z-20 flex flex-col gap-3 border-b border-border bg-background/95 px-4 pb-3 pt-3 backdrop-blur md:top-16 md:px-6">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-lg font-semibold">Nueva venta</h1>
            <p className="text-xs text-muted-foreground">{seller.fullName}</p>
          </div>
          {!online ? (
            <Badge variant="destructive" className="gap-1">
              <WifiOff className="size-3" /> Sin conexión
            </Badge>
          ) : null}
        </div>

        <div className="grid grid-cols-2 gap-2">
          <div className="flex flex-col gap-1">
            <Label className="text-xs text-muted-foreground">Canal</Label>
            <Select value={channelId} onValueChange={setChannelId}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {channels.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {c.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="flex flex-col gap-1">
            <Label className="text-xs text-muted-foreground">
              {isWeb ? "Sucursal de despacho" : "Sucursal"}
            </Label>
            <Select value={locationId} onValueChange={setLocationId}>
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

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Buscar producto…"
            className="pl-9"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        </div>
      </div>

      <div className="px-4 md:px-6">
        {filteredProducts.length === 0 ? (
          <EmptyState
            title="No encontramos productos que coincidan con tu búsqueda."
            className="mt-6"
          />
        ) : (
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
            {filteredProducts.map((p) => (
              <ProductCard
                key={p.id}
                product={productCardData(p)}
                quantity={cart[p.id] ?? 0}
                onChange={(qty) => setQuantity(p.id, qty)}
              />
            ))}
          </div>
        )}
      </div>

      {/* Cliente / doctora */}
      <div className="flex flex-col gap-3 px-4 md:px-6">
        <Separator />
        <div className="flex flex-wrap gap-2">
          <Button variant="outline" size="sm" onClick={() => setCustomerDialogOpen(true)}>
            <User className="size-4" />
            {customer ? customer.full_name : "+ Cliente (opcional)"}
          </Button>
          {customer ? (
            <Button variant="ghost" size="sm" onClick={() => setCustomer(null)}>
              <X className="size-4" /> Quitar
            </Button>
          ) : null}

          <Select value={doctorId} onValueChange={setDoctorId}>
            <SelectTrigger className="w-auto min-w-40 gap-2">
              <UserRound className="size-4 text-muted-foreground" />
              <SelectValue placeholder="Doctora (opcional)" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="none">Sin doctora</SelectItem>
              {doctors.map((d) => (
                <SelectItem key={d.id} value={d.id}>
                  {d.full_name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        {isWeb ? (
          <div className="grid grid-cols-2 gap-2">
            <Input
              placeholder="Nº de pedido (opcional)"
              value={externalOrderId}
              onChange={(e) => setExternalOrderId(e.target.value)}
            />
            <Input
              placeholder="Origen (ej: tiendanube)"
              value={externalSource}
              onChange={(e) => setExternalSource(e.target.value)}
            />
          </div>
        ) : null}

        <Textarea
          placeholder="Observaciones (opcional)"
          value={notes}
          onChange={(e) => setNotes(e.target.value)}
          rows={2}
        />
      </div>

      {/* Venta sin costo */}
      <div className="flex flex-col gap-2 px-4 md:px-6">
        <div className="flex items-center justify-between rounded-xl border border-border bg-card px-4 py-3">
          <div className="flex items-center gap-2">
            <Gift className="size-4 text-muted-foreground" />
            <div>
              <p className="text-sm font-medium">Venta sin costo</p>
              <p className="text-xs text-muted-foreground">Regalo, muestra, canje o cortesía — total $0</p>
            </div>
          </div>
          <Switch checked={isFreeSale} onCheckedChange={setIsFreeSale} />
        </div>

        {isFreeSale ? (
          <div className="flex flex-col gap-2 rounded-xl border border-warning/40 bg-warning/10 p-3.5">
            <Label className="text-sm">Motivo</Label>
            <Select value={freeSaleReason} onValueChange={(v) => setFreeSaleReason(v as typeof freeSaleReason)}>
              <SelectTrigger>
                <SelectValue placeholder="Seleccioná un motivo" />
              </SelectTrigger>
              <SelectContent>
                {FREE_SALE_REASONS.map((r) => (
                  <SelectItem key={r.value} value={r.value}>
                    {r.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            {freeSaleReason === "OTHER" ? (
              <Textarea
                placeholder="Contá el motivo…"
                value={freeSaleNotes}
                onChange={(e) => setFreeSaleNotes(e.target.value)}
                rows={2}
              />
            ) : null}
          </div>
        ) : null}
      </div>

      {/* Medio de pago (no aplica a venta sin costo) */}
      {!isFreeSale ? (
        <div className="flex flex-col gap-2 px-4 md:px-6">
          <Label className="text-sm">Medio de pago</Label>
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
            {paymentMethods.map((pm) => {
              const Icon = PAYMENT_ICONS[pm.code] ?? Banknote;
              const active = pm.id === paymentMethodId;
              return (
                <button
                  key={pm.id}
                  type="button"
                  onClick={() => setPaymentMethodId(pm.id)}
                  className={cn(
                    "flex min-h-20 flex-col items-center justify-center gap-1.5 rounded-xl border-2 px-2 py-3 text-center text-xs font-medium leading-tight transition-colors",
                    active
                      ? "border-primary bg-primary/10 text-primary"
                      : "border-border text-muted-foreground hover:bg-accent"
                  )}
                >
                  <Icon className="size-5 shrink-0" />
                  <span className="text-balance">{pm.name}</span>
                </button>
              );
            })}
          </div>
        </div>
      ) : null}

      {/* Carrito flotante */}
      <Sheet open={cartOpen} onOpenChange={setCartOpen}>
        <SheetTrigger asChild>
          <div className="fixed inset-x-4 bottom-20 z-30 md:bottom-6 md:left-auto md:right-6 md:w-96">
            {cartCount > 0 ? (
              <Button size="xl" className="w-full justify-between shadow-lg">
                <span className="flex items-center gap-2">
                  <ShoppingCart className="size-5" /> {cartCount} {cartCount === 1 ? "producto" : "productos"}
                </span>
                <span>{quote?.ok ? formatCurrency(quote.total) : quoting ? "…" : ""}</span>
              </Button>
            ) : null}
          </div>
        </SheetTrigger>
        <SheetContent side="bottom" className="flex max-h-[85dvh] flex-col">
          <SheetHeader>
            <SheetTitle>Resumen de la venta</SheetTitle>
          </SheetHeader>

          <div className="flex-1 overflow-y-auto">
            <CartSummary
              cartItems={cartItems}
              products={products}
              quote={quote}
              quoting={quoting}
              onRemove={(id) => setQuantity(id, 0)}
            />
          </div>

          <SheetFooter>
            <Button
              size="xl"
              className="w-full"
              disabled={
                !online ||
                !quote?.ok ||
                confirming ||
                cartItems.length === 0 ||
                (isFreeSale && !freeSaleReason)
              }
              onClick={handleConfirm}
            >
              {confirming ? <Loader2 className="animate-spin" /> : null}
              {!online
                ? "Necesitás conexión para confirmar la venta"
                : isFreeSale
                  ? "Confirmar entrega sin costo"
                  : quote?.ok
                    ? `Confirmar venta · ${formatCurrency(quote.total)}`
                    : "Confirmar venta"}
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>

      <CustomerPickerDialog open={customerDialogOpen} onOpenChange={setCustomerDialogOpen} onSelect={setCustomer} />
    </div>
  );
}

function CartSummary({
  cartItems,
  products,
  quote,
  quoting,
  onRemove,
}: {
  cartItems: { product_id: string; quantity: number }[];
  products: ProductOption[];
  quote: PricingQuoteResult | null;
  quoting: boolean;
  onRemove: (productId: string) => void;
}) {
  if (cartItems.length === 0) {
    return <p className="py-8 text-center text-sm text-muted-foreground">Todavía no agregaste productos.</p>;
  }

  return (
    <div className="flex flex-col gap-4 pb-4">
      <div className="flex flex-col divide-y divide-border">
        {cartItems.map((item) => {
          const product = products.find((p) => p.id === item.product_id);
          const line = quote?.ok ? quote.lines.find((l) => l.product_id === item.product_id) : undefined;
          return (
            <div key={item.product_id} className="flex items-center justify-between gap-2 py-2.5">
              <div className="min-w-0">
                <p className="truncate text-sm font-medium">{product?.name ?? item.product_id}</p>
                <p className="text-xs text-muted-foreground">
                  {item.quantity} × {line ? formatCurrency(line.sale_unit_price) : "…"}
                </p>
              </div>
              <div className="flex items-center gap-2">
                <span className="text-sm font-semibold">{line ? formatCurrency(line.line_total) : "…"}</span>
                <Button variant="ghost" size="icon" className="size-7" onClick={() => onRemove(item.product_id)}>
                  <X className="size-4" />
                </Button>
              </div>
            </div>
          );
        })}
      </div>

      <Separator />

      {quoting ? (
        <p className="text-center text-sm text-muted-foreground">Calculando precio…</p>
      ) : quote?.ok ? (
        <div className="flex flex-col gap-1.5">
          <div className="flex justify-between text-sm text-muted-foreground">
            <span>Subtotal lista</span>
            <span>{formatCurrency(quote.subtotal)}</span>
          </div>
          <div className="flex items-center justify-between text-sm">
            <Badge variant="secondary" className="font-normal">
              {quote.explanation}
            </Badge>
            {quote.discount_total > 0 ? (
              <span className="text-success-foreground">-{formatCurrency(quote.discount_total)}</span>
            ) : null}
          </div>
          <Separator className="my-1" />
          <div className="flex items-center justify-between">
            <span className="text-base font-semibold">TOTAL</span>
            <span className="text-2xl font-bold tabular-nums">{formatCurrency(quote.total)}</span>
          </div>
        </div>
      ) : quote && !quote.ok ? (
        <p className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">{quote.error_message}</p>
      ) : null}
    </div>
  );
}

function ReceiptView({ receipt, onNewSale }: { receipt: CreateSaleResult; onNewSale: () => void }) {
  return (
    <div className="mx-auto flex max-w-md flex-col items-center gap-5 px-4 py-10 text-center">
      <div className="flex size-16 items-center justify-center rounded-full bg-success/20">
        <CheckCircle2 className="size-9 text-success" />
      </div>
      <div>
        <h1 className="text-xl font-semibold">
          {receipt.is_free_sale ? "Entrega sin costo registrada" : "Venta registrada"}
        </h1>
        <p className="text-sm text-muted-foreground">{receipt.sale_number}</p>
      </div>

      <div className="w-full rounded-xl border border-border bg-card p-5 text-left shadow-sm">
        <div className="flex flex-col gap-1.5 text-sm">
          {receipt.lines.map((line) => (
            <div key={line.product_id} className="flex justify-between">
              <span>
                {line.quantity} × {line.name}
              </span>
              <span className="font-medium">{formatCurrency(line.line_total)}</span>
            </div>
          ))}
        </div>
        <Separator className="my-3" />
        <div className="flex justify-between text-sm text-muted-foreground">
          <span>{receipt.applied_price_condition_name ?? receipt.explanation}</span>
          <span>-{formatCurrency(receipt.discount_total)}</span>
        </div>
        <div className="mt-1 flex items-center justify-between">
          <span className="font-semibold">TOTAL</span>
          <span className="text-2xl font-bold">{formatCurrency(receipt.total)}</span>
        </div>
      </div>

      <div className="flex w-full flex-col gap-2">
        <Button size="lg" onClick={onNewSale}>
          Nueva venta
        </Button>
        <Button variant="outline" size="lg" asChild>
          <Link href={`/ventas/${receipt.sale_id}`}>Ver detalle</Link>
        </Button>
        <Button
          variant="ghost"
          size="lg"
          onClick={() => {
            const text = `${receipt.sale_number}\n${receipt.lines
              .map((l) => `${l.quantity}x ${l.name} — ${formatCurrency(l.line_total)}`)
              .join("\n")}\nTotal: ${formatCurrency(receipt.total)}`;
            navigator.clipboard.writeText(text);
            toast.success("Resumen copiado.");
          }}
        >
          <ClipboardCopy className="size-4" /> Copiar resumen
        </Button>
      </div>
    </div>
  );
}

function humanizeSaleError(message: string): string {
  // Los mensajes de create_sale() ya son legibles (RAISE EXCEPTION con texto en español).
  // Esto es un fallback por si llega algo técnico de Postgres/PostgREST.
  if (message.toLowerCase().includes("jwt") || message.toLowerCase().includes("auth")) {
    return "Tu sesión expiró. Volvé a ingresar.";
  }
  return message;
}
