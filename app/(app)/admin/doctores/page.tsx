import type { Metadata } from "next";

import { createClient } from "@/lib/supabase/server";
import { DoctorsTable } from "@/components/admin/doctors-table";

export const metadata: Metadata = { title: "Doctoras" };

export default async function AdminDoctorsPage() {
  const supabase = await createClient();
  const { data: doctors } = await supabase
    .from("doctors")
    .select("id, code, full_name, commission_percent, active")
    .order("full_name");

  return <DoctorsTable doctors={doctors ?? []} />;
}
