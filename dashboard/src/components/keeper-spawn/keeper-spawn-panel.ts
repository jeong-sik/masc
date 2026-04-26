import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { ActionButton } from '../common/button'
import { PersonaBrowser } from './persona-browser'
import { PersonaGenerator } from './persona-generator'
import { showSpawnPanel } from './keeper-spawn-state'

type SpawnMode = 'persona' | 'generate' | 'direct'
const spawnMode = signal<SpawnMode>('persona')

export function KeeperSpawnPanel() {
  if (!showSpawnPanel.value) {
    return html`<div class="mb-4">
      <${ActionButton} variant="primary" size="md" onClick=${() => { showSpawnPanel.value = true }}>+ 키퍼 생성<//>
    </div>`
  }
  return html`
    <div class="mb-4 rounded border border-[var(--color-border-default)] bg-[var(--bg-1)] p-4">
      <div class="flex items-center justify-between mb-3">
        <h3 class="text-sm text-[var(--color-fg-secondary)] font-medium">키퍼 생성</h3>
        <${ActionButton} variant="subtle" size="sm" onClick=${() => { showSpawnPanel.value = false }}>닫기<//>
      </div>
      <div class="flex gap-2 mb-3">
        <${ActionButton} variant=${spawnMode.value === 'persona' ? 'primary' : 'ghost'} size="sm"
          onClick=${() => { spawnMode.value = 'persona' }}>페르소나에서 생성<//>
        <${ActionButton} variant=${spawnMode.value === 'generate' ? 'primary' : 'ghost'} size="sm"
          onClick=${() => { spawnMode.value = 'generate' }}>새 페르소나<//>
        <${ActionButton} variant=${spawnMode.value === 'direct' ? 'primary' : 'ghost'} size="sm"
          onClick=${() => { spawnMode.value = 'direct' }}>직접 생성<//>
      </div>
      ${spawnMode.value === 'persona'
        ? html`<${PersonaBrowser} />`
        : spawnMode.value === 'generate'
          ? html`<${PersonaGenerator} />`
        : html`<p class="text-xs text-[var(--color-fg-muted)]">직접 생성은 도구 실행기에서 <code class="text-[var(--color-accent-fg)]">masc_keeper_up</code>을 사용하세요.</p>`}
    </div>
  `
}
