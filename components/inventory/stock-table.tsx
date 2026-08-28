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
  byLocation: Record<string, { quantity: number; status: "ok" | "bajo" | "sin_stock" }>;
  total: number;
  minStock: number;
  worstStatus: "ok" | "bajo" | "sin_stock";
}

const STATUS_RANK = { sin_stock: 2, bajo: 1, ok: 0 };

function pivot(rows: StockRow[]): PivotedProduct[] {
  const byProduct = new Map<string, PivotedProduct>();

  for (const row of rows) {
    let entry = byProduct.get(row.product_id);
    if (!entry) {
      entry = {
        product_id: row.product_id,
        sku: row.sku,
        name: row.name,
        category: row.category,
        byLocation: {},
        total: 0,
        minStock: Number(row.min_stock),
        worstStatus: "ok",
      };
      byProduct.set(row.product_id, entry);
    }
    const quantity = Number(row.quantity);
    entry.byLocation[row.location_code] = { quantity, status: row.status };
    entry.total += quantity;
    if (STATUS_RANK[row.status] > STATUS_RANK[entry.worstStatus]) entry.worstStatus = row.status;
  }

  return Array.from(byProduct.values()).sort((a, b) => a.name.localeCompare(b.name));
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
              <TableHead className="text-right">Mínimo</TableHead>
              <TableHead>Estado</TableHead>
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
                  <TableCell key={l.id} className="text-right tabular-nums">
                    {p.byLocation[l.code]?.quantity ?? "—"}
                  </TableCell>
                ))}
                <TableCell className="text-right font-medium tabular-nums">{p.total}</TableCell>
                <TableCell className="text-right tabular-nums text-muted-foreground">{p.minStock}</TableCell>
                <TableCell>
                  <StockStatusBadge status={p.worstStatus} />
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
              <StockStatusBadge status={p.worstStatus} />
            </div>
            <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-sm">
              {locations.map((l) => (
                <span key={l.id} className="text-muted-foreground">
                  {l.code}: <span className="font-medium text-foreground">{p.byLocation[l.code]?.quantity ?? "—"}</span>
                </span>
              ))}
              <span className="font-medium">Total: {p.total}</span>
            </div>
          </div>
        ))}
      </div>
    </>
  );
}
