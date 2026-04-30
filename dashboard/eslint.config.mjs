import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import tseslint from 'typescript-eslint'

const TARGET_FILES = [
  'src/api/gate.ts',
  'src/api/transport-health.ts',
  'src/components/common/async-container.ts',
  'src/components/common/empty-state.ts',
  'src/components/common/feedback-state.ts',
  'src/components/common/markdown.ts',
  'src/components/connector-status.ts',
  'src/components/fleet-fsm-matrix.ts',
  'src/components/harness-health-state.ts',
  'src/components/harness-health.ts',
  'src/components/keeper-tool-call-inspector.ts',
  'src/components/keeper-tool-telemetry.ts',
  'src/components/logs.ts',
  'src/components/mission.ts',
  'src/components/runtime-monitor.ts',
  'src/components/transport-health.ts',
  'src/lib/async-state.ts',
  'src/components/common/normalize.ts',
]

const TEST_FILES = [
  'src/components/common/markdown.test.ts',
  'src/components/connector-status.test.ts',
  'src/components/fleet-fsm-matrix.test.ts',
  'src/components/keeper-tool-call-inspector.test.ts',
  'src/components/transport-health.test.ts',
  'src/lib/async-state.test.ts',
]

export default tseslint.config(
  {
    ignores: ['dist/**', 'coverage/**'],
  },
  {
    files: TARGET_FILES,
    languageOptions: {
      parser: tseslint.parser,
      globals: {
        ...globals.browser,
        ...globals.node,
      },
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    plugins: {
      '@typescript-eslint': tseslint.plugin,
      'react-hooks': reactHooks,
    },
    rules: {
      'no-nested-ternary': 'error',
      'react-hooks/rules-of-hooks': 'error',
      'react-hooks/exhaustive-deps': 'error',
      '@typescript-eslint/consistent-type-imports': 'error',
      '@typescript-eslint/no-floating-promises': 'error',
    },
  },
  {
    files: ['src/api/gate.ts', 'src/api/transport-health.ts', 'src/components/common/normalize.ts'],
    rules: {
      '@typescript-eslint/no-unsafe-assignment': 'error',
      '@typescript-eslint/no-unsafe-member-access': 'error',
    },
  },
  {
    files: TEST_FILES,
    languageOptions: {
      parser: tseslint.parser,
      globals: {
        ...globals.browser,
        ...globals.node,
      },
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    plugins: {
      '@typescript-eslint': tseslint.plugin,
    },
    rules: {
      '@typescript-eslint/consistent-type-imports': 'error',
      '@typescript-eslint/no-floating-promises': 'off',
      '@typescript-eslint/no-unsafe-assignment': 'off',
      '@typescript-eslint/no-unsafe-member-access': 'off',
    },
  },
  // RFC 0017 — KpiStrip island guard.
  //
  // Direct imports of `./kpi-strip` and `./kpi-cell` are reserved for the
  // wrapper itself and the test shim path. Production code must reach
  // them through `KpiStripIsland`. The guard exists because the
  // sustained-load measurement (RFC 0017 §7c, 2026-04-30) showed that
  // KpiStripIsland is roughly 2× slower than the Preact original at our
  // production scale (n≈16, ~30 ms `useEffect` overhead per island)
  // — adding more direct callers would *worsen* SSE back-pressure on
  // streaming dashboards, while adding more island callers also worsens
  // it. Until a synchronous-mount spike eliminates the `useEffect`
  // delay, neither path should grow without explicit owner sign-off.
  {
    // Scope intentionally narrow: only `src/components/**/*.ts(x)` reach
    // for KpiStrip / KpiCell. Restricting the block keeps unrelated
    // files (workers, lib helpers with their own react-hooks disable
    // comments) untouched by this guard's parser configuration.
    files: ['src/components/**/*.{ts,tsx}'],
    ignores: [
      // The originals themselves.
      'src/components/kpi-strip.ts',
      'src/components/kpi-cell.ts',
      // The Preact wrapper re-exports them and the Solid factory does
      // not import them.
      'src/components/kpi-strip-island.ts',
      'src/components/kpi-strip-island-solid.solid.tsx',
      // Caller tests register a `vi.doMock('./kpi-strip-island', ...)`
      // shim factory built from the original Preact KpiStrip + KpiCell.
      'src/components/*.test.ts',
      'src/components/*.test.tsx',
    ],
    languageOptions: {
      parser: tseslint.parser,
    },
    plugins: {
      '@typescript-eslint': tseslint.plugin,
      // Plugin loaded (rules off by default) so existing
      // `// eslint-disable-next-line react-hooks/exhaustive-deps`
      // comments in components/common/virtual-list.ts and
      // components/fsm-hub.ts (outside TARGET_FILES) don't surface as
      // "Definition for rule was not found".
      'react-hooks': reactHooks,
    },
    rules: {
      // `@typescript-eslint/no-restricted-imports` over the core rule
      // because we want `allowTypeImports` — the existing
      // `import type { KpiCellKind } from './kpi-cell'` in
      // `governance.ts` is harmless (no runtime), only runtime imports
      // need the guard.
      '@typescript-eslint/no-restricted-imports': ['error', {
        paths: [
          {
            name: './kpi-strip',
            message:
              'Use KpiStripIsland from ./kpi-strip-island instead. Direct KpiStrip imports are reserved for the wrapper and the test shim path. See RFC 0017 §7c — measurement (2026-04-30) showed island throughput is ~half of Preact at n=16, so do not assume migration is a perf win.',
            allowTypeImports: true,
          },
          {
            name: './kpi-cell',
            message:
              'Use KpiStripIsland from ./kpi-strip-island instead. Direct KpiCell imports are reserved for the wrapper and the test shim path. See RFC 0017 §7c.',
            allowTypeImports: true,
          },
        ],
      }],
    },
  },
)
