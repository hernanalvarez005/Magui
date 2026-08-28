import Link from "next/link";
import { ArrowLeft, CheckCircle2, PackageMinus, XCircle } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { CancelSaleDialog } from "@/components/sales/cancel-sale-dialog";
import { formatCurrency, formatDateTime } from "@/lib/utils";
import type { FreeSaleReason, SaleItemRow, SaleRow, StockMovementRow } from "@/types/database";

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
  condition: { name: string } | null;
  cancelledByName?: string;
  movements: StockMovementRow[];
  canCancel: boolean;
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
  condition,
  cancelledByName,
  movements,
  canCancel,
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
            ) : (
              <Badge variant="success">Confirmada</Badge>
            )}
            {sale.is_free_sale ? <Badge variant="secondary">Sin costo · {FREE_SALE_LABELS[sale.free_sale_reason ?? "OTHER"]}</Badge> : null}
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
                <p className="font-medium">{item.product?.name ?? item.product_id}</p>
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
            <div className="flex justify-between text-muted-foreground">
              <span>Descuento</span>
              <span>-{formatCurrency(sale.discount_total)}</span>
            </div>
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
