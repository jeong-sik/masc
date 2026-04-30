import { defineConfig } from 'vitest/config'
import solid from 'vite-plugin-solid'

export default defineConfig({
  plugins: [
    solid({
      include: ['design-system/headless-solid/**/*.{ts,tsx}'],
    }),
  ],
  test: {
    environment: 'happy-dom',
    include: ['design-system/headless-solid/**/*.test.ts'],
    globals: true,
  },
})
