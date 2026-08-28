import { defineConfig, devices } from "@playwright/test";

// Smoke tests E2E que NO requieren una base Supabase real (solo validan que las
// rutas públicas respondan y que proxy.ts proteja las rutas privadas). El flujo
// completo de venta (login real + Nueva Venta + confirmar) se prueba localmente
// contra `supabase start` — ver docs/architecture.md y README §Tests.
export default defineConfig({
  testDir: "./tests/e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: "list",
  use: {
    baseURL: "http://localhost:3100",
    trace: "on-first-retry",
  },
  projects: [
    {
      name: "chromium",
      use: {
        ...devices["Desktop Chrome"],
        // En sandboxes con navegador preinstalado (no el bundle default de
        // Playwright), forzar el binario evita "Executable doesn't exist".
        launchOptions: process.env.PLAYWRIGHT_CHROMIUM_PATH
          ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_PATH }
          : {},
      },
    },
  ],
  webServer: {
    command: "npm run build && npm run start -- -p 3100",
    url: "http://localhost:3100/login",
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
  },
});
