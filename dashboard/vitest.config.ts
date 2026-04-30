import { defineConfig } from 'vitest/config'
import preact from '@preact/preset-vite'

export default defineConfig({
  // Keep Vitest on the Preact transform pipeline. vite-plugin-solid has
  // global test-mode side effects that break existing Preact hook tests even
  // when its transform include filter is path-scoped. Solid tests run through
  // vitest.solid.config.ts so their resolver/runtime conditions stay isolated.
  plugins: [preact()],
  test: {
    environment: 'happy-dom',
    include: ['src/**/*.test.ts', 'design-system/**/*.test.ts'],
    exclude: ['design-system/headless-solid/**/*.test.ts'],
    globals: true,
    setupFiles: ['./vitest-setup.ts'],
  },
})
