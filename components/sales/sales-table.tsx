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

interface Row extends SaleRow {
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
  if (status === "draft") return <Badge variant="secondary">Borrador</Badge>;
  return <Badge variant="success">Confirmada</Badge>;
}
