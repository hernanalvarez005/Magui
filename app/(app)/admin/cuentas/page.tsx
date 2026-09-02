import type { Metadata } from "next";

import { createClient } from "@/lib/supabase/server";
import { AccountsTable } from "@/components/admin/accounts-table";

export const metadata: Metadata = { title: "Bancos / Cuentas" };

export default async function AdminAccountsPage() {
  const supabase = await createClient();

  const { data: accounts } = await supabase
    .from("payment_accounts")
    .select("id, code, name, alias, active, sort_order")
    .order("sort_order")
    .order("name");

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-muted-foreground">
        Cuentas donde ingresa el dinero de una venta (Mercado Pago, Banco Galicia, etc.) — distinto de
        la forma de pago. El alias configurado acá aparece automáticamente en Nueva Venta cuando se
        elige Transferencia. Desactivar una cuenta la saca de Nueva Venta pero conserva su relación con
        las ventas ya confirmadas.
      </p>
      <AccountsTable accounts={accounts ?? []} />
    </div>
  );
}
