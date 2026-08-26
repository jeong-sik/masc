import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import '../styles/keeper-workspace.css'
import '../styles/chat-blocks-v2.css'

import { html } from 'htm/preact'
import { render } from 'preact'
import type { ToolCallEntry } from '../api/dashboard'
import { ChatTranscript } from '../components/chat/primitives'
import { recordToolCallOutputs, resetToolCallOutputs } from '../tool-call-output-store'
import type { KeeperConversationEntry } from '../types'

const keeperName = 'kidsnote'

const deliveredSurfacePost: ToolCallEntry = {
  ts: Date.parse('2026-07-30T02:00:01.000Z') / 1000,
  keeper: keeperName,
  tool: 'keeper_surface_post',
  tool_use_id: 'tc-surface-post',
  execution_id: 'exec-surface-post',
  input: { surface: 'dashboard' },
  output: '{"delivered":true}',
  success: true,
  duration_ms: 18,
}

export const controlStatusFixtureEntries: KeeperConversationEntry[] = [
  {
    id: 'user-tool-only',
    role: 'user',
    source: 'direct_user',
    label: '사용자',
    text: '현재 채널에 확인 메시지를 보내줘.',
    rawText: '현재 채널에 확인 메시지를 보내줘.',
    timestamp: '2026-07-30T02:00:00.000Z',
    delivery: 'history',
    streamState: null,
    details: null,
    error: null,
  },
  {
    id: 'tool-tc-surface-post',
    role: 'tool',
    source: 'tool_result',
    label: 'keeper_surface_post',
    text: '{"surface":"dashboard"}',
    rawText: '{"surface":"dashboard"}',
    timestamp: '2026-07-30T02:00:01.000Z',
    turnRef: 'trace-tool-only#1',
    toolCallId: 'tc-surface-post',
    executionId: 'exec-surface-post',
    delivery: 'history',
    streamState: null,
    details: null,
    error: null,
  },
  {
    id: 'user-gated-effect',
    role: 'user',
    source: 'direct_user',
    label: '사용자',
    text: '외부 저장소에 변경을 적용해줘.',
    rawText: '외부 저장소에 변경을 적용해줘.',
    timestamp: '2026-07-30T02:01:00.000Z',
    delivery: 'history',
    streamState: null,
    details: null,
    error: null,
  },
  {
    id: 'tool-tc-gated-effect',
    role: 'tool',
    source: 'tool_result',
    label: 'external_change',
    text: '{"target":"repository"}',
    rawText: '{"target":"repository"}',
    timestamp: '2026-07-30T02:01:01.000Z',
    turnRef: 'trace-gate-wait#2',
    toolCallId: 'tc-gated-effect',
    delivery: 'history',
    streamState: null,
    details: null,
    error: null,
  },
  {
    id: 'assistant-gate-wait',
    role: 'assistant',
    source: 'direct_assistant',
    label: keeperName,
    text: '',
    rawText: '',
    timestamp: '2026-07-30T02:01:02.000Z',
    turnRef: 'trace-gate-wait#2',
    delivery: 'history',
    streamState: null,
    details: {
      turnOutcome: 'external_effect_pending',
    },
    blocks: [{ t: 'status', kind: 'external_effect_pending' }],
    error: null,
  },
]

const fakeAssistantProseCount = controlStatusFixtureEntries.filter(
  entry => entry.role === 'assistant' && entry.text.trim().length > 0,
).length
const statusCount = controlStatusFixtureEntries.filter(
  entry => entry.blocks?.some(block => block.t === 'status'),
).length
const fixtureStatus =
  fakeAssistantProseCount === 0 && statusCount === 1 ? 'ok' : 'invalid'

export function ControlStatusFixture() {
  return html`
    <main
      class="min-h-screen px-4 py-8"
      style="background: var(--bg-deep);"
      data-keeper-chat-layout="workspace"
      data-control-status-fixture
      data-control-status-fixture-status=${fixtureStatus}
      data-fake-assistant-prose-count=${fakeAssistantProseCount}
      data-control-status-count=${statusCount}
    >
      <section class="mx-auto max-w-[820px]">
        <header class="mb-5">
          <p class="font-mono text-2xs uppercase tracking-[0.2em]" style="color: var(--text-dim);">
            Keeper Chat Control Status Fixture
          </p>
          <h1 class="mt-2 text-xl font-semibold" style="color: var(--text-main);">
            작업 상태는 대화문이 아닙니다
          </h1>
          <p class="mt-2 text-sm" style="color: var(--text-muted);">
            도구 실행만 있는 턴은 작업 타임라인으로, 승인 요청은 다음 행동이 있는 상태 카드로 표시합니다.
          </p>
        </header>
        <div
          class="kw-chat rounded-[var(--r-2)] border p-4"
          style="background: var(--bg-panel); border-color: var(--border-main);"
        >
          <${ChatTranscript}
            entries=${controlStatusFixtureEntries}
            emptyText="No control-status rows"
            variant="messenger"
            size="primary"
            showMetadata=${false}
            groupToolCalls=${true}
          />
        </div>
      </section>
    </main>
  `
}

const root = document.getElementById('app')
if (root) {
  resetToolCallOutputs()
  recordToolCallOutputs([deliveredSurfacePost])
  render(html`<${ControlStatusFixture} />`, root)
}
