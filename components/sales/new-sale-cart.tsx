"use client";

import { useState } from "react";
import {
  AlertTriangle,
  Banknote,
  ChevronDown,
  ClipboardCopy,
  CreditCard,
  Gift,
  History,
  Landmark,
  Loader2,
  ShoppingCart,
  UserRound,
  X,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Separator } from "@/components/ui/separator";
import { Sheet, SheetContent, SheetFooter, SheetHeader, SheetTitle, SheetTrigger } from "@/components/ui/sheet";
import { Switch } from "@/components/ui/switch";
import { Textarea } from "@/components/ui/textarea";
import { CustomerPickerFields, type CustomerOption } from "@/components/sales/customer-picker-dialog";
import { useMediaQuery } from "@/lib/hooks/use-media-query";
import { cn, formatCurrency } from "@/lib/utils";
import type { FreeSaleReason, PricingQuoteResult } from "@/types/database";

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
  image_url: string | null;
  kitContents: string[] | null;
}
interface PromotionOption {
  id: string;
  name: string;
  type: "THREE_FOR_TWO" | "DUO_PERCENT" | "KIT_PERCENT";
  discount_percent: string | null;
  group_size: number;
}
interface PaymentMethodOption {
  id: string;
  code: string;
  name: string;
}
interface PaymentAccountOption {
  id: string;
  code: string;
  name: string;
  alias: string | null;
}

const PAYMENT_ICONS: Record<string, React.ElementType> = {
  CASH: Banknote,
  TRANSFER: Landmark,
  CARD_3: CreditCard,
  CARD_1: CreditCard,
};

const FREE_SALE_REASONS: { value: FreeSaleReason; label: string }[] = [
  { value: "GIFT", label: "Regalo" },
  { value: "SAMPLE", label: "Muestra" },
  { value: "EXCHANGE", label: "Canje" },
  { value: "COURTESY", label: "Cortesía" },
  { value: "OTHER", label: "Otro" },
];

/** "Promoción aplicada: 20% OFF" / "Promoción aplicada: 3x2" — sección 15 del pedido. */
function promoLabel(p: PromotionOption): string {
  if (p.type === "THREE_FOR_TWO") return `Promoción aplicada: 3x${p.group_size - 1}`;
  const pct = p.discount_percent ? Math.round(Number(p.discount_percent) * 100) : 0;
  return `Promoción aplicada: ${pct}% OFF`;
}

/**
 * Carrito unificado de Nueva Venta (rediseño UX) — todo lo que compone la
 * operación (productos, cliente, doctora, datos adicionales, medio de pago,
 * cuenta/alias, resumen y confirmación) vive ACÁ, en un único lugar, en el
 * orden A-G pedido. new-sale-client.tsx (el padre) sigue siendo la única
 * fuente de estado — este componente es puramente de presentación, recibe
 * todo por props y notifica cambios por callbacks, sin estado propio salvo
 * el puramente visual (qué bloque está expandido).
 *
 * Desktop: panel lateral NO modal (sin overlay, sin bloquear el catálogo de
 * fondo — sección 20 del pedido: "si el drawer bloquea completamente el
 * catálogo, evaluar un panel lateral persistente"). Mobile: sheet modal
 * full-screen desde abajo (sección 21).
 */
