import { defineConfig } from 'vitest/config'
import preact from '@preact/preset-vite'

export default defineConfig({
  // Preact transform pipeline. The dashboard was unified on Preact in #66:
  // the former Solid KPI island, its *.solid mirror components, the
  // headless-solid experiment, and the separate vitest.solid.config.ts were
  // all removed, so there is no longer a second transform to exclude.
  plugins: [preact()],
  test: {
    environment: 'happy-dom',
    include: ['src/**/*.test.ts', 'design-system/**/*.test.ts'],
    globals: true,
    setupFiles: ['./vitest-setup.ts'],
  },
})
