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
  Plus,
  Undo2,
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
import type { CreateSaleReturnResult, ReturnableSale, ReturnableSaleItem, SaleRefundMethod } from "@/types/database";

const PAYMENT_ICONS: Record<string, React.ElementType> = {
  CASH: Banknote,
  TRANSFER: Landmark,
  CARD_3: CreditCard,
  CARD_1: CreditCard,
};

type Step = "dni" | "sales" | "items" | "confirm" | "success";

// Nota (sección 45/1 del audit + precisión del usuario): Devolución NUNCA
// reutiliza sale_exchanges — usa sale_returns/sale_return_items, tablas
// separadas, y customer_sales_for_return (no customer_sales_for_exchange).
// A diferencia del Cambio (una sola línea devuelta + un producto nuevo),
// acá se puede devolver MÁS DE UNA línea en un mismo evento — por eso el
// paso "items" es una lista con cantidad por línea, no una selección única.
export function DevolucionClient() {
  const supabase = useMemo(() => createClient(), []);

  const [step, setStep] = useState<Step>("dni");

  // Paso 1: búsqueda por DNI — mismo patrón que CambiosClient (deliberadamente
  // duplicado, no importado desde ahí: el flujo de Cambio de producto no se
  // toca para nada al construir este, ni siquiera para extraer algo en común).
  const [dni, setDni] = useState("");
  const [dniStatus, setDniStatus] = useState<"idle" | "searching" | "found" | "not_found">("idle");
  const [customer, setCustomer] = useState<{ id: string; full_name: string; dni: string | null } | null>(null);

  // Paso 2: ventas elegibles del cliente (customer_sales_for_return).
  const [sales, setSales] = useState<ReturnableSale[] | null>(null);
  const [loadingSales, setLoadingSales] = useState(false);

  // Paso 3: venta seleccionada + cantidad a devolver por línea (0 = no
  // incluida). Una devolución puede tocar varias líneas de la misma venta.
  const [selectedSale, setSelectedSale] = useState<ReturnableSale | null>(null);
  const [selections, setSelections] = useState<Record<string, number>>({});
  const [refundMethod, setRefundMethod] = useState<SaleRefundMethod>("CASH");
  const [paymentAccounts, setPaymentAccounts] = useState<{ id: string; name: string }[]>([]);
  const [paymentAccountId, setPaymentAccountId] = useState<string | null>(null);

  const [notes, setNotes] = useState("");
  const [confirming, setConfirming] = useState(false);
  const [result, setResult] = useState<CreateSaleReturnResult | null>(null);

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

  // Cuentas de reintegro — solo hacen falta si se elige Transferencia, pero
  // se cargan una vez apenas arranca el flujo (lista corta, sin costo real).
  useEffect(() => {
    void supabase
      .from("payment_accounts")
      .select("id, name")
      .eq("active", true)
      .order("sort_order")
      .then(({ data }) => setPaymentAccounts(data ?? []));
  }, [supabase]);

  async function handleUseCustomer() {
    if (!customer) return;
    setLoadingSales(true);
    setStep("sales");
    const { data, error } = await supabase.rpc("customer_sales_for_return", { p_customer_id: customer.id });
    setLoadingSales(false);
    if (error) {
      toast.error(error.message);
      setSales([]);
      return;
    }
    setSales(data ?? []);
  }

  function handleSelectSale(sale: ReturnableSale) {
    setSelectedSale(sale);
    setSelections({});
    setRefundMethod("CASH");
    setPaymentAccountId(null);
    setStep("items");
  }

  function setItemQty(item: ReturnableSaleItem, qty: number) {
    const clamped = Math.max(0, Math.min(item.available_to_return, qty));
    setSelections((prev) => {
      const next = { ...prev };
      if (clamped === 0) delete next[item.sale_item_id];
      else next[item.sale_item_id] = clamped;
      return next;
    });
  }

  const selectedItems = (selectedSale?.items ?? []).filter((i) => (selections[i.sale_item_id] ?? 0) > 0);
  const refundTotal = selectedItems.reduce(
    (sum, i) => sum + Number(i.sale_unit_price) * (selections[i.sale_item_id] ?? 0),
    0
  );
  const canContinueFromItems = selectedItems.length > 0;
  const canConfirm = canContinueFromItems && (refundMethod === "CASH" || paymentAccountId !== null);

  async function handleConfirm() {
    if (!selectedSale || !canConfirm) return;
    setConfirming(true);
    const { data, error } = await supabase.rpc("create_sale_return", {
      p_original_sale_id: selectedSale.sale_id,
      p_items: selectedItems.map((i) => ({ sale_item_id: i.sale_item_id, quantity: selections[i.sale_item_id] })),
      p_refund_method: refundMethod,
      p_payment_account_id: refundMethod === "TRANSFER" ? paymentAccountId : null,
      p_notes: notes.trim() || null,
    });
    setConfirming(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    setResult(data);
    setStep("success");
    toast.success("Devolución registrada.");
  }

  function handleReset() {
    setStep("dni");
    setDni("");
    setDniStatus("idle");
    setCustomer(null);
    setSales(null);
    setSelectedSale(null);
    setSelections({});
    setRefundMethod("CASH");
    setPaymentAccountId(null);
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
            <Undo2 className="size-5" /> Devolución de producto
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
              <Label htmlFor="dni-devolucion">DNI del cliente</Label>
              <div className="relative">
                <Input
                  id="dni-devolucion"
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
                No encontramos un cliente con este DNI. Una devolución siempre necesita partir de una venta
                original identificada — si el cliente todavía no está cargado, buscalo o creálo primero desde
                Clientes.
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
              title="Sin ventas para devolver"
              description="Este cliente no tiene ventas confirmadas en tus sedes que puedan usarse como origen de una devolución."
            />
          ) : (
            sales.map((sale) => {
              const Icon = PAYMENT_ICONS[sale.payment_method_code] ?? Banknote;
              const anyAvailable = sale.items.some((i) => i.available_to_return > 0);
              return (
                <button
                  key={sale.sale_id}
                  type="button"
                  disabled={!anyAvailable}
                  onClick={() => handleSelectSale(sale)}
                  className={cn(
                    "flex flex-col gap-1 rounded-xl border border-border bg-card p-4 text-left shadow-sm transition-colors hover:border-primary",
                    !anyAvailable && "cursor-not-allowed opacity-50 hover:border-border"
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
                    {sale.billing_status === "INVOICED" ? <Badge variant="outline">Facturada</Badge> : null}
                    {!anyAvailable ? <Badge variant="secondary">Ya devuelta en su totalidad</Badge> : null}
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

      {step === "items" && selectedSale ? (
        <div className="flex flex-col gap-4">
          <Card>
            <CardContent className="grid grid-cols-2 gap-3 p-4 text-sm">
              <Field label="Cliente" value={customer?.full_name ?? "—"} />
              <Field label="Fecha" value={formatDateTime(selectedSale.sold_at)} />
              <Field label="Sucursal" value={selectedSale.location_name} />
              <Field label="Medio de pago" value={selectedSale.payment_method_name} />
            </CardContent>
          </Card>

          {selectedSale.billing_status === "INVOICED" ? (
            <p className="rounded-lg border border-amber-600/30 bg-amber-600/10 px-3 py-2 text-xs text-amber-800 dark:text-amber-400">
              Esta venta ya está facturada. La devolución no modifica el comprobante fiscal original — eso
              requiere una nota de crédito por fuera de este sistema.
            </p>
          ) : null}

          <div>
            <p className="mb-2 text-sm font-medium">¿Qué productos devuelve? (podés elegir más de uno)</p>
            <div className="flex flex-col gap-2">
              {selectedSale.items.map((item) => {
                const qty = selections[item.sale_item_id] ?? 0;
                const exhausted = item.available_to_return <= 0;
                return (
                  <div
                    key={item.sale_item_id}
                    className={cn(
                      "flex items-center justify-between gap-3 rounded-lg border border-border bg-card p-3 text-sm",
                      qty > 0 && "border-primary ring-1 ring-primary",
                      exhausted && "opacity-50"
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
                        {exhausted
                          ? "Ya devuelto en su totalidad"
                          : `Disponible: ${item.available_to_return} de ${item.quantity} · ${formatCurrency(item.sale_unit_price)} c/u (precio pagado)`}
                      </span>
                    </div>
                    <div className="flex items-center gap-2 rounded-md bg-secondary">
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon"
                        className="size-8"
                        disabled={exhausted || qty <= 0}
                        onClick={() => setItemQty(item, qty - 1)}
                      >
                        <Minus className="size-4" />
                      </Button>
                      <span className="min-w-6 text-center text-sm font-semibold tabular-nums">{qty}</span>
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon"
                        className="size-8"
                        disabled={exhausted || qty >= item.available_to_return}
                        onClick={() => setItemQty(item, qty + 1)}
                      >
                        <Plus className="size-4" />
                      </Button>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>

          {canContinueFromItems ? (
            <Card>
              <CardContent className="flex flex-col gap-3 p-4">
                <div className="flex items-center justify-between text-sm">
                  <span className="text-muted-foreground">Total a reintegrar</span>
                  <span className="text-lg font-semibold">{formatCurrency(refundTotal)}</span>
                </div>

                <div className="flex flex-col gap-1.5">
                  <Label>Forma de reintegro</Label>
                  <div className="flex gap-2">
                    <Button
                      type="button"
                      variant={refundMethod === "CASH" ? "default" : "outline"}
                      className="flex-1"
                      onClick={() => setRefundMethod("CASH")}
                    >
                      <Banknote className="size-4" /> Efectivo
                    </Button>
                    <Button
                      type="button"
                      variant={refundMethod === "TRANSFER" ? "default" : "outline"}
                      className="flex-1"
                      onClick={() => setRefundMethod("TRANSFER")}
                    >
                      <Landmark className="size-4" /> Transferencia
                    </Button>
                  </div>
                </div>

                {refundMethod === "TRANSFER" ? (
                  <div className="flex flex-col gap-1.5">
                    <Label>Cuenta desde la que sale el dinero</Label>
                    <div className="flex flex-wrap gap-2">
                      {paymentAccounts.map((acc) => (
                        <Button
                          key={acc.id}
                          type="button"
                          size="sm"
                          variant={paymentAccountId === acc.id ? "default" : "outline"}
                          onClick={() => setPaymentAccountId(acc.id)}
                        >
                          {acc.name}
                        </Button>
                      ))}
                    </div>
                  </div>
                ) : null}

                <Button type="button" disabled={!canConfirm} onClick={() => setStep("confirm")}>
                  Continuar — revisar y confirmar
                </Button>
              </CardContent>
            </Card>
          ) : null}
        </div>
      ) : null}

      {step === "confirm" && selectedSale && canConfirm ? (
        <div className="flex flex-col gap-4">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Resumen de la devolución</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-col gap-2.5 p-5 pt-0 text-sm">
              <Row label="Cliente" value={customer?.full_name ?? "—"} />
              <Row label="Venta original" value={selectedSale.sale_number} />
              <Separator />
              {selectedItems.map((item) => (
                <Row
                  key={item.sale_item_id}
                  label={`${selections[item.sale_item_id]} × ${item.name}`}
                  value={formatCurrency(Number(item.sale_unit_price) * selections[item.sale_item_id])}
                  muted
                />
              ))}
              <Separator />
              <Row label="Total a reintegrar" value={formatCurrency(refundTotal)} strong />
              <Row
                label="Forma de reintegro"
                value={refundMethod === "CASH" ? "Efectivo" : `Transferencia — ${paymentAccounts.find((a) => a.id === paymentAccountId)?.name ?? ""}`}
              />
            </CardContent>
          </Card>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="notes-devolucion">Observaciones (opcional)</Label>
            <Textarea id="notes-devolucion" rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} />
          </div>

          <Button size="lg" disabled={confirming} onClick={handleConfirm}>
            {confirming ? <Loader2 className="animate-spin" /> : null}
            Confirmar devolución
          </Button>
        </div>
      ) : null}

      {step === "success" && result ? (
        <Card>
          <CardContent className="flex flex-col items-center gap-3 p-8 text-center">
            <CheckCircle2 className="size-10 text-success" />
            <p className="text-lg font-semibold">Devolución registrada</p>
            <p className="text-sm text-muted-foreground">
              Se reintegraron {formatCurrency(result.refund_amount)}.{" "}
              {result.is_full_return
                ? "La venta quedó devuelta en su totalidad."
                : "El resto de la venta original sigue vigente."}
            </p>
            <div className="flex gap-2">
              <Button asChild>
                <Link href={`/ventas/${result.original_sale_id}`}>Ver venta</Link>
              </Button>
              <Button variant="outline" onClick={handleReset}>
                Hacer otra devolución
              </Button>
            </div>
          </CardContent>
        </Card>
      ) : null}
    </div>
  );

  function goBack() {
    if (step === "sales") setStep("dni");
    else if (step === "items") setStep("sales");
    else if (step === "confirm") setStep("items");
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
}: {
  label: string;
  value: string;
  muted?: boolean;
  strong?: boolean;
}) {
  return (
    <div className="flex items-center justify-between gap-2">
      <span className="text-muted-foreground">{label}</span>
      <span className={cn(muted && "text-muted-foreground", strong && "text-base font-semibold")}>{value}</span>
    </div>
  );
}
