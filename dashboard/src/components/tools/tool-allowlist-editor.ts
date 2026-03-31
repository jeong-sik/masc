// Tool allowlist/denylist editor for keeper detail view.
// Uses existing POST /api/v1/keepers/:name/tools endpoint.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { editKeeperTools } from '../../api/keeper'
import type { ToolEditAction } from '../../api/keeper'

// ── State ────────────────────────────────────────────────

const searchTerm = signal('')
const pendingAdds = signal<string[]>([])
const pendingRemoves = signal<string[]>([])
const saving = signal(false)
const lastError = signal<string | null>(null)
const lastSuccess = signal<string | null>(null)

function resetEditorState(): void {
  searchTerm.value = ''
  pendingAdds.value = []
  pendingRemoves.value = []
  saving.value = false
  lastError.value = null
  lastSuccess.value = null
}

// ── Components ───────────────────────────────────────────

function RemovableChip({
  name,
  pending,
  onToggle,
}: {
  name: string
  pending: boolean
  onToggle: () => void
}) {
  const base =
    'inline-flex items-center gap-1 py-0.5 px-2 rounded-full text-[10px] font-medium border transition-colors cursor-pointer'
  const style = pending
    ? 'bg-red-500/15 text-red-300 border-red-400/30 line-through'
    : 'bg-[var(--accent-12)] text-[#9ad9ff] border-[rgba(71,184,255,0.25)] hover:bg-[rgba(71,184,255,0.18)]'
  return html`
    <button type="button" class="${base} ${style}" onClick=${onToggle}
      title=${pending ? '제거 취소' : '클릭하여 제거 표시'}
    >
      ${name}
      <span class="text-[8px] opacity-60">${pending ? '↩' : '✕'}</span>
    </button>
  `
}

function AddableRow({
  name,
  onAdd,
}: {
  name: string
  onAdd: () => void
}) {
  return html`
    <button type="button"
      class="flex items-center gap-2 w-full text-left py-1.5 px-3 rounded-lg hover:bg-[var(--white-6)] transition-colors cursor-pointer"
      onClick=${onAdd}
    >
      <span class="text-emerald-400 text-[10px] font-bold">+</span>
      <span class="text-[11px] text-[var(--text-body)]">${name}</span>
    </button>
  `
}

// ── Main Editor ──────────────────────────────────────────

