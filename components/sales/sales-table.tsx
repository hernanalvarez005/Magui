import Link from "next/link";

import { Badge } from "@/components/ui/badge";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { formatCurrency, formatDateTime } from "@/lib/utils";
import type { SaleRow } from "@/types/database";

// Solo los campos que esta tabla (y el mapeo de page.tsx) realmente usa —
// la query en app/(app)/ventas/page.tsx pide exactamente estas columnas de
// `sales`, no select("*"). El tipo completo (SaleRow, 28 columnas) sigue
// siendo correcto para el detalle de una venta puntual.
type SaleListFields = Pick<
  SaleRow,
  | "id"
  | "sale_number"
  | "sold_at"
  | "location_id"
  | "sales_channel_id"
  | "seller_id"
  | "customer_id"
  | "doctor_id"
  | "payment_method_id"
  | "total"
  | "commission_total"
  | "status"
  | "is_free_sale"
  | "stock_skipped"
>;

interface Row extends SaleListFields {
  location?: { code: string; name: string };
  channel?: { name: string };
  seller?: { full_name: string };
  customer?: { full_name: string };
  doctor?: { full_name: string };
  paymentMethod?: { name: string };
}

export function SalesTable({ rows }: { rows: Row[] }) {
  return (
    <>
      <div className="hidden overflow-hidden rounded-xl border border-border bg-card lg:block">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Nº venta</TableHead>
              <TableHead>Fecha</TableHead>
              <TableHead>Sucursal</TableHead>
              <TableHead>Canal</TableHead>
              <TableHead>Vendedor/a</TableHead>
              <TableHead>Cliente</TableHead>
              <TableHead>Medio de pago</TableHead>
              <TableHead className="text-right">Total</TableHead>
              <TableHead>Doctora</TableHead>
              <TableHead className="text-right">Comisión</TableHead>
              <TableHead>Estado</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((sale) => (
              <TableRow key={sale.id} className="cursor-pointer">
                <TableCell className="font-medium">
                  <Link href={`/ventas/${sale.id}`} className="hover:underline">
                    {sale.sale_number}
                  </Link>
                </TableCell>
                <TableCell className="text-xs text-muted-foreground">{formatDateTime(sale.sold_at)}</TableCell>
                <TableCell>{sale.location?.code}</TableCell>
                <TableCell>{sale.channel?.name}</TableCell>
                <TableCell>{sale.seller?.full_name}</TableCell>
                <TableCell>{sale.customer?.full_name ?? "—"}</TableCell>
                <TableCell>{sale.paymentMethod?.name}</TableCell>
                <TableCell className="text-right font-medium">{formatCurrency(sale.total)}</TableCell>
                <TableCell>{sale.doctor?.full_name ?? "—"}</TableCell>
                <TableCell className="text-right">{formatCurrency(sale.commission_total)}</TableCell>
                <TableCell>
                  <div className="flex flex-wrap gap-1">
                    <SaleStatusBadge status={sale.status} />
                    {sale.is_free_sale ? <Badge variant="secondary">Sin costo</Badge> : null}
                    {sale.stock_skipped ? <Badge variant="outline">Sin stock</Badge> : null}
                  </div>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>

      <div className="flex flex-col gap-2 lg:hidden">
        {rows.map((sale) => (
          <Link
            key={sale.id}
            href={`/ventas/${sale.id}`}
            className="flex flex-col gap-1.5 rounded-xl border border-border bg-card p-3.5"
          >
            <div className="flex items-start justify-between">
              <div>
                <p className="font-medium">{sale.sale_number}</p>
                <p className="text-xs text-muted-foreground">{formatDateTime(sale.sold_at)}</p>
              </div>
              <SaleStatusBadge status={sale.status} />
            </div>
            <div className="flex items-center justify-between text-sm">
              <span className="text-muted-foreground">
                {sale.location?.code} · {sale.paymentMethod?.name}
              </span>
              <span className="font-semibold">{formatCurrency(sale.total)}</span>
            </div>
          </Link>
        ))}
      </div>
    </>
  );
}

function SaleStatusBadge({ status }: { status: SaleRow["status"] }) {
  if (status === "cancelled") return <Badge variant="destructive">Cancelada</Badge>;
  // Reemplazada por un cambio de producto — nunca "Confirmada" (no cuenta en
  // ninguna métrica activa, y no es ni un borrador ni una anulación).
  if (status === "replaced") return <Badge variant="outline">Reemplazada</Badge>;
  if (status === "draft") return <Badge variant="secondary">Borrador</Badge>;
  return <Badge variant="success">Confirmada</Badge>;
}
