import { defineConfig } from 'vitest/config'
import preact from '@preact/preset-vite'

export default defineConfig({
  // The dashboard has one UI runtime and one test transform pipeline.
  plugins: [preact()],
  test: {
    environment: 'happy-dom',
    include: ['src/**/*.test.ts', 'design-system/**/*.test.ts'],
    globals: true,
    setupFiles: ['./vitest-setup.ts'],
  },
})
