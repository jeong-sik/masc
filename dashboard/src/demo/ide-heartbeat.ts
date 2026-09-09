import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import { render } from 'preact'
import { html } from 'htm/preact'
import { IdePersistencePanel } from '../components/ide/ide-persistence-panel'
import { keepers } from '../store'
import type { Keeper } from '../types'

// CI-only fixture: the browser harness supplies explicit synthetic HTTP state.
async function start() {
  const response = await fetch('/preview-fixture/heartbeat-keepers')
  if (!response.ok) throw new Error('Heartbeat fixture unavailable')
  const rows: Keeper[] = await response.json()
  keepers.value = rows
  render(html`<main>
    <h1>IDE 하트비트 표시 검증</h1>
    <p>합성 실행 상태로 실제 패널을 검증합니다. 저장 완료나 런타임 배포 증거가 아닙니다.</p>
    ${rows.map(keeper => html`<div data-keeper=${keeper.name}>
      <${IdePersistencePanel} keeperName=${keeper.name} />
    </div>`)}
  </main>`, document.getElementById('app')!)
}
void start()
