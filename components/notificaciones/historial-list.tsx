import { Package, User } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader } from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { formatCurrency, formatDateTime } from "@/lib/utils";
import type { WebOrderHistoryRow } from "@/types/database";

const STATUS_LABEL: Record<WebOrderHistoryRow["display_status"], string> = {
  DELIVERED: "Entregado",
  SHIPPED: "Enviado",
  CANCELLED: "Anulado",
};

const STATUS_VARIANT: Record<WebOrderHistoryRow["display_status"], "success" | "secondary" | "destructive"> = {
  DELIVERED: "success",
  SHIPPED: "secondary",
  CANCELLED: "destructive",
};

/**
 * Lista de Historial (BLOQUE E). Sin "use client" — es puramente
 * presentacional (nada de estado ni handlers), las filas ya vienen
 * resueltas por web_order_history() vía el server component.
 */
export function HistorialList({ rows }: { rows: WebOrderHistoryRow[] }) {
  return (
    <div className="flex flex-col gap-3">
      {rows.map((row) => (
        <HistorialCard key={row.sale_id} row={row} />
      ))}
    </div>
  );
}

function HistorialCard({ row }: { row: WebOrderHistoryRow }) {
  const isShipping = row.fulfillment_type === "SHIPPING";

  return (
    <Card>
      <CardHeader className="flex-row items-start justify-between gap-3 space-y-0">
        <div>
          <p className="font-semibold">{row.sale_number}</p>
          <p className="text-sm text-muted-foreground">{formatDateTime(row.sold_at)}</p>
        </div>
        <div className="flex flex-col items-end gap-1">
          <Badge variant={STATUS_VARIANT[row.display_status]} className="font-normal">
            {STATUS_LABEL[row.display_status]}
          </Badge>
          <Badge variant={row.payment_status === "PENDING" ? "destructive" : "success"} className="font-normal">
            {row.payment_status === "PENDING" ? "PENDIENTE DE COBRO" : "PAGADO"}
          </Badge>
        </div>
      </CardHeader>

      <CardContent className="flex flex-col gap-3">
        <div className="flex items-start gap-2 text-sm">
          <User className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
          <div>
            <p className="font-medium">{row.customer_name ?? "Sin cliente"}</p>
            {row.customer_dni ? <p className="text-muted-foreground">DNI {row.customer_dni}</p> : null}
          </div>
        </div>

        <div className="flex items-start gap-2 text-sm">
          <Package className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
          <ul className="flex flex-col gap-0.5">
            {row.items.map((item, i) => (
              <li key={i}>
                {Number(item.quantity)}× {item.product_name}
                {item.is_kit ? <span className="text-muted-foreground"> (kit)</span> : null}
              </li>
            ))}
          </ul>
        </div>

        <Separator />

        <div className="grid grid-cols-2 gap-x-3 gap-y-1.5 text-sm">
          <span className="text-muted-foreground">Total</span>
          <span className="text-right font-semibold">{formatCurrency(row.total)}</span>
          <span className="text-muted-foreground">Forma de pago</span>
          <span className="text-right">{row.payment_method_name}</span>
          <span className="text-muted-foreground">Forma de entrega</span>
          <span className="text-right">{isShipping ? "Envío por correo" : "Retiro en sede"}</span>
          <span className="text-muted-foreground">{isShipping ? "Sale de" : "Retiro en"}</span>
          <span className="text-right">{row.location_name}</span>

          {/*
            SHIPPING nunca tiene delivered_at/delivered_by_name (no existe
            una fecha/actor de envío separados en el modelo — auditado en
            20260201000060, nunca inventado). El envío ocurre en el mismo
            instante en que se crea el pedido, así que acá se reusa sold_at
            (ya mostrado arriba como fecha de creación) en vez de fabricar
            un segundo timestamp idéntico.
          */}
          {isShipping ? (
            <>
              <span className="text-muted-foreground">Enviado</span>
              <span className="text-right">Al crear el pedido ({formatDateTime(row.sold_at)})</span>
            </>
          ) : row.delivered_at ? (
            <>
              <span className="text-muted-foreground">Entregado</span>
              <span className="text-right">{formatDateTime(row.delivered_at)}</span>
              <span className="text-muted-foreground">Entregó</span>
              <span className="text-right">{row.delivered_by_name}</span>
            </>
          ) : (
            <>
              <span className="text-muted-foreground">Entregado</span>
              <span className="text-right">No llegó a entregarse</span>
            </>
          )}

          <span className="text-muted-foreground">Cargada por</span>
          <span className="text-right">{row.seller_name}</span>
        </div>

        {row.display_status === "CANCELLED" ? (
          <>
            <Separator />
            <div className="text-sm text-destructive">
              <p className="font-medium">
                Anulado {formatDateTime(row.cancelled_at)} por {row.cancelled_by_name}
              </p>
              {row.cancellation_reason ? <p className="text-muted-foreground">{row.cancellation_reason}</p> : null}
            </div>
          </>
        ) : null}
      </CardContent>
    </Card>
  );
}
