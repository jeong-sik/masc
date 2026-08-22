import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import tseslint from 'typescript-eslint'

const TARGET_FILES = [
  'design-system/headless-preact/use-inline-suggestion.ts',
  'design-system/headless-preact/use-collaboration.ts',
  'src/api/dashboard-runtime.ts',
  'src/api/dashboard.ts',
  'src/api/effect-http.ts',
  'src/api/feature-health.ts',
  'src/api/gate.ts',
  'src/api/goal-loop.ts',
  'src/api/schemas/runtime.ts',
  'src/api/schemas/dashboard-config.ts',
  'src/api/schemas/feature-health.ts',
  'src/api/schemas/transport-health.ts',
  'src/api/transport-health.ts',
  'src/components/common/async-container.ts',
  'src/components/common/empty-state.ts',
  'src/components/common/feedback-state.ts',
  'src/components/common/markdown.ts',
  'src/components/connector-status.ts',
  'src/components/fleet-fsm-matrix.ts',
  'src/components/feature-health.ts',
  'src/components/goal-loop-panel.ts',
  'src/components/harness-health-state.ts',
  'src/components/harness-health.ts',
  'src/components/journey-panel.ts',
  'src/components/journey-waterfall-state.ts',
  'src/components/keeper-detail-body.ts',
  'src/components/keeper-sse-match.ts',
  'src/components/keeper-turn-inspector.ts',
  'src/components/keeper-tool-call-inspector.ts',
  'src/components/keeper-tool-telemetry.ts',
  'src/components/logs.ts',
  'src/components/mission.ts',
  'src/components/runtime-monitor.ts',
  'src/components/session-trace/session-trace-live-store.ts',
  'src/components/common/section-nav.ts',
  'src/components/status.ts',
  'src/components/transport-health.ts',
  'src/dashboard-ws.ts',
  'src/goal-loop-status.ts',
  'src/keeper-actions.ts',
  'src/keeper-chat-pending.ts',
  'src/keeper-runtime.ts',
  'src/lib/async-state.ts',
  'src/lib/effect-resource.ts',
  'src/lib/remote-data.ts',
  'src/components/common/normalize.ts',
  'src/runtime-counts.ts',
  'src/schemas/sse-event-payload.ts',
  'src/schemas/sse.ts',
  'src/sse.ts',
  'src/sse-store.ts',
  'src/tab-refresh.ts',
  'src/tool-call-output-store.ts',
  'src/types/sse.ts',
]

const TEST_FILES = [
  'design-system/headless-preact/use-inline-suggestion.test.ts',
  'design-system/headless-preact/use-collaboration.test.ts',
  'design-system/headless-preact/use-tabs.test.ts',
  'src/api/schemas/runtime.test.ts',
  'src/api/schemas/dashboard-config.test.ts',
  'src/api/schemas/feature-health.test.ts',
  'src/api/schemas/transport-health.test.ts',
  'src/api/transport-health.test.ts',
  'src/api/feature-health.test.ts',
  'src/cb-shared-telemetry-source.test.ts',
  'src/components/common/markdown.test.ts',
  'src/components/common/rich-content.test.ts',
  'src/components/common/window.test.ts',
  'src/components/common/cytoscape-fsm.test.ts',
  'src/components/auth-status.test.ts',
  'src/components/connector-status.test.ts',
  'src/components/fleet-fsm-matrix.test.ts',
  'src/components/feature-health.test.ts',
  'src/components/goal-loop-panel.test.ts',
  'src/components/ide/ide-activity-panel.test.ts',
  'src/components/journey-panel.test.ts',
  'src/components/journey-waterfall-state.test.ts',
  'src/components/keeper-turn-inspector.test.ts',
  'src/components/keeper-sse-match.test.ts',
  'src/components/keeper-tool-call-inspector.test.ts',
  'src/components/logs.test.ts',
  'src/components/session-trace/session-trace-state.test.ts',
  'src/components/transport-health.test.ts',
  'src/dashboard-bundle-preload.test.ts',
  'src/dashboard-ws.test.ts',
  'src/goal-loop-status.test.ts',
  'src/keeper-actions.test.ts',
  'src/keeper-chat-store.test.ts',
  'src/lib/async-state.test.ts',
  'src/lib/effect-resource.test.ts',
  'src/runtime-counts.test.ts',
  'src/schemas/sse-event-payload.test.ts',
  'src/schemas/sse.test.ts',
  'src/sse-store.test.ts',
  'src/styles/approvals-css-ownership.test.ts',
  'src/styles/chat-blocks-v2.test.ts',
  'src/styles/css-test-utils.ts',
  'src/styles/paper-theme.test.ts',
  'src/styles/skin-v2-paper.test.ts',
]

