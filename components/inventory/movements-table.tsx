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
import { formatDateTime } from "@/lib/utils";
import { TYPE_LABELS } from "@/components/inventory/movement-filters";
import type { StockMovementRow } from "@/types/database";

// Solo los campos que esta tabla usa — la query en
// app/(app)/stock/movimientos/page.tsx pide exactamente estas 10 columnas
// de stock_movements, no select("*") (13 en total; transfer_id, notes y
// created_at quedan afuera). El export CSV sí sigue pidiendo todo.
type StockMovementListFields = Pick<
  StockMovementRow,
  | "id"
  | "occurred_at"
  | "location_id"
  | "product_id"
  | "movement_type"
  | "quantity_delta"
  | "sale_id"
  | "reference"
  | "reason"
  | "created_by"
>;

interface Row extends StockMovementListFields {
  product?: { name: string; sku: string };
  location?: { code: string; name: string };
  user?: { full_name: string };
  sale?: { sale_number: string };
}

const REASON_LABELS: Record<string, string> = {
  RECEPTION: "Recepción de mercadería",
  BREAKAGE: "Rotura",
  EXPIRATION: "Vencimiento",
  COUNT_DIFFERENCE: "Diferencia de conteo",
  RETURN: "Devolución",
  OTHER: "Otro",
};

export function MovementsTable({ rows }: { rows: Row[] }) {
  return (
    <>
      <div className="hidden overflow-hidden rounded-xl border border-border bg-card md:block">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Fecha</TableHead>
              <TableHead>Producto</TableHead>
              <TableHead>Sucursal</TableHead>
              <TableHead>Tipo</TableHead>
              <TableHead className="text-right">Cantidad</TableHead>
              <TableHead>Usuario</TableHead>
              <TableHead>Referencia</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <MovementRow key={row.id} row={row} />
            ))}
          </TableBody>
        </Table>
      </div>

      <div className="flex flex-col gap-2 md:hidden">
        {rows.map((row) => (
          <div key={row.id} className="rounded-xl border border-border bg-card p-3.5 text-sm">
            <div className="flex items-start justify-between gap-2">
              <div>
                <p className="font-medium">{row.product?.name ?? "—"}</p>
                <p className="text-xs text-muted-foreground">{formatDateTime(row.occurred_at)}</p>
              </div>
              <Delta value={Number(row.quantity_delta)} />
            </div>
            <div className="mt-2 flex flex-wrap items-center gap-1.5 text-xs text-muted-foreground">
              <Badge variant="outline">{TYPE_LABELS[row.movement_type] ?? row.movement_type}</Badge>
              <span>{row.location?.code}</span>
              {row.user ? <span>· {row.user.full_name}</span> : null}
            </div>
            <ReferenceLine row={row} />
          </div>
        ))}
      </div>
    </>
  );
}

function MovementRow({ row }: { row: Row }) {
  return (
    <TableRow>
      <TableCell className="text-xs text-muted-foreground">{formatDateTime(row.occurred_at)}</TableCell>
      <TableCell>
        <p className="font-medium">{row.product?.name ?? "—"}</p>
        <p className="text-xs text-muted-foreground">{row.product?.sku}</p>
      </TableCell>
      <TableCell>{row.location?.code}</TableCell>
      <TableCell>
        <Badge variant="outline">{TYPE_LABELS[row.movement_type] ?? row.movement_type}</Badge>
      </TableCell>
      <TableCell className="text-right">
        <Delta value={Number(row.quantity_delta)} />
      </TableCell>
      <TableCell className="text-xs text-muted-foreground">{row.user?.full_name ?? "Sistema"}</TableCell>
      <TableCell className="text-xs text-muted-foreground">
        <ReferenceLine row={row} />
      </TableCell>
    </TableRow>
  );
}

function Delta({ value }: { value: number }) {
  const positive = value > 0;
  return (
    <span className={positive ? "font-semibold text-success-foreground" : "font-semibold text-destructive"}>
      {positive ? "+" : ""}
      {value}
    </span>
  );
}

function ReferenceLine({ row }: { row: Row }) {
  if (row.sale) {
    return (
      <Link href={`/ventas/${row.sale_id}`} className="text-primary hover:underline">
        {row.sale.sale_number}
      </Link>
    );
  }
  if (row.reason) return <span>{REASON_LABELS[row.reason] ?? row.reason}</span>;
  if (row.reference) return <span>{row.reference}</span>;
  return <span>—</span>;
}
