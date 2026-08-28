interface KitRow {
  kit_product_id: string;
  kit_sku: string;
  kit_name: string;
  location_id: string;
  location_code: string;
  buildable_qty: number;
}
interface LocationOption {
  id: string;
  code: string;
  name: string;
}

export function KitAvailabilityList({ rows, locations }: { rows: KitRow[]; locations: LocationOption[] }) {
  const byKit = new Map<string, { name: string; sku: string; byLocation: Record<string, number> }>();

  for (const row of rows) {
    let entry = byKit.get(row.kit_product_id);
    if (!entry) {
      entry = { name: row.kit_name, sku: row.kit_sku, byLocation: {} };
      byKit.set(row.kit_product_id, entry);
    }
    entry.byLocation[row.location_code] = row.buildable_qty;
  }

  const kits = Array.from(byKit.values()).sort((a, b) => a.name.localeCompare(b.name));

  if (kits.length === 0) {
    return <p className="text-sm text-muted-foreground">No hay kits configurados.</p>;
  }

  return (
    <div className="flex flex-col divide-y divide-border">
      {kits.map((kit) => (
        <div key={kit.sku} className="flex items-center justify-between gap-3 py-2.5 text-sm">
          <div>
            <p className="font-medium">{kit.name}</p>
            <p className="text-xs text-muted-foreground">{kit.sku}</p>
          </div>
          <div className="flex gap-3 text-right">
            {locations.map((l) => (
              <div key={l.id}>
                <p className="text-xs text-muted-foreground">{l.code}</p>
                <p className="font-semibold tabular-nums">{kit.byLocation[l.code] ?? 0}</p>
              </div>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}
