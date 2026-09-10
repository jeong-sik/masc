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
    // vitest's default is 5000, which nobody chose for this suite. The full
    // parallel run spends most of its time standing up per-file environments:
    // measured 2026-09-10 over three runs, wall clock 164-183s against an
    // environment sum of 720-853s across workers. A test whose own work is
    // milliseconds can therefore wait seconds for its worker, and the default
    // deadline counts that wait. Five of seven failures in one such run were
    // "timed out in 5000ms" in five different files, and the files change from
    // run to run, so the deadline is the bound being hit rather than any one
    // test being slow (#35032).
    //
    // 20s is four times the observed need and still bounds a genuine hang at
    // one-sixth of the suite's wall clock.
    testTimeout: 20_000,
  },
})
