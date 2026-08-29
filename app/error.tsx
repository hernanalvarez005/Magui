"use client";

import { useEffect } from "react";
import { AlertTriangle, RotateCcw } from "lucide-react";

import { Button } from "@/components/ui/button";

// Red de contención para cualquier error de renderizado del lado del
// cliente que no se haya manejado puntualmente (ver useActionState en los
// formularios, que sí modela sus propios errores esperados). Sin este
// archivo, un error acá terminaba en una pantalla en blanco o "colgada" —
// sin ningún mensaje ni forma de recuperarse sin cerrar y volver a abrir la
// app. Un caso real que puede disparar esto: recargar el navegador cambia
// la versión desplegada mientras una pantalla (ej. el login) sigue abierta
// con la versión anterior — Next.js rota las referencias de los Server
// Actions en cada deploy, así que una acción vieja ya no existe en el
// servidor nuevo. "Recargar página" siempre soluciona ese caso puntual.
export default function ErrorPage({
  error,
  retry,
}: {
  error: Error & { digest?: string };
  retry: () => void;
}) {
  useEffect(() => {
    console.error(error);
  }, [error]);

  return (
    <div className="flex min-h-screen flex-1 flex-col items-center justify-center gap-4 bg-secondary/40 px-4 py-10 text-center">
      <div className="flex size-14 items-center justify-center rounded-full bg-destructive/10">
        <AlertTriangle className="size-7 text-destructive" />
      </div>
      <div>
        <h1 className="text-lg font-semibold">Algo salió mal</h1>
        <p className="mt-1 max-w-sm text-sm text-muted-foreground">
          Puede ser algo pasajero. Si el sistema se actualizó mientras tenías esta pantalla abierta,
          recargar la página lo soluciona.
        </p>
      </div>
      <div className="flex gap-2">
        <Button variant="outline" onClick={() => window.location.reload()}>
          Recargar página
        </Button>
        <Button onClick={() => retry()}>
          <RotateCcw /> Reintentar
        </Button>
      </div>
    </div>
  );
}
