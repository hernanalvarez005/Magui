import { redirect } from "next/navigation";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { AdminTabs } from "@/components/admin/admin-tabs";

export default async function AdminLayout({ children }: LayoutProps<"/admin">) {
  const profile = await getCurrentProfile();
  if (profile.role !== "admin") {
    redirect("/");
  }

  return (
    <div className="flex flex-col gap-5 p-4 md:p-6">
      <div>
        <h1 className="text-xl font-semibold">Administración</h1>
        <p className="text-sm text-muted-foreground">Precios, promociones, doctoras y usuarios.</p>
      </div>
      <AdminTabs />
      {children}
    </div>
  );
}
