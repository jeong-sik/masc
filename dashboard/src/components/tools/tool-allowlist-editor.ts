import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { editKeeperTools, type ToolEditResponse } from '../../api/keeper'

const policyMode = signal<'preset' | 'custom'>('preset')
const preset = signal<'minimal' | 'messaging' | 'coding' | 'research' | 'full'>('full')
const alsoAllowRaw = signal('')
const customAllowRaw = signal('')
const denyRaw = signal('')
const saving = signal(false)
const lastError = signal<string | null>(null)
const lastSuccess = signal<string | null>(null)

function parseToolList(raw: string): string[] {
  return Array.from(
    new Set(
      raw
        .split(/[\n,]/)
        .map(item => item.trim())
        .filter(Boolean),
    ),
  )
}

function formatToolList(values: string[] | undefined): string {
  return (values ?? []).join(', ')
}

function resetEditorState(params: {
  mode?: string | null
  preset?: string | null
  alsoAllow?: string[]
  customAllowlist?: string[]
  denylist?: string[]
}) {
  policyMode.value = params.mode === 'custom' ? 'custom' : 'preset'
  preset.value =
    params.preset === 'minimal'
    || params.preset === 'messaging'
    || params.preset === 'coding'
    || params.preset === 'research'
    || params.preset === 'full'
      ? params.preset
      : 'full'
  alsoAllowRaw.value = formatToolList(params.alsoAllow)
  customAllowRaw.value = formatToolList(params.customAllowlist)
  denyRaw.value = formatToolList(params.denylist)
  saving.value = false
  lastError.value = null
  lastSuccess.value = null
}

function ToolChip({ name }: { name: string }) {
  return html`
    <span class="inline-flex items-center py-0.5 px-2 rounded-full text-[10px] font-medium bg-[var(--accent-12)] text-[#9ad9ff] border border-[rgba(71,184,255,0.25)]">
      ${name}
    </span>
  `
}

