import Link from "next/link";
import { AlertTriangle, ArrowLeft, Banknote, CheckCircle2, Landmark, PackageMinus, Undo2, XCircle } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { CancelSaleDialog } from "@/components/sales/cancel-sale-dialog";
import { formatCurrency, formatDateTime } from "@/lib/utils";
import type { FreeSaleReason, SaleItemRow, SaleRefundMethod, SaleRow, StockMovementRow } from "@/types/database";

const FREE_SALE_LABELS: Record<FreeSaleReason, string> = {
  GIFT: "Regalo",
  SAMPLE: "Muestra",
  EXCHANGE: "Canje",
  COURTESY: "Cortesía",
  OTHER: "Otro",
};

interface Props {
  sale: SaleRow;
  items: (SaleItemRow & { product?: { name: string; sku: string } })[];
  location: { code: string; name: string } | null;
  channel: { name: string } | null;
  seller: { full_name: string } | null;
  customer: { full_name: string; dni: string | null; whatsapp: string | null } | null;
  doctor: { full_name: string; commission_percent: string } | null;
  paymentMethod: { name: string } | null;
  paymentAccount: { name: string } | null;
  condition: { name: string } | null;
  cancelledByName?: string;
  movements: StockMovementRow[];
  canCancel: boolean;
  /** Cambios/Devoluciones: esta venta fue reemplazada por un cambio (status=replaced) -> la operación nueva. */
  replacedBy?: { id: string; sale_number: string } | null;
  /** Cambios/Devoluciones: esta venta ES la operación nueva de un cambio -> la venta que reemplaza. */
  replacesOriginal?: { id: string; sale_number: string } | null;
  /** Devolución de producto (sección 38 del pedido): NUNCA reemplaza/oculta la venta original — se lista aparte. */
  returns?: {
    id: string;
    refund_amount: string;
    refund_method: SaleRefundMethod;
    payment_account_name: string | null;
    notes: string | null;
    created_at: string;
    created_by_name: string | null;
    items: { product_name: string; quantity: string; unit_price_refunded: string; line_refund_total: string }[];
  }[];
}

