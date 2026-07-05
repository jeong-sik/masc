import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import '../styles/keeper-workspace.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import type { ToolCallEntry } from '../api/dashboard'
import { ChatTranscript } from '../components/chat/primitives'
import { keeperClientObservedSseStreamContract } from '../keeper-state'
import {
  recordToolCallOutputs,
  resetToolCallOutputs,
  type ToolCallOutputHydrationContract,
} from '../tool-call-output-store'
import type { KeeperConversationEntry } from '../types'

export const INTERLEAVE_FIXTURE_KEEPER = 'sangsu'
export const INTERLEAVE_ORDER_SIGNATURE =
  'trace:think|tool:tc-context|trace:think|tool:tc-missing|chat:assistant-interleave'
export const INTERLEAVE_FIXTURE_COVERED_SINCE_MS = Date.parse('2026-07-05T14:19:50.000Z')
export const INTERLEAVE_FIXTURE_COVERED_THROUGH_MS = Date.parse('2026-07-05T14:20:10.000Z')

const joinedToolOutput: ToolCallEntry = {
  ts: INTERLEAVE_FIXTURE_COVERED_THROUGH_MS / 1000,
  keeper: INTERLEAVE_FIXTURE_KEEPER,
  tool: 'keeper_context_status',
  tool_use_id: 'tc-context',
  input: { scope: 'current' },
  output: 'context status joined from tool_calls_endpoint',
  success: true,
  semantic_success: true,
  duration_ms: 84,
}

export const interleaveHydrationContract: ToolCallOutputHydrationContract = {
  source: 'tool_calls_endpoint',
  status: 'hydrated',
  failureReason: null,
  startedAtMs: INTERLEAVE_FIXTURE_COVERED_SINCE_MS,
  completedAtMs: INTERLEAVE_FIXTURE_COVERED_THROUGH_MS,
  coveredSinceMs: INTERLEAVE_FIXTURE_COVERED_SINCE_MS,
  coveredThroughMs: INTERLEAVE_FIXTURE_COVERED_THROUGH_MS,
}

export const interleaveEntries: KeeperConversationEntry[] = [
  {
    id: 'tool-tc-context',
    role: 'tool',
    source: 'tool_result',
    label: 'keeper_context_status',
    text: '{"scope":"current"}',
    rawText: '{"scope":"current"}',
    timestamp: '2026-07-05T14:20:01.000Z',
    turnRef: 'trace-interleave#9',
    delivery: 'history',
    streamState: null,
    details: null,
    error: null,
  },
  {
    id: 'assistant-interleave',
    role: 'assistant',
    source: 'direct_assistant',
    label: INTERLEAVE_FIXTURE_KEEPER,
    text: 'Structural order stayed intact without timestamp sorting or fake tool output.',
    rawText: 'Structural order stayed intact without timestamp sorting or fake tool output.',
    timestamp: '2026-07-05T14:20:00.000Z',
    turnRef: 'trace-interleave#9',
    delivery: 'delivered',
    streamState: null,
    streamContract: keeperClientObservedSseStreamContract('sse_event', 'backend_terminal_event', {
      eventName: 'RUN_FINISHED',
      turnRef: 'trace-interleave#9',
      reason: 'live terminal event observed by dashboard SSE client',
    }),
    traceSteps: [
      {
        kind: 'think',
        text: 'First structural thought appears before the tool even though its timestamp is later.',
        ts: '2026-07-05T14:20:05.000Z',
        oasBlockIndex: 10,
      },
      {
        kind: 'tool',
        name: 'keeper_context_status',
        toolCallId: 'tc-context',
        status: 'ok',
        args: '{"scope":"current"}',
        ts: '2026-07-05T14:20:01.000Z',
        oasBlockIndex: 11,
      },
      {
        kind: 'think',
        text: 'Second structural thought must remain after the joined tool despite an earlier timestamp.',
        ts: '2026-07-05T14:20:02.000Z',
        oasBlockIndex: 12,
      },
      {
        kind: 'tool',
        name: 'keeper_memory_search',
        toolCallId: 'tc-missing',
        args: '{"query":"old task context"}',
        ts: '2026-07-05T14:20:03.000Z',
        oasBlockIndex: 13,
      },
    ],
    details: null,
    error: null,
  },
]

export const joinedToolCount = interleaveEntries.filter(entry => entry.role === 'tool').length
export const traceOnlyToolCount = interleaveEntries
  .flatMap(entry => entry.traceSteps ?? [])
  .filter(step => step.kind === 'tool' && step.toolCallId === 'tc-missing')
  .length
export const interleaveFixtureStatus =
  joinedToolCount === 1 && traceOnlyToolCount === 1 ? 'ok' : 'invalid'

export function installInterleaveFixtureToolOutputs(): void {
  resetToolCallOutputs()
  recordToolCallOutputs([joinedToolOutput])
}

export function InterleaveContractFixture() {
  return html`
    <main
      class="min-h-screen px-4 py-8"
      style="background: var(--bg-deep);"
      data-keeper-chat-layout="workspace"
      data-interleave-contract-fixture
      data-interleave-contract-fixture-status=${interleaveFixtureStatus}
      data-interleave-order-signature=${INTERLEAVE_ORDER_SIGNATURE}
      data-interleave-joined-tool-count=${joinedToolCount}
      data-interleave-trace-only-tool-count=${traceOnlyToolCount}
    >
      <section class="mx-auto max-w-[820px]">
        <header class="mb-5">
          <p class="font-mono text-2xs uppercase tracking-[0.2em]" style="color: var(--text-dim);">
            Keeper Chat Interleave Contract Fixture
          </p>
          <h1 class="mt-2 text-xl font-semibold" style="color: var(--text-main);">
            Structural thinking/tool order
          </h1>
        </header>
        <div
          class="kw-chat rounded-[var(--r-2)] border p-4"
          style="background: var(--bg-panel); border-color: var(--border-main);"
        >
          <${ChatTranscript}
            entries=${interleaveEntries}
            emptyText="No interleave rows"
            variant="messenger"
            size="primary"
            showMetadata=${false}
            groupToolCalls=${true}
            toolOutputsCoveredSinceMs=${INTERLEAVE_FIXTURE_COVERED_SINCE_MS}
            toolOutputsCoveredThroughMs=${INTERLEAVE_FIXTURE_COVERED_THROUGH_MS}
            toolOutputHydrationContract=${interleaveHydrationContract}
          />
        </div>
      </section>
    </main>
  `
}

const root = document.getElementById('app')
if (root) {
  installInterleaveFixtureToolOutputs()
  render(html`<${InterleaveContractFixture} />`, root)
}
