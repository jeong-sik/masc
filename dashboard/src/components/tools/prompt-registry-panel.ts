import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Markdown } from "../common/markdown"
import { useEffect, useState } from 'preact/hooks'
import {
  clearPromptOverride,
  fetchDashboardPrompts,
  savePromptOverride,
  type DashboardPromptItem,
  type PromptSource,
} from '../../api'
import { Card } from '../common/card'
import { ErrorState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import { TextArea, TextInput } from '../common/input'
import { FilterChips } from '../common/filter-chips'
import { StatusChip } from '../common/status-chip'

type PromptSourceFilter = 'all' | PromptSource

const SOURCE_CHIP_ORDER: PromptSourceFilter[] = ['all', 'file', 'override', 'default', 'missing']

const SOURCE_LABELS: Record<PromptSourceFilter, string> = {
  all: '전체',
  file: '파일',
  override: '오버라이드',
  default: '기본값',
  missing: '누락',
}

function sourceBadgeClass(source: PromptSource): string {
  switch (source) {
    case 'override':
      return 'text-[var(--color-status-warn)] bg-[var(--warn-soft)] border-[var(--warn-border)]'
    case 'file':
      return 'text-[var(--ok-20)] bg-[var(--emerald-12)] border-[var(--emerald-28)]'
    case 'missing':
      return 'text-[var(--bad-light)] bg-[var(--bad-soft)] border-[var(--err-border)]'
    default:
      return 'text-[var(--color-fg-muted)] bg-[var(--color-bg-hover)] border-[var(--color-border-default)]'
  }
}

function normalizeDraft(prompt: DashboardPromptItem | null): string {
  if (!prompt) return ''
  return prompt.override_value ?? prompt.effective
}

// Pure helper: filter by source + substring search (case-insensitive).
// Exported for unit testing.
function filterPrompts(
  prompts: DashboardPromptItem[],
  source: PromptSourceFilter,
  query: string,
): DashboardPromptItem[] {
  const q = query.trim().toLowerCase()
  return prompts.filter(p => {
    if (source !== 'all' && p.source !== source) return false
    if (!q) return true
    return (
      p.key.toLowerCase().includes(q) ||
      p.category.toLowerCase().includes(q) ||
      p.description.toLowerCase().includes(q)
    )
  })
}

// Exported for unit testing.
export function promptSourceCounts(
  prompts: DashboardPromptItem[],
): Record<PromptSourceFilter, number> {
  const counts: Record<PromptSourceFilter, number> = {
    all: prompts.length,
    file: 0,
    override: 0,
    default: 0,
    missing: 0,
  }
  for (const p of prompts) counts[p.source] += 1
  return counts
}

const sourceFilter = signal<PromptSourceFilter>('all')
const searchQuery = signal('')

export function PromptRegistryPanel() {
  const [prompts, setPrompts] = useState<DashboardPromptItem[]>([])
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [status, setStatus] = useState<string | null>(null)
  const [selectedKey, setSelectedKey] = useState<string | null>(null)
  const [draft, setDraft] = useState('')

  const visiblePrompts = filterPrompts(prompts, sourceFilter.value, searchQuery.value)
  const selectedPrompt = prompts.find(prompt => prompt.key === selectedKey) ?? prompts[0] ?? null
  const counts = promptSourceCounts(prompts)

  async function loadPrompts(preferredKey?: string | null) {
    setLoading(true)
    setError(null)
    try {
      const response = await fetchDashboardPrompts()
      const nextPrompts = response.prompts ?? []
      setPrompts(nextPrompts)
      const nextSelectedKey =
        preferredKey && nextPrompts.some(prompt => prompt.key === preferredKey)
          ? preferredKey
          : nextPrompts[0]?.key ?? null
      setSelectedKey(nextSelectedKey)
      const nextPrompt = nextPrompts.find(prompt => prompt.key === nextSelectedKey) ?? nextPrompts[0] ?? null
      setDraft(normalizeDraft(nextPrompt))
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    void loadPrompts()
  }, [])

  useEffect(() => {
    if (!selectedPrompt) return
    setDraft(current => (current === '' ? normalizeDraft(selectedPrompt) : current))
  }, [selectedPrompt?.key])

  async function applyOverride() {
    if (!selectedPrompt) return
    setSaving(true)
    setError(null)
    setStatus(null)
    try {
      const response = await savePromptOverride(selectedPrompt.key, draft)
      if (!response.ok) {
        throw new Error(response.error ?? 'prompt override 실패')
      }
      setStatus(response.message ?? 'override 설정됨')
      await loadPrompts(selectedPrompt.key)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setSaving(false)
    }
  }

  async function clearOverride() {
    if (!selectedPrompt) return
    setSaving(true)
    setError(null)
    setStatus(null)
    try {
      const response = await clearPromptOverride(selectedPrompt.key)
      if (!response.ok) {
        throw new Error(response.error ?? 'prompt override clear failed')
      }
      setStatus(response.message ?? 'override cleared')
      await loadPrompts(selectedPrompt.key)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setSaving(false)
    }
  }

  return html`
    <${Card} title="프롬프트 레지스트리" class="section mb-4">
      <div class="mb-4 text-xs text-[var(--color-fg-muted)] leading-relaxed">
        <div>기준 원문은 resolved config root의 <code>prompts/*.md</code>입니다. 경로는 설정 경로 상세 패널에서 확인할 수 있습니다.</div>
        <div>이 화면에서는 현재 effective 값 확인과 runtime override 적용/해제만 합니다.</div>
      </div>

      ${error ? html`<${ErrorState} message=${error} class="mb-4" />` : null}
      ${status ? html`<div class="mb-4 rounded-[var(--r-1)] border border-[var(--sky-28)] bg-[var(--sky-8)] px-3 py-2 text-xs text-[var(--sky-light)]">${status}</div>` : null}

      <div class="grid gap-4 lg:grid-cols-[320px_minmax(0,1fr)]">
        <div class="min-h-65 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-2">
          <div class="mb-2 flex items-center justify-between gap-2 px-2">
            <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
              등록된 프롬프트
              ${sourceFilter.value !== 'all' || searchQuery.value
                ? html`<span class="ml-1 normal-case tracking-normal text-[var(--color-fg-muted)]">${visiblePrompts.length} / ${prompts.length}</span>`
                : null}
            </div>
            <${ActionButton} variant="ghost" size="sm" disabled=${loading || saving} onClick=${() => { void loadPrompts(selectedPrompt?.key ?? null) }}>
              ${loading ? '새로고침 중' : '새로고침'}
            <//>
          </div>
          <div class="mb-2 px-2">
            <${FilterChips}
              chips=${SOURCE_CHIP_ORDER.map(key => ({
                key,
                label: SOURCE_LABELS[key],
                count: counts[key],
              }))}
              active=${sourceFilter}
            />
          </div>
          <div class="mb-2 px-2">
            <${TextInput}
              placeholder="key / category / 설명 검색"
              ariaLabel="프롬프트 검색"
              value=${searchQuery.value}
              onInput=${(e: Event) => { searchQuery.value = (e.target as HTMLInputElement).value }}
            />
          </div>
          <div class="flex max-h-130 flex-col gap-2 overflow-y-auto pr-1">
            ${visiblePrompts.length === 0 ? html`
              <div class="rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] px-3 py-6 text-center text-2xs text-[var(--color-fg-muted)]">
                조건에 맞는 프롬프트가 없습니다.
              </div>
            ` : null}
            ${visiblePrompts.map(prompt => html`
              <button
                type="button"
                class="rounded-[var(--r-1)] border px-3 py-2 text-left transition-colors ${selectedPrompt?.key === prompt.key
                  ? 'border-[var(--accent-30)] bg-[var(--accent-10)]'
                  : 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)] hover:bg-[var(--color-bg-elevated)]'}"
                onClick=${() => {
                  setSelectedKey(prompt.key)
                  setDraft(normalizeDraft(prompt))
                  setStatus(null)
                }}
              >
                <div class="mb-1 flex items-start justify-between gap-2">
                  <div class="font-mono text-xs text-[var(--color-fg-secondary)]">${prompt.key}</div>
                  <${StatusChip} tone=${sourceBadgeClass(prompt.source)}>${prompt.source}<//>
                </div>
                <div class="mb-1 text-2xs text-[var(--color-fg-muted)]">${prompt.category}</div>
                <div class="text-xs text-[var(--color-fg-primary)] leading-relaxed">${prompt.description}</div>
              </button>
            `)}
          </div>
        </div>

        <div class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4">
          ${selectedPrompt ? html`
            <div class="mb-4 flex flex-wrap items-center gap-2">
              <div class="font-mono text-sm text-[var(--color-fg-secondary)]">${selectedPrompt.key}</div>
              <${StatusChip} tone=${sourceBadgeClass(selectedPrompt.source)}>${selectedPrompt.source}<//>
              ${selectedPrompt.has_override
                ? html`<${StatusChip} tone="warn">오버라이드 활성<//>`
                : null}
            </div>

            <div class="mb-4 grid gap-3 md:grid-cols-2">
              <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
                <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">마크다운 파일</div>
                <div class="mt-1 break-all font-mono text-xs text-[var(--color-fg-primary)]">${selectedPrompt.file_path ?? '미설정'}</div>
              </div>
              <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
                <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">문자 수</div>
                <div class="mt-1 font-mono text-xs text-[var(--color-fg-primary)]">${selectedPrompt.char_count}</div>
              </div>
            </div>

            ${selectedPrompt.template_variables.length > 0 ? html`
              <div class="mb-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
                <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">허용된 플레이스홀더</div>
                <div class="mt-2 flex flex-wrap gap-2">
                  ${selectedPrompt.template_variables.map(variable => html`
                    <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5 font-mono text-2xs text-[var(--color-fg-primary)]">${`{{${variable}}}`}</span>
                  `)}
                </div>
              </div>
            ` : null}

            <div class="mb-4">
              <div class="mb-2 text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">파일 기준값</div>
              <div class="max-h-55 overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] custom-scrollbar"><${Markdown} text=${'```markdown\n' + (selectedPrompt.file_value ?? '없음') + '\n```'} /></div>
            </div>

            <div class="mb-2 flex items-center justify-between gap-2">
              <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">런타임 오버라이드</div>
              <div class="text-2xs text-[var(--color-fg-muted)]">저장 후 effective 미리보기가 오버라이드를 반영합니다</div>
            </div>
            <${TextArea}
              rows=${18}
              value=${draft}
              class="min-h-80 font-mono text-xs"
              onInput=${(event: Event) => {
                setDraft((event.target as HTMLTextAreaElement).value)
                setStatus(null)
              }}
            />

            <div class="mt-4 flex flex-wrap gap-2">
              <${ActionButton} variant="primary" size="md" disabled=${saving || loading || draft.trim().length === 0} onClick=${() => { void applyOverride() }}>
                ${saving ? '저장 중...' : '오버라이드 적용'}
              <//>
              <${ActionButton} variant="ghost" size="md" disabled=${saving || loading || !selectedPrompt.has_override} onClick=${() => { void clearOverride() }}>
                오버라이드 제거
              <//>
              <${ActionButton} variant="ghost" size="md" disabled=${saving || loading} onClick=${() => {
                setDraft(normalizeDraft(selectedPrompt))
                setStatus(null)
              }}>
                초안 초기화
              <//>
            </div>
          ` : html`
            <div class="rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] px-4 py-10 text-center text-xs text-[var(--color-fg-muted)]">
              ${loading ? '프롬프트 목록을 불러오는 중입니다.' : '표시할 프롬프트가 없습니다.'}
            </div>
          `}
        </div>
      </div>
    <//>
  `
}
