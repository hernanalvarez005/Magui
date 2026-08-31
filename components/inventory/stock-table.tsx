import { cn } from "@/lib/utils";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { StockStatusBadge } from "@/components/inventory/stock-status-badge";

interface StockRow {
  product_id: string;
  sku: string;
  name: string;
  category: string | null;
  location_id: string;
  location_code: string;
  quantity: string;
  min_stock: string;
  status: "ok" | "bajo" | "sin_stock";
}

interface LocationOption {
  id: string;
  code: string;
  name: string;
}

interface PivotedProduct {
  product_id: string;
  sku: string;
  name: string;
  category: string | null;
  byLocation: Record<string, { quantity: number; minStock: number; status: "ok" | "bajo" | "sin_stock" }>;
  total: number;
}

function pivot(rows: StockRow[]): PivotedProduct[] {
  const byProduct = new Map<string, PivotedProduct>();

  for (const row of rows) {
    let entry = byProduct.get(row.product_id);
    if (!entry) {
      entry = { product_id: row.product_id, sku: row.sku, name: row.name, category: row.category, byLocation: {}, total: 0 };
      byProduct.set(row.product_id, entry);
    }
    const quantity = Number(row.quantity);
    entry.byLocation[row.location_code] = { quantity, minStock: Number(row.min_stock), status: row.status };
    entry.total += quantity;
  }

  return Array.from(byProduct.values()).sort((a, b) => a.name.localeCompare(b.name));
}

// El estado es SIEMPRE por sede — nunca un "peor caso" agregado entre
// sucursales. Un producto bajo en Depósito pero sobrado en Sede 25 muestra
// eso mismo: Depósito bajo, Sede 25 OK. Mezclarlos en un único badge
// (comportamiento anterior) hacía ver "Bajo" un producto con stock de sobra
// en la sede que realmente importa.
const STATUS_TEXT_CLASS: Record<StockRow["status"], string> = {
  ok: "text-foreground",
  bajo: "text-warning-foreground",
  sin_stock: "text-destructive",
};

function LocationCell({ cell }: { cell: { quantity: number; minStock: number; status: StockRow["status"] } | undefined }) {
  if (!cell) return <span className="text-muted-foreground">—</span>;
  return (
    <span
      className={cn("tabular-nums", STATUS_TEXT_CLASS[cell.status])}
      title={`Mínimo en esta sede: ${cell.minStock}`}
    >
      {cell.quantity}
      {cell.status !== "ok" ? (
        <span
          aria-hidden
          className={cn(
            "ml-1 inline-block size-1.5 rounded-full align-middle",
            cell.status === "sin_stock" ? "bg-destructive" : "bg-warning"
          )}
        />
      ) : null}
    </span>
  );
}

/** Chips de las sedes que NO están OK — reemplaza el badge único "peor caso". */
function AlertChips({ byLocation }: { byLocation: PivotedProduct["byLocation"] }) {
  const alerts = Object.entries(byLocation).filter(([, v]) => v.status !== "ok");
  if (alerts.length === 0) return <StockStatusBadge status="ok" />;
  return (
    <div className="flex flex-wrap gap-1">
      {alerts.map(([code, v]) => (
        <span
          key={code}
          className={cn(
            "inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs font-medium",
            v.status === "sin_stock"
              ? "border-transparent bg-destructive text-destructive-foreground"
              : "border-transparent bg-warning text-warning-foreground"
          )}
        >
          {code}: {v.status === "sin_stock" ? "sin stock" : "bajo"}
        </span>
      ))}
    </div>
  );
}

export function StockTable({ rows, locations }: { rows: StockRow[]; locations: LocationOption[] }) {
  const products = pivot(rows);

  return (
    <>
      {/* Desktop: tabla */}
      <div className="hidden rounded-xl border border-border bg-card md:block">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Producto</TableHead>
              {locations.map((l) => (
                <TableHead key={l.id} className="text-right">
                  {l.code}
                </TableHead>
              ))}
              <TableHead className="text-right">Total</TableHead>
              <TableHead>Estado por sede</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {products.map((p) => (
              <TableRow key={p.product_id}>
                <TableCell>
                  <p className="font-medium">{p.name}</p>
                  <p className="text-xs text-muted-foreground">{p.sku}</p>
                </TableCell>
                {locations.map((l) => (
                  <TableCell key={l.id} className="text-right">
                    <LocationCell cell={p.byLocation[l.code]} />
                  </TableCell>
                ))}
                <TableCell className="text-right font-medium tabular-nums">{p.total}</TableCell>
                <TableCell>
                  <AlertChips byLocation={p.byLocation} />
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>

      {/* Mobile: cards */}
      <div className="flex flex-col gap-2 md:hidden">
        {products.map((p) => (
          <div key={p.product_id} className="rounded-xl border border-border bg-card p-3.5">
            <div className="flex items-start justify-between gap-2">
              <div>
                <p className="font-medium">{p.name}</p>
                <p className="text-xs text-muted-foreground">{p.sku}</p>
              </div>
              <span className="font-medium">Total: {p.total}</span>
            </div>
            <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-sm">
              {locations.map((l) => (
                <span key={l.id} className="text-muted-foreground">
                  {l.code}: <LocationCell cell={p.byLocation[l.code]} />
                </span>
              ))}
            </div>
            <div className="mt-2">
              <AlertChips byLocation={p.byLocation} />
            </div>
          </div>
        ))}
      </div>
    </>
  );
}
