import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import { render } from 'preact'
import { html } from 'htm/preact'
import { ChatTranscript } from '../components/chat/primitives'
import { recordToolCallOutputs } from '../tool-call-output-store'
import type { KeeperConversationEntry } from '../types'
import '../styles/keeper-workspace.css'
import type { ToolCallEntry } from '../api/dashboard'

// The harness supplies deterministic receipts and artifact HTTP responses.
// Actual fetch verification, component rendering and worker execution are live.
async function start() {
  const response = await fetch('/preview-fixture/edit-receipts')
  const receipts: ToolCallEntry[] = await response.json()
  recordToolCallOutputs(receipts)
  const transcript = (receipt: ToolCallEntry, index: number): KeeperConversationEntry[] => [{
    id: `edit-row-${index}`, role: 'tool', source: 'tool_result', label: 'Edit',
    text: JSON.stringify(receipt.input), rawText: JSON.stringify(receipt.input),
    timestamp: '2026-09-10T00:00:00.000Z', turnRef: `edit-turn-${index}`,
    executionId: receipt.execution_id, toolCallId: 'provider-reused-id',
    delivery: 'history', streamState: null, details: null, error: null,
  }]
  render(html`<main class="mx-auto max-w-5xl p-4">
    <h1>Keeper 편집 diff — CI 브라우저 시나리오</h1>
    <p>합성 편집 기록으로 화면과 실제 worker를 검증합니다. 런타임 배포 증거가 아닙니다.</p>
    ${receipts.map((receipt, index) => html`<div data-scenario=${index}><${ChatTranscript} keeperName=${receipt.keeper} entries=${transcript(receipt, index)} emptyText="No edit records" variant="messenger" size="primary" /></div>`)}
  </main>`, document.getElementById('app')!)
}
void start()
