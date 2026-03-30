import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import { SurfaceCard } from '../common/card'
import { ActionButton } from '../common/button'
import { personas, personasLoading, personasError, loadPersonas, spawnKeeperFromPersona, spawning, spawnResult, type PersonaSummary } from './keeper-spawn-state'

const confirmTarget = signal<string | null>(null)

function PersonaCard({ persona }: { persona: PersonaSummary }) {
  const isConfirming = confirmTarget.value === persona.name
  const isSpawning = spawning.value && isConfirming
  const title = persona.displayName ?? persona.name
  return html`
    <div class="rounded-xl border border-[var(--card-border)] bg-[var(--white-4)] p-4 flex flex-col gap-2 min-w-[180px]">
      <div class="text-[14px] text-[var(--text-strong)] font-medium">${title}</div>
      ${persona.role ? html`<div class="text-[11px] text-[var(--text-muted)]">${persona.role}</div>` : null}
      ${persona.mode ? html`<div class="text-[10px] text-[var(--text-muted)]">모드: ${persona.mode}</div>` : null}
      ${persona.description ? html`<div class="text-[11px] text-[var(--text-body)] mt-1 line-clamp-2">${persona.description}</div>` : null}
      <div class="mt-auto pt-2">
        ${isConfirming ? html`
          <div class="flex flex-col gap-1.5">
            <p class="text-[10px] text-[var(--warn)]">키퍼를 시작합니까?</p>
            <div class="flex gap-1.5">
              <${ActionButton} variant="primary" size="sm" disabled=${isSpawning}
                onClick=${() => { void spawnKeeperFromPersona(persona.name).then(() => { confirmTarget.value = null }) }}>
                ${isSpawning ? '생성 중...' : '시작'}<//>
              <${ActionButton} variant="ghost" size="sm" onClick=${() => { confirmTarget.value = null }}>취소<//>
            </div>
          </div>
        ` : html`
          <${ActionButton} variant="ghost" size="sm" block=${true} onClick=${() => { confirmTarget.value = persona.name }}>키퍼 시작<//>
        `}
      </div>
    </div>
  `
}

export function PersonaBrowser() {
  useEffect(() => { if (personas.value.length === 0 && !personasLoading.value) void loadPersonas() }, [])
  if (personasLoading.value) return html`<p class="text-[12px] text-[var(--text-muted)] py-4">페르소나 로딩 중...</p>`
  if (personasError.value) return html`
    <div class="py-4">
      <p class="text-[12px] text-[var(--bad)] mb-2">${personasError.value}</p>
      <${ActionButton} variant="ghost" size="sm" onClick=${() => void loadPersonas()}>재시도<//>
    </div>`
  if (personas.value.length === 0) return html`<p class="text-[12px] text-[var(--text-muted)] py-4">등록된 페르소나가 없습니다.</p>`
  return html`
    <div>
      <div class="grid grid-cols-[repeat(auto-fill,minmax(200px,1fr))] gap-3">
        ${personas.value.map(p => html`<${PersonaCard} key=${p.name} persona=${p} />`)}
      </div>
      ${spawnResult.value ? html`
        <${SurfaceCard} class="mt-3" variant="compact">
          <pre class="text-[11px] font-mono overflow-x-auto max-h-[200px] overflow-y-auto
            ${spawnResult.value.success ? 'text-[var(--text-body)]' : 'text-[var(--bad)]'}">${spawnResult.value.message}</pre>
        <//>` : null}
    </div>
  `
}
