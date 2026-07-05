import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import '../styles/keeper-workspace.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import { ChatTranscript } from '../components/chat/primitives'
import { keeperClientObservedSseStreamContract } from '../keeper-state'
import {
  resetToolCallOutputs,
  type ToolCallOutputHydrationContract,
} from '../tool-call-output-store'
import type { KeeperConversationEntry } from '../types'

export const TOOL_OUTPUT_FAILURE_FIXTURE_KEEPER = 'sangsu'
export const TOOL_OUTPUT_FAILURE_REASON = 'tool_calls_endpoint_502'
export const HYDRATION_FAILED_ORDER_SIGNATURE = 'tool:tc-hydration-failed|chat:assistant-hydration-failed'
export const COVERAGE_GAP_ORDER_SIGNATURE = 'tool:tc-coverage-gap|chat:assistant-coverage-gap'
export const HYDRATION_FAILED_STARTED_AT_MS = Date.parse('2026-07-05T15:09:50.000Z')
export const HYDRATION_FAILED_COMPLETED_AT_MS = Date.parse('2026-07-05T15:10:05.000Z')
export const COVERAGE_GAP_COVERED_SINCE_MS = Date.parse('2026-07-05T15:11:00.000Z')
export const COVERAGE_GAP_COVERED_THROUGH_MS = Date.parse('2026-07-05T15:11:10.000Z')

export const hydrationFailedContract: ToolCallOutputHydrationContract = {
  source: 'tool_calls_endpoint',
  status: 'failed',
  failureReason: TOOL_OUTPUT_FAILURE_REASON,
  startedAtMs: HYDRATION_FAILED_STARTED_AT_MS,
  completedAtMs: HYDRATION_FAILED_COMPLETED_AT_MS,
  coveredSinceMs: null,
  coveredThroughMs: null,
}

export const coverageGapContract: ToolCallOutputHydrationContract = {
  source: 'tool_calls_endpoint',
  status: 'hydrated',
  failureReason: null,
  startedAtMs: COVERAGE_GAP_COVERED_SINCE_MS,
  completedAtMs: COVERAGE_GAP_COVERED_THROUGH_MS,
  coveredSinceMs: COVERAGE_GAP_COVERED_SINCE_MS,
  coveredThroughMs: COVERAGE_GAP_COVERED_THROUGH_MS,
}

export const hydrationFailedEntries: KeeperConversationEntry[] = [
  {
    id: 'tool-tc-hydration-failed',
    role: 'tool',
    source: 'tool_result',
    label: 'keeper_context_status',
    text: '{"scope":"current"}',
    rawText: '{"scope":"current"}',
    timestamp: '2026-07-05T15:10:01.000Z',
    turnRef: 'tool-output-failure#1',
    delivery: 'history',
    streamState: null,
    details: null,
    error: null,
  },
  {
    id: 'assistant-hydration-failed',
    role: 'assistant',
    source: 'direct_assistant',
    label: TOOL_OUTPUT_FAILURE_FIXTURE_KEEPER,
    text: 'The tool output surface failed, so this cannot be reported as pending.',
    rawText: 'The tool output surface failed, so this cannot be reported as pending.',
    timestamp: '2026-07-05T15:10:02.000Z',
    turnRef: 'tool-output-failure#1',
    delivery: 'delivered',
    streamState: null,
    streamContract: keeperClientObservedSseStreamContract('sse_event', 'backend_terminal_event', {
      eventName: 'RUN_FINISHED',
      turnRef: 'tool-output-failure#1',
      reason: 'terminal event observed before tool output hydration failed',
    }),
    traceSteps: [
      {
        kind: 'tool',
        name: 'keeper_context_status',
        toolCallId: 'tc-hydration-failed',
        args: '{"scope":"current"}',
        ts: '2026-07-05T15:10:01.000Z',
        oasBlockIndex: 21,
      },
    ],
    details: null,
    error: null,
  },
]

