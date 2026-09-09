import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import { render } from 'preact'
import { html } from 'htm/preact'
import { ChatEditEvidence } from '../components/chat/edit-evidence'
import type { ToolCallEntry } from '../api/dashboard'

// The harness supplies deterministic receipts and artifact HTTP responses.
// Actual fetch verification, component rendering and worker execution are live.
async function start() {
  const response = await fetch('/preview-fixture/edit-receipts')
  const receipts: ToolCallEntry[] = await response.json()
  render(html`<main class="mx-auto max-w-5xl p-4">
    <h1>Keeper 편집 diff — CI 브라우저 시나리오</h1>
    <p>합성 편집 기록으로 화면과 실제 worker를 검증합니다. 런타임 배포 증거가 아닙니다.</p>
    ${receipts.map((receipt, index) => html`<div data-scenario=${index}><${ChatEditEvidence} output=${receipt} /></div>`)}
  </main>`, document.getElementById('app')!)
}
void start()
