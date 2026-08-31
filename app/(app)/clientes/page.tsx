import type { Metadata } from "next";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { EmptyState } from "@/components/shared/empty-state";
import { CustomersView } from "@/components/customers/customers-view";

export const metadata: Metadata = { title: "Clientes" };

export default async function CustomersPage(props: PageProps<"/clientes">) {
  const searchParams = await props.searchParams;
  const q = typeof searchParams.q === "string" ? searchParams.q : undefined;
  const showInactive = searchParams.inactive === "1";
  const profile = await getCurrentProfile();

  const supabase = await createClient();
  let query = supabase
    .from("customers")
    .select("id, full_name, dni, whatsapp, email, active, notes, created_at")
    .order("full_name")
    .limit(200);

  if (!showInactive) query = query.eq("active", true);
  if (q) {
    query = query.or(`full_name.ilike.%${q}%,dni.ilike.%${q}%,whatsapp.ilike.%${q}%`);
  }

  const { data: customers } = await query;

  return (
    <div className="flex flex-col gap-5 p-4 md:p-6">
      <div>
        <h1 className="text-xl font-semibold">Clientes</h1>
        <p className="text-sm text-muted-foreground">Buscá por nombre, DNI o WhatsApp.</p>
      </div>

      <CustomersView
        initialCustomers={customers ?? []}
        initialQuery={q ?? ""}
        showInactive={showInactive}
        isAdmin={profile.role === "admin"}
        canWrite={profile.role !== "viewer"}
      />

      {(!customers || customers.length === 0) && q ? (
        <EmptyState title="No encontramos clientes que coincidan con tu búsqueda." />
      ) : null}
    </div>
  );
}
