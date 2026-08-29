"use client";

// Última red de contención: cubre un error que rompe el root layout mismo
// (donde app/error.tsx no llega — ver docs/file-conventions/error.md).
// Reemplaza <html>/<body> enteros mientras está activo, así que no puede
// depender de globals.css ni de los componentes de ui/ (podrían ser
// justamente lo que falló) — todo en estilos inline, deliberadamente.
export default function GlobalError({
  retry,
}: {
  error: Error & { digest?: string };
  retry: () => void;
}) {
  return (
    <html lang="es-AR">
      <body
        style={{
          margin: 0,
          minHeight: "100vh",
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          gap: 16,
          padding: 24,
          fontFamily: "system-ui, -apple-system, sans-serif",
          textAlign: "center",
          background: "#faf8f6",
          color: "#1a1a1a",
        }}
      >
        <h1 style={{ fontSize: 18, fontWeight: 600, margin: 0 }}>Algo salió mal</h1>
        <p style={{ fontSize: 14, color: "#6b6b6b", maxWidth: 360, margin: 0 }}>
          Recargá la página. Si el problema sigue, avisale al equipo.
        </p>
        <div style={{ display: "flex", gap: 8 }}>
          <button
            onClick={() => window.location.reload()}
            style={{
              padding: "10px 16px",
              borderRadius: 8,
              border: "1px solid #d4d0cb",
              background: "white",
              cursor: "pointer",
              fontSize: 14,
            }}
          >
            Recargar página
          </button>
          <button
            onClick={() => retry()}
            style={{
              padding: "10px 16px",
              borderRadius: 8,
              border: "none",
              background: "#1a1a1a",
              color: "white",
              cursor: "pointer",
              fontSize: 14,
            }}
          >
            Reintentar
          </button>
        </div>
      </body>
    </html>
  );
}
