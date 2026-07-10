import { html } from 'htm/preact'
import { ActionButton } from '../common/button'
import { PersonaBrowser } from './persona-browser'
import { showSpawnPanel } from './keeper-spawn-state'

// Simple keeper creation entry point for the fleet. Pick a persona → confirm →
// the keeper boots with that persona's default goal/instructions. Fine-grained
// overrides at creation time are intentionally NOT here — those go through
// keeper detail (post-create) or masc_keeper_up in the tool executor, keeping
// this flow to one decision.
//
// Spacing below the panel is owned by the parent flex container (gap-4 in
// AgentsUnified); the root carries no bottom margin so the panel↔roster gap
// stays a single 16px step instead of stacking margin + gap.
export function KeeperSpawnPanel() {
  if (!showSpawnPanel.value) {
    return html`<div class="v2-monitoring-surface" data-testid="keeper-spawn-panel">
      <${ActionButton} variant="primary" size="md" onClick=${() => { showSpawnPanel.value = true }}>+ 키퍼 생성<//>
    </div>`
  }
  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4 v2-monitoring-panel"
      data-testid="keeper-spawn-panel"
    >
      <div class="flex items-center justify-between mb-3 v2-monitoring-toolbar">
        <h3 class="text-sm text-[var(--color-fg-secondary)] font-medium">키퍼 생성</h3>
        <${ActionButton} variant="subtle" size="sm" onClick=${() => { showSpawnPanel.value = false }}>닫기<//>
      </div>
      <p class="text-2xs text-[var(--color-fg-muted)] mb-3">
        페르소나를 골라 키퍼를 시작합니다. 목표·지시사항은 페르소나 기본값을 쓰고, 세부 조정은 생성 후 keeper 상세에서 합니다.
      </p>
      <${PersonaBrowser} />
    </div>
  `
}
