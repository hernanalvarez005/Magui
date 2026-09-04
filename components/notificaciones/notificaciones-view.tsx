"use client";

import Link from "next/link";
import { Bell, History, Package, User } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader } from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { EmptyState } from "@/components/shared/empty-state";
import { DeliverPickupDialog } from "@/components/notificaciones/deliver-pickup-dialog";
import { MarkPaidAndDeliverDialog } from "@/components/notificaciones/mark-paid-and-deliver-dialog";
import { formatCurrency, formatDateTime } from "@/lib/utils";
import type { WebPendingPickupRow } from "@/types/database";

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

/**
 * Bandeja de Notificaciones (BLOQUE D del circuito Ventas Web). Cada fila
 * viene ya resuelta por web_pending_pickups() — nada de esto vuelve a
 * decidir visibilidad por sede/rol, eso ya pasó en el backend. Las acciones
 * (cobrar+entregar / marcar entregado) llaman ÚNICAMENTE a
 * mark_web_order_paid / deliver_web_pickup — ninguna lógica de stock acá.
 */
export function NotificacionesView({
  pickups,
  paymentMethods,
  paymentAccounts,
  canAct,
}: {
  pickups: WebPendingPickupRow[];
  paymentMethods: PaymentMethodOption[];
  paymentAccounts: PaymentAccountOption[];
  canAct: boolean;
}) {
  return (
    <div className="mx-auto flex max-w-3xl flex-col gap-4 p-4 md:p-6">
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <Bell className="size-5 text-muted-foreground" />
          <h1 className="text-lg font-semibold">Notificaciones</h1>
          {pickups.length > 0 ? <Badge variant="secondary">{pickups.length} pendientes de retiro</Badge> : null}
        </div>
        <Button variant="outline" size="sm" asChild>
          <Link href="/notificaciones/historial">
            <History /> Historial
          </Link>
        </Button>
      </div>

      {pickups.length === 0 ? (
        <EmptyState
          icon={Bell}
          title="No hay pedidos Web pendientes de retiro"
          description="Los pedidos Web con retiro en sede van a aparecer acá hasta que se entreguen."
        />
      ) : (
        <div className="flex flex-col gap-3">
          {pickups.map((pickup) => (
            <PendingPickupCard
              key={pickup.sale_id}
              pickup={pickup}
              paymentMethods={paymentMethods}
              paymentAccounts={paymentAccounts}
              canAct={canAct}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function PendingPickupCard({
  pickup,
  paymentMethods,
  paymentAccounts,
  canAct,
}: {
  pickup: WebPendingPickupRow;
  paymentMethods: PaymentMethodOption[];
  paymentAccounts: PaymentAccountOption[];
  canAct: boolean;
}) {
  const isPaid = pickup.payment_status === "PAID";

  return (
    <Card>
      <CardHeader className="flex-row items-start justify-between gap-3 space-y-0">
        <div>
          <p className="font-semibold">{pickup.sale_number}</p>
          <p className="text-sm text-muted-foreground">{formatDateTime(pickup.sold_at)}</p>
        </div>
        <Badge variant={isPaid ? "success" : "destructive"} className="font-normal">
          {isPaid ? "PAGADO" : "PENDIENTE DE COBRO"}
        </Badge>
      </CardHeader>

      <CardContent className="flex flex-col gap-3">
        <div className="flex items-start gap-2 text-sm">
          <User className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
          <div>
            <p className="font-medium">{pickup.customer_name ?? "Sin cliente"}</p>
            {pickup.customer_dni ? <p className="text-muted-foreground">DNI {pickup.customer_dni}</p> : null}
          </div>
        </div>

        <div className="flex items-start gap-2 text-sm">
          <Package className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
          <ul className="flex flex-col gap-0.5">
            {pickup.items.map((item, i) => (
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
          <span className="text-right font-semibold">{formatCurrency(pickup.total)}</span>
          <span className="text-muted-foreground">Forma de pago</span>
          <span className="text-right">{pickup.payment_method_name}</span>
          <span className="text-muted-foreground">Retiro en</span>
          <span className="text-right">{pickup.pickup_location_name}</span>
          <span className="text-muted-foreground">Cargada por</span>
          <span className="text-right">{pickup.seller_name}</span>
        </div>

        {canAct ? (
          <div className="pt-1">
            {isPaid ? (
              <DeliverPickupDialog saleId={pickup.sale_id} saleNumber={pickup.sale_number} />
            ) : (
              <MarkPaidAndDeliverDialog
                saleId={pickup.sale_id}
                saleNumber={pickup.sale_number}
                currentPaymentMethodId={pickup.payment_method_id}
                currentPaymentAccountId={pickup.payment_account_id}
                paymentMethods={paymentMethods}
                paymentAccounts={paymentAccounts}
              />
            )}
          </div>
        ) : null}
      </CardContent>
    </Card>
  );
}
