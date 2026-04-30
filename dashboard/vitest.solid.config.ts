import { defineConfig } from 'vitest/config'
import solid from 'vite-plugin-solid'

export default defineConfig({
  plugins: [
    solid({
      include: [
        'design-system/headless-solid/**/*.{ts,tsx}',
        'src/components/**/*.solid.{ts,tsx}',
        'src/components/**/*.solid.test.{ts,tsx}',
      ],
    }),
  ],
  test: {
    environment: 'happy-dom',
    include: [
      'design-system/headless-solid/**/*.test.ts',
      'src/components/**/*.solid.test.{ts,tsx}',
    ],
    globals: true,
  },
})
