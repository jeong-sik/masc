import { defineConfig } from 'vitest/config'
import preact from '@preact/preset-vite'

export default defineConfig({
  // Keep Vitest on the Preact transform pipeline. vite-plugin-solid has
  // global test-mode side effects that break existing Preact hook tests
  // (Preact hooks dispatcher gets clobbered → "Cannot read properties of
  // undefined (reading '__H')" during render) even when its transform
  // include filter is path-scoped to /\.solid\.tsx$/. Confirmed PR #6
  // 2026-04-30 with vite-plugin-solid 2.11.12 — same failure mode as
  // documented earlier.
  //
  // Instead, vitest-setup.ts substitutes KpiStripIsland with a
  // synchronous Preact shim so caller tests can keep asserting KpiCell
  // cell content immediately after render. The real island ships in
  // production and is exercised under vitest.solid.config.ts.
  plugins: [preact()],
  test: {
    environment: 'happy-dom',
    include: ['src/**/*.test.ts', 'design-system/**/*.test.ts'],
    exclude: [
      'design-system/headless-solid/**/*.test.ts',
      'src/**/*.solid.test.{ts,tsx}',
    ],
    globals: true,
    setupFiles: ['./vitest-setup.ts'],
  },
})
