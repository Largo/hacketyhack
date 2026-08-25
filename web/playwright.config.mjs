import { defineConfig, devices } from "@playwright/test";

// The dev server is started for the run unless one is already listening, and
// the Ruby bundle is rebuilt first so a test never runs against stale code.
export default defineConfig({
  testDir: "./tests",
  // Booting a 32 MB CRuby and 5 MB of Hackety Hack takes a few seconds.
  timeout: 180_000,
  expect: { timeout: 15_000 },
  fullyParallel: true,
  workers: process.env.CI ? 2 : undefined,
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : [["list"]],
  use: {
    baseURL: process.env.CLOGS_BASE_URL || "http://localhost:4173",
    viewport: { width: 1100, height: 760 },
    // Screenshots of a canvas are only useful if the canvas is not scaled.
    deviceScaleFactor: 1,
    trace: "retain-on-failure",
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  webServer: {
    command: "node build.mjs && node serve.mjs 4173",
    url: "http://localhost:4173/",
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
    stdout: "pipe",
  },
});
