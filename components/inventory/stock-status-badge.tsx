import { Badge } from "@/components/ui/badge";

export function StockStatusBadge({ status }: { status: "ok" | "bajo" | "sin_stock" }) {
  if (status === "sin_stock") return <Badge variant="destructive">Sin stock</Badge>;
  if (status === "bajo") return <Badge variant="warning">Stock bajo</Badge>;
  return <Badge variant="secondary">OK</Badge>;
}
