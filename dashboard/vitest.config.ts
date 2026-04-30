import { defineConfig } from 'vitest/config'
import preact from '@preact/preset-vite'
import solid from 'vite-plugin-solid'

export default defineConfig({
  plugins: [
    // SolidJS plugin must run before Preact's so it claims its files
    // first. `include` restricts the JSX transform to PoC paths so
    // non-Solid Preact tests are unaffected. Mirrors vite.config.ts.
    solid({
      include: [
        /design-system\/headless-solid\//,
        /design-system\/preview\/solid-.*/,
      ],
    }),
    preact(),
  ],
  test: {
    environment: 'happy-dom',
    include: ['src/**/*.test.ts', 'design-system/**/*.test.ts'],
    globals: true,
    setupFiles: ['./vitest-setup.ts'],
  },
})
