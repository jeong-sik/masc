import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import { SurfaceCard } from '../common/card'
import { ActionButton } from '../common/button'
import { shellAuthSummary } from '../../store'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'
import { personas, personasLoading, personasError, loadPersonas, spawnKeeperFromPersona, spawning, spawnResult, type PersonaSummary } from './keeper-spawn-state'

const confirmTarget = signal<string | null>(null)
const searchQuery = signal('')

/**
 * Pure filter for persona rows.
 *
 * - `query` is case-insensitive substring match across `name`, `displayName`,
 *   `role`, `mode`, and `description` (trimmed).
 * - Empty/whitespace-only query returns the input reference unchanged
 *   (zero-allocation fast path).
 * - Does not mutate the input array.
 */
export function filterPersonas(
  rows: readonly PersonaSummary[],
  query: string,
): readonly PersonaSummary[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return rows
  return rows.filter(p => {
    if (p.name.toLowerCase().includes(needle)) return true
    if (p.displayName && p.displayName.toLowerCase().includes(needle)) return true
    if (p.role && p.role.toLowerCase().includes(needle)) return true
    if (p.mode && p.mode.toLowerCase().includes(needle)) return true
    if (p.description && p.description.toLowerCase().includes(needle)) return true
    return false
  })
}

function PersonaCard({ persona }: { persona: PersonaSummary }) {
  const isConfirming = confirmTarget.value === persona.name
  const isSpawning = spawning.value && isConfirming
  const spawnAccess = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  const title = persona.displayName ?? persona.name
  return html`
    <div class="rounded border border-[var(--card-border)] bg-[var(--white-4)] p-4 flex flex-col gap-2 min-w-45">
      <div class="text-base text-[var(--text-strong)] font-medium">${title}</div>
      ${persona.role ? html`<div class="text-2xs text-[var(--text-muted)]">${persona.role}</div>` : null}
      ${persona.mode ? html`<div class="text-3xs text-[var(--text-muted)]">모드: ${persona.mode}</div>` : null}
      ${persona.description ? html`<div class="text-2xs text-[var(--text-body)] mt-1 line-clamp-2" title=${persona.description}>${persona.description}</div>` : null}
      <div class="mt-auto pt-2">
        ${isConfirming ? html`
          <div class="flex flex-col gap-1.5">
            <p class="text-3xs text-[var(--warn)]">키퍼를 시작합니까?</p>
            <div class="flex gap-1.5">
              <${ActionButton} variant="primary" size="sm" disabled=${isSpawning || !spawnAccess.allowed}
                title=${spawnAccess.allowed ? undefined : spawnAccess.reason ?? undefined}
                onClick=${() => { void spawnKeeperFromPersona(persona.name).then(() => { confirmTarget.value = null }) }}>
                ${isSpawning ? '생성 중...' : '시작'}<//>
              <${ActionButton} variant="ghost" size="sm" onClick=${() => { confirmTarget.value = null }}>취소<//>
            </div>
          </div>
        ` : html`
          <${ActionButton}
            variant="ghost"
            size="sm"
            block=${true}
            disabled=${!spawnAccess.allowed}
            title=${spawnAccess.allowed ? undefined : spawnAccess.reason ?? undefined}
            onClick=${() => { confirmTarget.value = persona.name }}
          >키퍼 시작<//>
        `}
      </div>
    </div>
  `
}

export function PersonaBrowser() {
  useEffect(() => { if (personas.value.length === 0 && !personasLoading.value) void loadPersonas() }, [])
  const spawnAccess = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  if (personasLoading.value) return html`<p class="text-xs text-[var(--text-muted)] py-4" role="status">페르소나 로딩 중...</p>`
  if (personasError.value) return html`
    <div class="py-4">
      <p class="text-xs text-[var(--bad)] mb-2" role="alert">${personasError.value}</p>
      <${ActionButton} variant="ghost" size="sm" onClick=${() => void loadPersonas()}>재시도<//>
    </div>`
  if (personas.value.length === 0) return html`<p class="text-xs text-[var(--text-muted)] py-4">등록된 페르소나가 없습니다.</p>`
  const visible = filterPersonas(personas.value, searchQuery.value)
  return html`
    <div role="region" aria-label="페르소나 목록">
      ${spawnAccess.allowed ? null : html`
        <p class="mb-3 text-2xs text-[var(--warn)]">
          키퍼 생성 차단: ${spawnAccess.reason ?? 'worker 권한이 필요합니다.'}
        </p>
      `}
      <div class="flex flex-wrap items-center gap-2 mb-3">
        <input
          type="search"
          value=${searchQuery.value}
          placeholder="페르소나 검색 (이름/역할/모드/설명)"
          aria-label="페르소나 검색"
          autoComplete="off"
          onInput=${(e: Event) => { searchQuery.value = (e.target as HTMLInputElement).value }}
          class="min-w-45 flex-1 rounded border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-2xs text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)] focus-visible:ring-2 focus-visible:ring-[var(--accent)]/50"
        />
        <span class="text-3xs text-[var(--text-muted)] tabular-nums">
          ${searchQuery.value.trim()
            ? `${visible.length} / ${personas.value.length}`
            : `${personas.value.length}개`}
        </span>
      </div>
      ${visible.length === 0
        ? html`<p class="text-xs text-[var(--text-muted)] py-4">검색 조건에 맞는 페르소나가 없습니다.</p>`
        : html`
          <div class="grid grid-cols-[repeat(auto-fill,minmax(200px,1fr))] gap-3">
            ${visible.map(p => html`<${PersonaCard} key=${p.name} persona=${p} />`)}
          </div>
        `}
      ${spawnResult.value ? html`
        <${SurfaceCard} class="mt-3" variant="compact">
          <pre class="text-2xs font-mono leading-[1.4] overflow-x-auto max-h-50 overflow-y-auto custom-scrollbar
            ${spawnResult.value.success ? 'text-[var(--text-body)]' : 'text-[var(--bad)]'}" tabindex="0" aria-label="spawn 결과">${spawnResult.value.message}</pre>
        <//>` : null}
    </div>
  `
}
