import { defineConfig } from 'vitest/config'
import preact from '@preact/preset-vite'

export default defineConfig({
  plugins: [preact()],
  test: {
    environment: 'happy-dom',
    include: ['src/**/*.test.ts', 'design-system/**/*.test.ts'],
    exclude: ['design-system/headless-solid/**/*.test.ts'],
    globals: true,
    setupFiles: ['./vitest-setup.ts'],
  },
})
