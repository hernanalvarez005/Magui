import type { Metadata } from "next";

import { LoginForm } from "@/components/auth/login-form";

export const metadata: Metadata = { title: "Ingresar" };

export default async function LoginPage(props: PageProps<"/login">) {
  const searchParams = await props.searchParams;
  const next = typeof searchParams.next === "string" ? searchParams.next : undefined;
  const deactivated = searchParams.error === "inactive";

  return (
    <div className="flex min-h-screen flex-1 items-center justify-center bg-secondary/40 px-4 py-10">
      <div className="w-full max-w-sm">
        <div className="mb-8 flex flex-col items-center gap-2 text-center">
          <div className="flex size-14 items-center justify-center rounded-2xl bg-primary text-2xl font-serif text-primary-foreground">
            M
          </div>
          <h1 className="text-xl font-semibold">Maguirejuve</h1>
          <p className="text-sm text-muted-foreground">Ventas, precios y stock</p>
        </div>

        <div className="rounded-2xl border border-border bg-card p-6 shadow-sm">
          {deactivated ? (
            <p className="mb-4 rounded-md bg-warning/20 px-3 py-2 text-sm text-warning-foreground">
              Tu usuario todavía no está activo. Pedile a un administrador que te habilite.
            </p>
          ) : null}
          <LoginForm next={next} />
        </div>
      </div>
    </div>
  );
}