export function ToolAllowlistEditor({
  keeperName,
  currentAllowlist,
  allToolNames,
  onUpdated,
}: {
  keeperName: string
  currentAllowlist: string[]
  allToolNames: string[]
  onUpdated: (newAllowlist: string[]) => void
}) {
  const removes = pendingRemoves.value
  const adds = pendingAdds.value
  const query = searchTerm.value.toLowerCase().trim()

  const hasChanges = removes.length > 0 || adds.length > 0

  // Tools available to add: in catalog but not in current allowlist and not already pending add
  const addCandidates = allToolNames
    .filter(
      (n) =>
        !currentAllowlist.includes(n) &&
        !adds.includes(n) &&
        (query.length === 0 || n.toLowerCase().includes(query)),
    )
    .slice(0, 20)

  // Pending adds that also match search
  const filteredAdds = adds.filter(
    (n) => query.length === 0 || n.toLowerCase().includes(query),
  )

  async function applyChanges(): Promise<void> {
    saving.value = true
    lastError.value = null
    lastSuccess.value = null
    try {
      // Compute final list: current - removes + adds
      const finalList = [
        ...currentAllowlist.filter((n) => !removes.includes(n)),
        ...adds,
      ]
      const resp = await editKeeperTools(keeperName, 'set_allowlist' as ToolEditAction, finalList)
      if (resp.ok) {
        lastSuccess.value = `${resp.total_active}개 도구 활성`
        onUpdated(resp.tool_allowlist)
        pendingAdds.value = []
        pendingRemoves.value = []
      } else {
        lastError.value = resp.error ?? '알 수 없는 오류'
      }
    } catch (err) {
      lastError.value = err instanceof Error ? err.message : '요청 실패'
    } finally {
      saving.value = false
    }
  }

  return html`
    <div class="flex flex-col gap-2 mt-2 p-3 rounded-xl border border-[var(--card-border)] bg-[rgba(11,18,32,0.6)]">
      <div class="flex items-center justify-between">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">허용 도구 편집</span>
        <button type="button"
          class="text-[10px] text-[var(--text-muted)] hover:text-[var(--text-body)] cursor-pointer"
          onClick=${resetEditorState}
        >초기화</button>
      </div>

      <!-- Current allowlist with remove toggle -->
      <div class="flex flex-wrap gap-1.5 max-h-[200px] overflow-y-auto">
        ${currentAllowlist.map(
          (name) => html`
            <${RemovableChip}
              name=${name}
              pending=${removes.includes(name)}
              onToggle=${() => {
                pendingRemoves.value = removes.includes(name)
                  ? removes.filter((n) => n !== name)
                  : [...removes, name]
              }}
            />
          `,
        )}
        ${filteredAdds.map(
          (name) => html`
            <span class="inline-flex items-center gap-1 py-0.5 px-2 rounded-full text-[10px] font-medium bg-emerald-500/15 text-emerald-300 border border-emerald-400/30 cursor-pointer"
              onClick=${() => {
                pendingAdds.value = adds.filter((n) => n !== name)
              }}
              title="추가 취소"
            >
              + ${name}
              <span class="text-[8px] opacity-60">↩</span>
            </span>
          `,
        )}
      </div>

      <!-- Search to add -->
      <input
        type="text"
        class="w-full px-3 py-1.5 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] text-[11px] text-[var(--text-body)] placeholder:text-[var(--text-muted)] focus:outline-none focus:border-[rgba(71,184,255,0.5)]"
        placeholder="도구 검색하여 추가..."
        value=${searchTerm.value}
        onInput=${(e: Event) => {
          searchTerm.value = (e.target as HTMLInputElement).value
        }}
      />

      ${query.length > 0 && addCandidates.length > 0
        ? html`
            <div class="max-h-[150px] overflow-y-auto rounded-lg border border-[var(--card-border)] bg-[var(--white-3)]">
              ${addCandidates.map(
                (name) => html`
                  <${AddableRow}
                    name=${name}
                    onAdd=${() => {
                      pendingAdds.value = [...adds, name]
                      searchTerm.value = ''
                    }}
                  />
                `,
              )}
            </div>
          `
        : query.length > 0
          ? html`<span class="text-[10px] text-[var(--text-muted)] italic">일치하는 도구 없음</span>`
          : null}

      <!-- Diff summary + apply -->
      ${hasChanges
        ? html`
            <div class="flex flex-col gap-1.5 p-2 rounded-lg border border-accent/20 bg-accent/5">
              <div class="text-[10px] text-[var(--text-muted)]">
                ${removes.length > 0
                  ? html`<span class="text-red-300">-${removes.length} 제거</span>`
                  : null}
                ${removes.length > 0 && adds.length > 0 ? ' / ' : ''}
                ${adds.length > 0
                  ? html`<span class="text-emerald-300">+${adds.length} 추가</span>`
                  : null}
              </div>
              <div class="flex gap-2">
                <button type="button"
                  class="py-1 px-3 rounded-lg text-[10px] font-medium bg-[#4ade80] text-[#000] hover:bg-[#22c55e] transition-colors cursor-pointer disabled:opacity-50"
                  onClick=${applyChanges}
                  disabled=${saving.value}
                >${saving.value ? '저장 중...' : '변경 적용'}</button>
                <button type="button"
                  class="py-1 px-3 rounded-lg text-[10px] font-medium bg-[var(--white-10)] text-[var(--text-body)] hover:bg-[var(--white-15)] transition-colors cursor-pointer"
                  onClick=${() => {
                    pendingAdds.value = []
                    pendingRemoves.value = []
                  }}
                >취소</button>
              </div>
            </div>
          `
        : null}

      ${lastError.value
        ? html`<span class="text-[10px] text-red-400">${lastError.value}</span>`
        : null}
      ${lastSuccess.value
        ? html`<span class="text-[10px] text-emerald-400">${lastSuccess.value}</span>`
        : null}
    </div>
  `
}