const DEFAULT_PROJECT_FILES = [
  'design-system/headless-preact/use-inline-suggestion.ts',
  'design-system/headless-preact/use-inline-suggestion.test.ts',
  'design-system/headless-preact/use-collaboration.ts',
  'design-system/headless-preact/use-collaboration.test.ts',
  'design-system/headless-preact/use-tabs.test.ts',
]

// Shrink-only migration allowlist. Every other dashboard TypeScript file is
// forbidden from importing Valibot; remove a path in the same PR that moves
// that boundary to Effect Schema.
const LEGACY_VALIBOT_FILES = [
  'src/api/schemas/agent-relations.ts',
  'src/api/schemas/agent-timeline.ts',
  'src/api/schemas/drift-error.test.ts',
  'src/api/schemas/drift-error.ts',
  'src/api/schemas/gate-connectors.ts',
  'src/api/schemas/gate-status.ts',
  'src/api/schemas/keeper-chat-history.ts',
  'src/api/schemas/keeper-composite.ts',
  'src/api/schemas/keeper-transitions.ts',
  'src/api/schemas/link-previews.ts',
  'src/api/schemas/operator-action.ts',
  'src/api/schemas/runtime-defaults.ts',
  'src/api/schemas/runtime-resolved.ts',
]

export default tseslint.config(
  {
    ignores: ['dist/**', 'coverage/**'],
  },
  {
    files: ['src/**/*.{ts,tsx}'],
    ignores: LEGACY_VALIBOT_FILES,
    linterOptions: {
      // This policy-only pass reaches files outside the typed lint target.
      // Their unrelated inline directives remain owned by their normal lint
      // migration; typed target files restore unused-directive reporting.
      reportUnusedDisableDirectives: false,
    },
    languageOptions: {
      parser: tseslint.parser,
    },
    plugins: {
      '@typescript-eslint': tseslint.plugin,
      'react-hooks': reactHooks,
    },
    rules: {
      'no-restricted-imports': ['error', {
        paths: [
          {
            name: 'valibot',
            message: 'New and migrated boundaries use Effect Schema only.',
          },
        ],
      }],
    },
  },
  {
    files: TARGET_FILES,
    linterOptions: {
      reportUnusedDisableDirectives: true,
    },
    languageOptions: {
      parser: tseslint.parser,
      globals: {
        ...globals.browser,
        ...globals.node,
      },
      parserOptions: {
        projectService: {
          allowDefaultProject: DEFAULT_PROJECT_FILES,
        },
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
    files: [
      'src/api/feature-health.ts',
      'src/api/gate.ts',
      'src/api/transport-health.ts',
      'src/components/common/normalize.ts',
    ],
    rules: {
      '@typescript-eslint/no-unsafe-assignment': 'error',
      '@typescript-eslint/no-unsafe-member-access': 'error',
    },
  },
  {
    files: TEST_FILES,
    linterOptions: {
      reportUnusedDisableDirectives: true,
    },
    languageOptions: {
      parser: tseslint.parser,
      globals: {
        ...globals.browser,
        ...globals.node,
      },
      parserOptions: {
        projectService: {
          allowDefaultProject: DEFAULT_PROJECT_FILES,
        },
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