export const coverageGapEntries: KeeperConversationEntry[] = [
  {
    id: 'tool-tc-coverage-gap',
    role: 'tool',
    source: 'tool_result',
    label: 'keeper_board_comment',
    text: '{"post_id":"post-7","body":"ack"}',
    rawText: '{"post_id":"post-7","body":"ack"}',
    timestamp: '2026-07-05T15:11:30.000Z',
    turnRef: 'tool-output-failure#2',
    delivery: 'history',
    streamState: null,
    details: null,
    error: null,
  },
  {
    id: 'assistant-coverage-gap',
    role: 'assistant',
    source: 'direct_assistant',
    label: TOOL_OUTPUT_FAILURE_FIXTURE_KEEPER,
    text: 'Hydration completed for an older tail, so this newer tool is a coverage gap.',
    rawText: 'Hydration completed for an older tail, so this newer tool is a coverage gap.',
    timestamp: '2026-07-05T15:11:31.000Z',
    turnRef: 'tool-output-failure#2',
    delivery: 'delivered',
    streamState: null,
    streamContract: keeperClientObservedSseStreamContract('sse_event', 'backend_terminal_event', {
      eventName: 'RUN_FINISHED',
      turnRef: 'tool-output-failure#2',
      reason: 'terminal event observed after an older tool-output tail hydrated',
    }),
    traceSteps: [
      {
        kind: 'tool',
        name: 'keeper_board_comment',
        toolCallId: 'tc-coverage-gap',
        args: '{"post_id":"post-7","body":"ack"}',
        ts: '2026-07-05T15:11:30.000Z',
        oasBlockIndex: 22,
      },
    ],
    details: null,
    error: null,
  },
]

export const hydrationFailedToolCount = hydrationFailedEntries.filter(entry => entry.role === 'tool').length
export const coverageGapToolCount = coverageGapEntries.filter(entry => entry.role === 'tool').length
export const toolOutputFailureFixtureStatus =
  hydrationFailedToolCount === 1 && coverageGapToolCount === 1 ? 'ok' : 'invalid'

export function installToolOutputFailureFixtureStore(): void {
  resetToolCallOutputs()
}

export function ToolOutputFailureContractFixture() {
  return html`
    <main
      class="min-h-screen px-4 py-8"
      style="background: var(--bg-deep);"
      data-keeper-chat-layout="workspace"
      data-tool-output-failure-contract-fixture
      data-tool-output-failure-contract-fixture-status=${toolOutputFailureFixtureStatus}
      data-tool-output-failure-hydration-failed-count=${hydrationFailedToolCount}
      data-tool-output-failure-coverage-gap-count=${coverageGapToolCount}
    >
      <section class="mx-auto max-w-[900px]">
        <header class="mb-5">
          <p class="font-mono text-2xs uppercase tracking-[0.2em]" style="color: var(--text-dim);">
            Keeper Chat Tool Output Failure Contract Fixture
          </p>
          <h1 class="mt-2 text-xl font-semibold" style="color: var(--text-main);">
            Tool output failures are explicit
          </h1>
        </header>
        <div class="grid gap-4">
          <section
            class="kw-chat rounded-[var(--r-2)] border p-4"
            style="background: var(--bg-panel); border-color: var(--border-main);"
            data-tool-output-failure-scenario="hydration-failed"
            data-tool-output-failure-order-signature=${HYDRATION_FAILED_ORDER_SIGNATURE}
          >
            <${ChatTranscript}
              entries=${hydrationFailedEntries}
              emptyText="No hydration failure rows"
              variant="messenger"
              size="primary"
              showMetadata=${false}
              groupToolCalls=${true}
              toolOutputHydrationContract=${hydrationFailedContract}
            />
          </section>
          <section
            class="kw-chat rounded-[var(--r-2)] border p-4"
            style="background: var(--bg-panel); border-color: var(--border-main);"
            data-tool-output-failure-scenario="coverage-gap"
            data-tool-output-failure-order-signature=${COVERAGE_GAP_ORDER_SIGNATURE}
          >
            <${ChatTranscript}
              entries=${coverageGapEntries}
              emptyText="No coverage gap rows"
              variant="messenger"
              size="primary"
              showMetadata=${false}
              groupToolCalls=${true}
              toolOutputsCoveredSinceMs=${COVERAGE_GAP_COVERED_SINCE_MS}
              toolOutputsCoveredThroughMs=${COVERAGE_GAP_COVERED_THROUGH_MS}
              toolOutputHydrationContract=${coverageGapContract}
            />
          </section>
        </div>
      </section>
    </main>
  `
}

const root = document.getElementById('app')
if (root) {
  installToolOutputFailureFixtureStore()
  render(html`<${ToolOutputFailureContractFixture} />`, root)
}