export function SaleDetailView({
  sale,
  items,
  location,
  channel,
  seller,
  customer,
  doctor,
  paymentMethod,
  paymentAccount,
  condition,
  cancelledByName,
  movements,
  canCancel,
  replacedBy,
  replacesOriginal,
  returns = [],
}: Props) {
  return (
    <div className="mx-auto flex max-w-3xl flex-col gap-5 p-4 md:p-6">
      <div className="flex items-center justify-between">
        <Button variant="ghost" size="sm" asChild>
          <Link href="/ventas">
            <ArrowLeft className="size-4" /> Ventas
          </Link>
        </Button>
        {sale.status === "confirmed" && canCancel ? (
          <CancelSaleDialog saleId={sale.id} saleNumber={sale.sale_number} />
        ) : null}
      </div>

      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <h1 className="text-xl font-semibold">{sale.sale_number}</h1>
            {sale.status === "cancelled" ? (
              <Badge variant="destructive">Cancelada</Badge>
            ) : sale.status === "replaced" ? (
              <Badge variant="outline">Anulada / Reemplazada por cambio</Badge>
            ) : sale.status === "returned" ? (
              <Badge variant="outline">Devuelta en su totalidad</Badge>
            ) : (
              <Badge variant="success">Confirmada</Badge>
            )}
            {/* Una venta 'confirmed' con devoluciones parciales sigue siendo una
                venta válida (regla crítica, sección 19 del pedido) — este badge
                es solo informativo, nunca reemplaza el estado real. */}
            {sale.status === "confirmed" && returns.length > 0 ? (
              <Badge variant="secondary">Con devolución parcial</Badge>
            ) : null}
            {sale.is_free_sale ? <Badge variant="secondary">Sin costo · {FREE_SALE_LABELS[sale.free_sale_reason ?? "OTHER"]}</Badge> : null}
            {sale.stock_skipped ? <Badge variant="outline">Carga histórica · sin stock</Badge> : null}
          </div>
          <p className="text-sm text-muted-foreground">{formatDateTime(sale.sold_at)}</p>
        </div>
        <div className="text-right">
          <p className="text-3xl font-bold">{formatCurrency(sale.total)}</p>
          <p className="text-sm text-muted-foreground">
            {sale.is_free_sale ? `Valor entregado: ${formatCurrency(sale.subtotal)}` : paymentMethod?.name}
          </p>
        </div>
      </div>

      {sale.is_free_sale && sale.free_sale_notes ? (
        <p className="rounded-md bg-muted px-3 py-2 text-sm text-muted-foreground">
          {sale.free_sale_notes}
        </p>
      ) : null}

      {/* Cambios/Devoluciones — vínculo en las dos direcciones (sección 34 del
          pedido): nunca se edita la venta original, así que esto es la única
          forma de navegar entre las dos operaciones. */}
      {replacedBy ? (
        <div className="flex items-center justify-between gap-3 rounded-md border border-border bg-muted px-3 py-2 text-sm">
          <span>Esta venta fue reemplazada por un cambio de producto.</span>
          <Link href={`/ventas/${replacedBy.id}`} className="font-medium text-primary hover:underline">
            Ver operación nueva ({replacedBy.sale_number})
          </Link>
        </div>
      ) : null}
      {replacesOriginal ? (
        <div className="flex items-center justify-between gap-3 rounded-md border border-border bg-muted px-3 py-2 text-sm">
          <span>Esta operación se originó en un cambio de producto.</span>
          <Link href={`/ventas/${replacesOriginal.id}`} className="font-medium text-primary hover:underline">
            Ver venta original ({replacesOriginal.sale_number})
          </Link>
        </div>
      ) : null}

      {/* Precisión #6 (aprobada por el usuario): una devolución comercial
          NUNCA reabre ni modifica el comprobante fiscal ya emitido — eso es
          un proceso externo de nota de crédito, fuera de alcance de este
          módulo. Esta advertencia se muestra solo cuando ya hubo alguna
          devolución sobre una venta que además está facturada. */}
      {sale.billing_status === "INVOICED" && returns.length > 0 ? (
        <div className="flex items-start gap-2 rounded-md border border-amber-600/30 bg-amber-600/10 px-3 py-2 text-sm text-amber-800 dark:text-amber-400">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
          <span>
            Esta venta ya está facturada. La devolución comercial registrada abajo no modifica el comprobante
            fiscal original — si corresponde ajustarlo, hace falta una nota de crédito por fuera de este sistema.
          </span>
        </div>
      ) : null}

      <Card>
        <CardContent className="grid grid-cols-2 gap-4 p-5 text-sm sm:grid-cols-3">
          <Field label="Sucursal" value={location ? `${location.name} (${location.code})` : "—"} />
          <Field label="Canal" value={channel?.name ?? "—"} />
          <Field label="Vendedor/a" value={seller?.full_name ?? "—"} />
          <Field
            label="Cliente"
            value={customer ? `${customer.full_name}${customer.dni ? ` · DNI ${customer.dni}` : ""}` : "Sin identificar"}
          />
          <Field label="Doctora" value={doctor?.full_name ?? "Sin doctora"} />
          <Field label="Condición aplicada" value={condition?.name ?? "—"} />
          {/* Cuenta donde ingresó el dinero — distinto del medio de pago (ya
              se muestra arriba, junto al total). Una venta histórica sin
              cuenta asociada (ej. efectivo, o previa a este ajuste) muestra
              "No registrada", nunca se inventa retroactivamente. */}
          <Field label="Cuenta" value={paymentAccount?.name ?? "No registrada"} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Productos</CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col divide-y divide-border p-0 pb-2">
          {items.map((item) => (
            <div key={item.id} className="flex items-center justify-between gap-3 px-5 py-3">
              <div>
                <div className="flex items-center gap-1.5">
                  <p className="font-medium">{item.product?.name ?? item.product_id}</p>
                  {item.applied_promotion_id ? (
                    <Badge variant="secondary" className="font-normal">
                      Promo
                    </Badge>
                  ) : null}
                </div>
                <p className="text-xs text-muted-foreground">
                  {item.quantity} × {formatCurrency(item.sale_unit_price)}
                  {Number(item.line_discount) > 0 ? (
                    <span className="ml-1 line-through opacity-60">{formatCurrency(item.list_unit_price)}</span>
                  ) : null}
                  {item.commissionable ? null : (
                    <span className="ml-1 text-muted-foreground">· no comisionable</span>
                  )}
                </p>
              </div>
              <span className="font-semibold">{formatCurrency(item.line_total)}</span>
            </div>
          ))}
          <div className="flex flex-col gap-1 px-5 pt-3 text-sm">
            <div className="flex justify-between text-muted-foreground">
              <span>Subtotal lista</span>
              <span>{formatCurrency(sale.subtotal)}</span>
            </div>
            {Number(sale.discount_total) > 0 ? (
              <div className="flex justify-between text-muted-foreground">
                <span>Descuento</span>
                <span>-{formatCurrency(sale.discount_total)}</span>
              </div>
            ) : null}
            {Number(sale.surcharge_total) > 0 ? (
              // Una condición más cara que Lista (ej. cuotas) es un recargo
              // comercial válido — se muestra solo cuando aporta valor,
              // nunca junto al descuento (son complementarios).
              <div className="flex justify-between text-muted-foreground">
                <span>Recargo</span>
                <span className="text-destructive">+{formatCurrency(sale.surcharge_total)}</span>
              </div>
            ) : null}
            <Separator className="my-1" />
            <div className="flex justify-between text-base font-semibold">
              <span>Total</span>
              <span>{formatCurrency(sale.total)}</span>
            </div>
            {Number(sale.commission_total) > 0 ? (
              <div className="flex justify-between text-muted-foreground">
                <span>Comisión ({doctor?.full_name})</span>
                <span>{formatCurrency(sale.commission_total)}</span>
              </div>
            ) : null}
          </div>
        </CardContent>
      </Card>

      {returns.length > 0 ? (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Devoluciones</CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-4 p-5 pt-0">
            {returns.map((ret) => {
              const AccountIcon = ret.refund_method === "TRANSFER" ? Landmark : Banknote;
              return (
                <div key={ret.id} className="rounded-lg border border-border p-3">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <div className="flex items-center gap-1.5 text-sm font-medium">
                      <Undo2 className="size-4 text-muted-foreground" />
                      {formatDateTime(ret.created_at)}
                      {ret.created_by_name ? (
                        <span className="font-normal text-muted-foreground">· {ret.created_by_name}</span>
                      ) : null}
                    </div>
                    <span className="font-semibold text-destructive">-{formatCurrency(ret.refund_amount)}</span>
                  </div>
                  <p className="mt-1 flex items-center gap-1 text-xs text-muted-foreground">
                    <AccountIcon className="size-3" />
                    Reintegrado por {ret.refund_method === "TRANSFER" ? "transferencia" : "efectivo"}
                    {ret.payment_account_name ? ` · ${ret.payment_account_name}` : ""}
                  </p>
                  <div className="mt-2 flex flex-col gap-1 text-xs text-muted-foreground">
                    {ret.items.map((item, idx) => (
                      <div key={idx} className="flex justify-between">
                        <span>
                          {item.quantity} × {item.product_name} (a {formatCurrency(item.unit_price_refunded)})
                        </span>
                        <span>{formatCurrency(item.line_refund_total)}</span>
                      </div>
                    ))}
                  </div>
                  {ret.notes ? <p className="mt-2 text-xs text-muted-foreground">{ret.notes}</p> : null}
                </div>
              );
            })}
          </CardContent>
        </Card>
      ) : null}

      {sale.notes ? (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Observaciones</CardTitle>
          </CardHeader>
          <CardContent className="pt-0 text-sm text-muted-foreground">{sale.notes}</CardContent>
        </Card>
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Historial</CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 pt-0">
          <TimelineItem
            icon={CheckCircle2}
            title="Venta creada"
            detail={formatDateTime(sale.created_at)}
            tone="success"
          />
          {movements.length > 0 ? (
            <TimelineItem
              icon={PackageMinus}
              title={`Stock descontado (${movements.length} ${movements.length === 1 ? "movimiento" : "movimientos"})`}
              detail="Ver detalle en /stock/movimientos"
              tone="muted"
            />
          ) : null}
          {sale.status === "cancelled" ? (
            <TimelineItem
              icon={XCircle}
              title="Venta cancelada"
              detail={`${formatDateTime(sale.cancelled_at)}${cancelledByName ? ` · ${cancelledByName}` : ""}${
                sale.cancellation_reason ? ` · ${sale.cancellation_reason}` : ""
              }`}
              tone="destructive"
            />
          ) : null}
        </CardContent>
      </Card>
    </div>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className="font-medium">{value}</p>
    </div>
  );
}

function TimelineItem({
  icon: Icon,
  title,
  detail,
  tone,
}: {
  icon: React.ElementType;
  title: string;
  detail: string;
  tone: "success" | "muted" | "destructive";
}) {
  const toneClass =
    tone === "success" ? "bg-success/20 text-success" : tone === "destructive" ? "bg-destructive/10 text-destructive" : "bg-muted text-muted-foreground";
  return (
    <div className="flex items-start gap-3">
      <div className={`flex size-8 shrink-0 items-center justify-center rounded-full ${toneClass}`}>
        <Icon className="size-4" />
      </div>
      <div>
        <p className="text-sm font-medium">{title}</p>
        <p className="text-xs text-muted-foreground">{detail}</p>
      </div>
    </div>
  );
}
