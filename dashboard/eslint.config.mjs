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
)