export function ToolAllowlistEditor({
  keeperName,
  currentMode,
  currentPreset,
  currentAlsoAllow,
  currentCustomAllowlist,
  currentDenylist,
  resolvedAllowlist,
  onUpdated,
}: {
  keeperName: string
  currentMode?: string | null
  currentPreset?: string | null
  currentAlsoAllow?: string[]
  currentCustomAllowlist?: string[]
  currentDenylist?: string[]
  resolvedAllowlist: string[]
  onUpdated: (response: ToolEditResponse) => void
}) {
  useEffect(() => {
    resetEditorState({
      mode: currentMode,
      preset: currentPreset,
      alsoAllow: currentAlsoAllow,
      customAllowlist: currentCustomAllowlist,
      denylist: currentDenylist,
    })
  }, [
    keeperName,
    currentMode,
    currentPreset,
    JSON.stringify(currentAlsoAllow ?? []),
    JSON.stringify(currentCustomAllowlist ?? []),
    JSON.stringify(currentDenylist ?? []),
  ])

  async function applyChanges(): Promise<void> {
    saving.value = true
    lastError.value = null
    lastSuccess.value = null
    try {
      const response = await editKeeperTools(keeperName, {
        action: 'set_policy',
        mode: policyMode.value,
        preset: policyMode.value === 'preset' ? preset.value : undefined,
        allow: policyMode.value === 'custom' ? parseToolList(customAllowRaw.value) : undefined,
        also_allow: policyMode.value === 'preset' ? parseToolList(alsoAllowRaw.value) : undefined,
        deny: parseToolList(denyRaw.value),
      })
      if (!response.ok) {
        lastError.value = response.error ?? '알 수 없는 오류'
        return
      }
      lastSuccess.value = `${response.total_active}개 도구 활성`
      onUpdated(response)
    } catch (err) {
      lastError.value = err instanceof Error ? err.message : '요청 실패'
    } finally {
      saving.value = false
    }
  }

  return html`
    <div class="flex flex-col gap-3 mt-2 p-3 rounded-xl border border-[var(--card-border)] bg-[rgba(11,18,32,0.6)]">
      <div class="flex items-center justify-between">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">도구 정책 편집</span>
        <button
          type="button"
          class="text-[10px] text-[var(--text-muted)] hover:text-[var(--text-body)] cursor-pointer"
          onClick=${() =>
            resetEditorState({
              mode: currentMode,
              preset: currentPreset,
              alsoAllow: currentAlsoAllow,
              customAllowlist: currentCustomAllowlist,
              denylist: currentDenylist,
            })}
        >
          초기화
        </button>
      </div>

      <div class="flex gap-2">
        <button
          type="button"
          class=${`py-1 px-3 rounded-lg text-[10px] font-medium border transition-colors cursor-pointer ${policyMode.value === 'preset'
            ? 'border-[rgba(71,184,255,0.35)] bg-[rgba(71,184,255,0.16)] text-[#9ad9ff]'
            : 'border-[var(--card-border)] bg-[var(--white-3)] text-[var(--text-muted)]'}`}
          onClick=${() => { policyMode.value = 'preset' }}
        >
          preset
        </button>
        <button
          type="button"
          class=${`py-1 px-3 rounded-lg text-[10px] font-medium border transition-colors cursor-pointer ${policyMode.value === 'custom'
            ? 'border-[rgba(71,184,255,0.35)] bg-[rgba(71,184,255,0.16)] text-[#9ad9ff]'
            : 'border-[var(--card-border)] bg-[var(--white-3)] text-[var(--text-muted)]'}`}
          onClick=${() => { policyMode.value = 'custom' }}
        >
          custom
        </button>
      </div>

      ${policyMode.value === 'preset'
        ? html`
            <label class="flex flex-col gap-1">
              <span class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">preset</span>
              <select
                class="w-full px-3 py-2 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] text-[11px] text-[var(--text-body)]"
                value=${preset.value}
                onChange=${(e: Event) => { preset.value = (e.target as HTMLSelectElement).value as typeof preset.value }}
              >
                <option value="minimal">minimal</option>
                <option value="messaging">messaging</option>
                <option value="coding">coding</option>
                <option value="research">research</option>
                <option value="full">full</option>
              </select>
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">also allow</span>
              <textarea
                class="min-h-[72px] w-full px-3 py-2 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] text-[11px] text-[var(--text-body)] placeholder:text-[var(--text-muted)]"
                placeholder="추가 허용 도구를 쉼표 또는 줄바꿈으로 입력"
                value=${alsoAllowRaw.value}
                onInput=${(e: Event) => { alsoAllowRaw.value = (e.target as HTMLTextAreaElement).value }}
              />
            </label>
          `
        : html`
            <label class="flex flex-col gap-1">
              <span class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">custom allowlist</span>
              <textarea
                class="min-h-[88px] w-full px-3 py-2 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] text-[11px] text-[var(--text-body)] placeholder:text-[var(--text-muted)]"
                placeholder="허용 도구를 쉼표 또는 줄바꿈으로 입력"
                value=${customAllowRaw.value}
                onInput=${(e: Event) => { customAllowRaw.value = (e.target as HTMLTextAreaElement).value }}
              />
            </label>
          `}

      <label class="flex flex-col gap-1">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">denylist</span>
        <textarea
          class="min-h-[72px] w-full px-3 py-2 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] text-[11px] text-[var(--text-body)] placeholder:text-[var(--text-muted)]"
          placeholder="차단 도구를 쉼표 또는 줄바꿈으로 입력"
          value=${denyRaw.value}
          onInput=${(e: Event) => { denyRaw.value = (e.target as HTMLTextAreaElement).value }}
        />
      </label>

      <div class="flex flex-col gap-1">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">resolved allowlist</span>
        <div class="flex flex-wrap gap-1.5">
          ${resolvedAllowlist.length > 0
            ? resolvedAllowlist.map(name => html`<${ToolChip} name=${name} />`)
            : html`<span class="text-[11px] text-[var(--text-muted)] italic">resolved allowlist 없음</span>`}
        </div>
      </div>

      <div class="flex gap-2">
        <button
          type="button"
          class="py-1 px-3 rounded-lg text-[10px] font-medium bg-[#4ade80] text-[#000] hover:bg-[#22c55e] transition-colors cursor-pointer disabled:opacity-50"
          onClick=${applyChanges}
          disabled=${saving.value}
        >
          ${saving.value ? '저장 중...' : '정책 적용'}
        </button>
      </div>

      ${lastError.value
        ? html`<span class="text-[10px] text-red-400">${lastError.value}</span>`
        : null}
      ${lastSuccess.value
        ? html`<span class="text-[10px] text-emerald-400">${lastSuccess.value}</span>`
        : null}
    </div>
  `
}