export function NewSaleCart({
  open,
  onOpenChange,
  cartCount,
  cartItems,
  products,
  promotions,
  quote,
  quoting,
  onRemoveItem,
  isAdmin,
  manualPrices,
  onManualPriceChange,
  onClearManualPrices,
  customer,
  onSelectCustomer,
  onClearCustomer,
  doctors,
  doctorId,
  onDoctorIdChange,
  isWeb,
  externalSource,
  onExternalSourceChange,
  externalOrderId,
  onExternalOrderIdChange,
  notes,
  onNotesChange,
  isFreeSale,
  onIsFreeSaleChange,
  freeSaleReason,
  onFreeSaleReasonChange,
  freeSaleNotes,
  onFreeSaleNotesChange,
  isAdminHistoricalAllowed,
  isHistorical,
  onIsHistoricalChange,
  historicalSoldAt,
  onHistoricalSoldAtChange,
  skipStockMovement,
  onSkipStockMovementChange,
  paymentMethods,
  paymentMethodId,
  onPaymentMethodChange,
  requiresPaymentAccount,
  paymentAccounts,
  paymentAccountId,
  onPaymentAccountChange,
  showAlias,
  online,
  confirming,
  onConfirm,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  cartCount: number;
  cartItems: { product_id: string; quantity: number; manual_price?: number }[];
  products: ProductOption[];
  promotions: PromotionOption[];
  quote: PricingQuoteResult | null;
  quoting: boolean;
  onRemoveItem: (productId: string) => void;
  isAdmin: boolean;
  manualPrices: Record<string, string>;
  onManualPriceChange: (productId: string, value: string) => void;
  onClearManualPrices: () => void;
  customer: CustomerOption | null;
  onSelectCustomer: (customer: CustomerOption) => void;
  onClearCustomer: () => void;
  doctors: DoctorOption[];
  doctorId: string;
  onDoctorIdChange: (id: string) => void;
  isWeb: boolean;
  externalSource: string;
  onExternalSourceChange: (v: string) => void;
  externalOrderId: string;
  onExternalOrderIdChange: (v: string) => void;
  notes: string;
  onNotesChange: (v: string) => void;
  isFreeSale: boolean;
  onIsFreeSaleChange: (v: boolean) => void;
  freeSaleReason: FreeSaleReason | "";
  onFreeSaleReasonChange: (v: FreeSaleReason | "") => void;
  freeSaleNotes: string;
  onFreeSaleNotesChange: (v: string) => void;
  isAdminHistoricalAllowed: boolean;
  isHistorical: boolean;
  onIsHistoricalChange: (v: boolean) => void;
  historicalSoldAt: string;
  onHistoricalSoldAtChange: (v: string) => void;
  skipStockMovement: boolean;
  onSkipStockMovementChange: (v: boolean) => void;
  paymentMethods: PaymentMethodOption[];
  paymentMethodId: string;
  onPaymentMethodChange: (id: string) => void;
  requiresPaymentAccount: boolean;
  paymentAccounts: PaymentAccountOption[];
  paymentAccountId: string;
  onPaymentAccountChange: (id: string) => void;
  showAlias: boolean;
  online: boolean;
  confirming: boolean;
  onConfirm: () => void;
}) {
  const isDesktop = useMediaQuery("(min-width: 768px)");
  const [moreOptionsOpen, setMoreOptionsOpen] = useState(false);

  const selectedPaymentAccount = paymentAccounts.find((pa) => pa.id === paymentAccountId);
  const promoById = new Map(promotions.map((p) => [p.id, p]));

  // Validaciones contextuales (sección 18 del pedido): se calculan acá para
  // mostrarlas ANTES de confirmar, nunca esperar a que create_sale() falle.
  // El backend sigue siendo la autoridad real — esto es una capa de UX,
  // igual criterio que el resto de las validaciones de este formulario.
  const issues: string[] = [];
  if (cartItems.length === 0) issues.push("Agregá al menos un producto.");
  if (!paymentMethodId) issues.push("Elegí un medio de pago.");
  if (requiresPaymentAccount && !customer?.dni) issues.push("Para este medio de pago necesitás asociar un cliente con DNI.");
  if (requiresPaymentAccount && !paymentAccountId) issues.push("Elegí la cuenta donde ingresó el dinero.");
  if (isFreeSale && !freeSaleReason) issues.push("Elegí un motivo para la entrega sin costo.");
  if (isHistorical && !historicalSoldAt) issues.push("Elegí la fecha de la venta histórica.");
  if (quote && !quote.ok) issues.push(quote.error_message);

  const canConfirm = online && !confirming && issues.length === 0 && !!quote?.ok;

  return (
    <Sheet open={open} onOpenChange={onOpenChange} modal={!isDesktop}>
      <SheetTrigger asChild>
        <div className="fixed inset-x-4 bottom-20 z-30 md:bottom-6 md:left-auto md:right-6 md:w-96">
          {/* Oculto mientras el carrito ya está abierto — en desktop el panel
              persistente ocupa ese mismo costado, se superpondría. */}
          {cartCount > 0 && !open ? (
            <Button size="xl" className="w-full justify-between shadow-lg">
              <span className="flex items-center gap-2">
                <ShoppingCart className="size-5" /> Carrito · {cartCount} {cartCount === 1 ? "producto" : "productos"}
              </span>
              <span>{quote?.ok ? formatCurrency(quote.total) : quoting ? "…" : ""}</span>
            </Button>
          ) : null}
        </div>
      </SheetTrigger>

      <SheetContent
        side={isDesktop ? "right" : "bottom"}
        showOverlay={!isDesktop}
        // Desktop: el panel es persistente mientras se sigue comprando —
        // clickear un producto del catálogo de fondo no lo tiene que cerrar
        // (sección 20/22 del pedido). Escape y el botón de cerrar siguen andando.
        onPointerDownOutside={(e) => {
          if (isDesktop) e.preventDefault();
        }}
        onInteractOutside={(e) => {
          if (isDesktop) e.preventDefault();
        }}
        className={cn("flex flex-col", isDesktop ? "w-[45%] max-w-2xl" : "max-h-[92dvh]")}
      >
        <SheetHeader>
          <SheetTitle>Carrito · Resumen de venta</SheetTitle>
        </SheetHeader>

        <div className="flex-1 overflow-y-auto">
          {cartItems.length === 0 ? (
            <p className="py-8 text-center text-sm text-muted-foreground">Todavía no agregaste productos.</p>
          ) : (
            <div className="flex flex-col gap-5 pb-4">
              {/* A. Productos */}
              <div className="flex flex-col divide-y divide-border">
                {cartItems.map((item) => {
                  const product = products.find((p) => p.id === item.product_id);
                  // Una promoción (3x2, duo%) puede partir un mismo producto
                  // en más de una línea del quote — hay que sumar todas las
                  // que le correspondan, nunca tomar solo la primera.
                  const lines = quote?.ok ? quote.lines.filter((l) => l.product_id === item.product_id) : [];
                  const lineTotal = lines.length > 0 ? lines.reduce((sum, l) => sum + l.line_total, 0) : null;
                  const appliedPromotionId = lines.find((l) => l.applied_promotion_id)?.applied_promotion_id;
                  const promo = appliedPromotionId ? promoById.get(appliedPromotionId) : undefined;
                  const hasManualPrice = lines.some((l) => l.manual_price);
                  const avgUnitPrice = lines.length > 0 ? lineTotal! / item.quantity : null;
                  return (
                    <div key={item.product_id} className="flex flex-col gap-1.5 py-2.5">
                      <div className="flex items-center justify-between gap-2">
                        <div className="min-w-0">
                          <div className="flex items-center gap-1.5">
                            <p className="truncate text-sm font-medium">{product?.name ?? item.product_id}</p>
                            {hasManualPrice ? (
                              <Badge variant="outline" className="shrink-0 font-normal">
                                Precio manual
                              </Badge>
                            ) : null}
                          </div>
                          <p className="text-xs text-muted-foreground">
                            {item.quantity} × {avgUnitPrice !== null ? formatCurrency(avgUnitPrice) : "…"}
                          </p>
                          {promo ? (
                            <div className="mt-1 flex flex-wrap items-center gap-1.5">
                              <Badge variant="success" className="shrink-0 font-normal">
                                {promoLabel(promo)}
                              </Badge>
                              <span className="text-[11px] text-muted-foreground">No acumulable con otros descuentos</span>
                            </div>
                          ) : null}
                        </div>
                        <div className="flex items-center gap-2">
                          <span className="text-sm font-semibold">
                            {lineTotal !== null ? formatCurrency(lineTotal) : "…"}
                          </span>
                          <Button variant="ghost" size="icon" className="size-7" onClick={() => onRemoveItem(item.product_id)}>
                            <X className="size-4" />
                          </Button>
                        </div>
                      </div>

                      {/* Precio manual: exclusivo de admin, no combina con
                          venta sin costo (el switch lo limpia al activarse). */}
                      {isAdmin && !isFreeSale ? (
                        <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
                          Precio manual (por unidad)
                          <span className="relative">
                            <span className="pointer-events-none absolute left-2 top-1/2 -translate-y-1/2">$</span>
                            <Input
                              type="number"
                              inputMode="decimal"
                              min="0"
                              step="0.01"
                              placeholder={avgUnitPrice !== null ? String(Math.round(avgUnitPrice)) : ""}
                              value={manualPrices[item.product_id] ?? ""}
                              onChange={(e) => onManualPriceChange(item.product_id, e.target.value)}
                              className="h-7 w-24 pl-4 text-xs"
                            />
                          </span>
                        </label>
                      ) : null}
                    </div>
                  );
                })}
              </div>

              <Separator />

              {/* B. Cliente */}
              <CartCustomerSection
                customer={customer}
                onSelect={onSelectCustomer}
                onClear={onClearCustomer}
                requiresPaymentAccount={requiresPaymentAccount}
              />

              {/* C. Doctora */}
              <div className="flex flex-col gap-1.5">
                <Label className="text-sm">Doctora</Label>
                <Select value={doctorId} onValueChange={onDoctorIdChange}>
                  <SelectTrigger className="gap-2">
                    <UserRound className="size-4 text-muted-foreground" />
                    <SelectValue placeholder="Sin doctora" />
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

              {/* D. Datos adicionales — colapsado por default para no ocupar
                  espacio si no se usa (sección 9/11 del pedido). */}
              <div className="flex flex-col gap-3 rounded-xl border border-border">
                <button
                  type="button"
                  onClick={() => setMoreOptionsOpen((v) => !v)}
                  className="flex items-center justify-between px-4 py-3 text-left text-sm font-medium"
                >
                  Más opciones
                  <ChevronDown className={cn("size-4 text-muted-foreground transition-transform", moreOptionsOpen && "rotate-180")} />
                </button>

                {moreOptionsOpen ? (
                  <div className="flex flex-col gap-3 px-4 pb-4">
                    {isWeb ? (
                      <div className="grid grid-cols-2 gap-2">
                        <Input
                          placeholder="Nº de pedido (opcional)"
                          value={externalOrderId}
                          onChange={(e) => onExternalOrderIdChange(e.target.value)}
                        />
                        <Input
                          placeholder="Origen (ej: tiendanube)"
                          value={externalSource}
                          onChange={(e) => onExternalSourceChange(e.target.value)}
                        />
                      </div>
                    ) : null}

                    <div className="flex flex-col gap-1.5">
                      <Label className="text-sm">Observaciones (opcional)</Label>
                      <Textarea value={notes} onChange={(e) => onNotesChange(e.target.value)} rows={2} />
                    </div>

                    {/* Venta sin costo */}
                    <div className="flex items-center justify-between rounded-lg border border-border px-3 py-2.5">
                      <div className="flex items-center gap-2">
                        <Gift className="size-4 text-muted-foreground" />
                        <div>
                          <p className="text-sm font-medium">Venta sin costo</p>
                          <p className="text-xs text-muted-foreground">Regalo, muestra, canje o cortesía — total $0</p>
                        </div>
                      </div>
                      <Switch
                        checked={isFreeSale}
                        onCheckedChange={(checked) => {
                          onIsFreeSaleChange(checked);
                          // No combina con precio manual (el backend también
                          // lo rechaza) — se limpia para que no quede un
                          // override "fantasma" si se desactiva de nuevo.
                          if (checked) onClearManualPrices();
                        }}
                      />
                    </div>
                    {isFreeSale ? (
                      <div className="flex flex-col gap-2 rounded-xl border border-warning/40 bg-warning/10 p-3.5">
                        <Label className="text-sm">Motivo</Label>
                        <Select value={freeSaleReason} onValueChange={(v) => onFreeSaleReasonChange(v as FreeSaleReason)}>
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
                            onChange={(e) => onFreeSaleNotesChange(e.target.value)}
                            rows={2}
                          />
                        ) : null}
                      </div>
                    ) : null}

                    {/* Carga histórica: solo admin */}
                    {isAdminHistoricalAllowed && !isFreeSale ? (
                      <>
                        <div className="flex items-center justify-between rounded-lg border border-border px-3 py-2.5">
                          <div className="flex items-center gap-2">
                            <History className="size-4 text-muted-foreground" />
                            <div>
                              <p className="text-sm font-medium">Carga histórica</p>
                              <p className="text-xs text-muted-foreground">Registrar una venta con fecha pasada</p>
                            </div>
                          </div>
                          <Switch checked={isHistorical} onCheckedChange={onIsHistoricalChange} />
                        </div>
                        {isHistorical ? (
                          <div className="flex flex-col gap-3 rounded-xl border border-warning/40 bg-warning/10 p-3.5">
                            <div className="flex flex-col gap-1.5">
                              <Label className="text-sm">Fecha y hora de la venta</Label>
                              <Input
                                type="datetime-local"
                                value={historicalSoldAt}
                                onChange={(e) => onHistoricalSoldAtChange(e.target.value)}
                              />
                            </div>
                            <label className="flex items-start gap-2 text-sm">
                              <input
                                type="checkbox"
                                className="mt-0.5"
                                checked={skipStockMovement}
                                onChange={(e) => onSkipStockMovementChange(e.target.checked)}
                              />
                              <span>
                                No descontar del stock real
                                <span className="block text-xs text-muted-foreground">
                                  Para cargar ventas ya despachadas hace tiempo, cuyo stock actual ya no las refleja.
                                </span>
                              </span>
                            </label>
                          </div>
                        ) : null}
                      </>
                    ) : null}
                  </div>
                ) : null}
              </div>

              {/* E. Medio de pago */}
              {!isFreeSale ? (
                <div className="flex flex-col gap-2">
                  <Label className="text-sm">Medio de pago</Label>
                  <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
                    {paymentMethods.map((pm) => {
                      const Icon = PAYMENT_ICONS[pm.code] ?? Banknote;
                      const active = pm.id === paymentMethodId;
                      return (
                        <button
                          key={pm.id}
                          type="button"
                          onClick={() => onPaymentMethodChange(pm.id)}
                          className={cn(
                            "flex min-h-16 flex-col items-center justify-center gap-1.5 rounded-xl border-2 px-2 py-2.5 text-center text-xs font-medium leading-tight transition-colors",
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

                  {requiresPaymentAccount ? (
                    <div className="flex flex-col gap-1.5 pt-1">
                      <Label className="text-sm">Cuenta donde ingresó el dinero</Label>
                      <Select value={paymentAccountId} onValueChange={onPaymentAccountChange}>
                        <SelectTrigger>
                          <SelectValue placeholder="Elegí la cuenta" />
                        </SelectTrigger>
                        <SelectContent>
                          {paymentAccounts.map((pa) => (
                            <SelectItem key={pa.id} value={pa.id}>
                              {pa.name}
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                      <p className="text-xs text-muted-foreground">
                        Esta operación va a quedar pendiente de facturación — necesita cliente con DNI.
                      </p>

                      {showAlias ? (
                        <div className="flex flex-col gap-1.5 rounded-lg border border-primary/30 bg-primary/5 p-3">
                          <p className="text-xs font-medium text-muted-foreground">Alias para transferencia</p>
                          <div className="flex items-center justify-between gap-2">
                            <div className="min-w-0">
                              <p className="truncate text-xs text-muted-foreground">{selectedPaymentAccount!.name}</p>
                              <p className="truncate font-mono text-sm font-semibold">{selectedPaymentAccount!.alias}</p>
                            </div>
                            <Button
                              type="button"
                              variant="outline"
                              size="sm"
                              className="shrink-0"
                              onClick={() => {
                                navigator.clipboard.writeText(selectedPaymentAccount!.alias!);
                                toast.success("Alias copiado");
                              }}
                            >
                              <ClipboardCopy className="size-3.5" /> Copiar alias
                            </Button>
                          </div>
                        </div>
                      ) : null}
                    </div>
                  ) : null}
                </div>
              ) : null}

              <Separator />

              {/* F. Resumen económico */}
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
                    ) : quote.surcharge_total > 0 ? (
                      // Recargo (ej. cuotas) es válido — nunca junto al
                      // descuento, son complementarios.
                      <span className="text-destructive">+{formatCurrency(quote.surcharge_total)}</span>
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
          )}
        </div>

        {/* Validaciones contextuales — nunca se cierra el carrito con un
            error pendiente (sección 18/19 del pedido). */}
        {issues.length > 0 && cartItems.length > 0 ? (
          <div className="flex shrink-0 flex-col gap-1 rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-xs text-destructive">
            {issues.map((issue, idx) => (
              <div key={idx} className="flex items-center gap-1.5">
                <AlertTriangle className="size-3 shrink-0" /> {issue}
              </div>
            ))}
          </div>
        ) : null}

        {/* G. Confirmar */}
        <SheetFooter>
          <Button size="xl" className="w-full" disabled={!canConfirm} onClick={onConfirm}>
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
  );
}

/**
 * Bloque "Cliente" del carrito — sección 5/6 del pedido. Tres estados: sin
 * cliente (botón "Agregar cliente"), editando (CustomerPickerFields inline,
 * sin salir del carrito) y cliente elegido (vista compacta + "Cambiar").
 */
function CartCustomerSection({
  customer,
  onSelect,
  onClear,
  requiresPaymentAccount,
}: {
  customer: CustomerOption | null;
  onSelect: (c: CustomerOption) => void;
  onClear: () => void;
  requiresPaymentAccount: boolean;
}) {
  const [editing, setEditing] = useState(false);
  const missingDni = requiresPaymentAccount && (!customer || !customer.dni);

  return (
    <div className="flex flex-col gap-1.5">
      <Label className="text-sm">Cliente</Label>

      {editing ? (
        <div className="rounded-xl border border-border p-3">
          <CustomerPickerFields
            autoFocus
            onSelect={(c) => {
              onSelect(c);
              setEditing(false);
            }}
            footer={
              <Button type="button" variant="ghost" onClick={() => setEditing(false)}>
                Cancelar
              </Button>
            }
          />
        </div>
      ) : customer ? (
        <div className="flex items-center justify-between gap-2 rounded-xl border border-border bg-card px-3.5 py-2.5">
          <div className="min-w-0">
            <p className="truncate text-sm font-medium">{customer.full_name}</p>
            <p className="text-xs text-muted-foreground">{customer.dni ? `DNI ${customer.dni}` : "Sin DNI"}</p>
          </div>
          <div className="flex shrink-0 items-center gap-1">
            <Button type="button" variant="ghost" size="sm" onClick={() => setEditing(true)}>
              Cambiar
            </Button>
            <Button type="button" variant="ghost" size="icon" className="size-8" onClick={onClear}>
              <X className="size-4" />
            </Button>
          </div>
        </div>
      ) : (
        <Button type="button" variant="outline" className="h-11 justify-start gap-2" onClick={() => setEditing(true)}>
          Agregar cliente
        </Button>
      )}

      {missingDni ? (
        <p className="flex items-center gap-1.5 text-xs text-destructive">
          <AlertTriangle className="size-3 shrink-0" /> Para este medio de pago necesitás asociar un cliente con DNI.
        </p>
      ) : null}
    </div>
  );
}
