import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { Markdown } from "../common/markdown"
import { useEffect, useMemo, useState } from 'preact/hooks'
import {
  clearPromptOverride,
  fetchDashboardPrompts,
  savePromptOverride,
  type DashboardPromptItem,
  type PromptSource,
} from '../../api'
import { SectionCard } from '../common/card'
import { ErrorState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import { TextArea, TextInput } from '../common/input'
import { FilterChips } from '../common/filter-chips'
import { StatusChip } from '../common/status-chip'
import { errorToString } from '../../lib/format-string'
import {
  buildKeeperPromptAssemblyReport,
  KeeperPromptAssemblyPanel,
  type KeeperPromptAssemblyReport,
  type KeeperPromptAssemblyRow,
  type KeeperPromptAssemblyStage,
} from '../keeper-prompt-assembly-panel'
import { PromptBookPanel } from './prompt-book-panel'

export type PromptSourceFilter = 'all' | PromptSource
export type PromptPresetId = 'all' | 'attention' | `stage:${string}`

export interface PromptPreset {
  id: PromptPresetId
  label: string
  description: string
  count: number
}

export interface PromptDestination {
  stageTitle: string
  messageSlot: string
  role: KeeperPromptAssemblyStage['role']
  summary: string
}

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

const STAGE_PRESET_PREFIX = 'stage:'
const COMPUTED_PROMPT_SOURCE: KeeperPromptAssemblyRow['source'] = 'computed'
const NOT_SENT_MESSAGE_SLOT = 'not sent'
const MODEL_INPUT_STAGE_ROLE: KeeperPromptAssemblyStage['role'] = 'model_input'

function stagePresetId(preset: PromptPresetId): string | null {
  if (preset === 'all' || preset === 'attention') return null
  return preset.slice(STAGE_PRESET_PREFIX.length)
}

function promptAssemblyRows(stage: KeeperPromptAssemblyStage): KeeperPromptAssemblyRow[] {
  return stage.rows.filter(row => row.source !== COMPUTED_PROMPT_SOURCE)
}

function promptPresetRows(report: KeeperPromptAssemblyReport, preset: PromptPresetId): Set<string> | null {
  const stageId = stagePresetId(preset)
  if (!stageId) return null
  const stage = report.stages.find(item => item.id === stageId)
  if (!stage) return new Set()
  return new Set(promptAssemblyRows(stage).map(row => row.promptKey))
}

function stagePresetLabel(stage: KeeperPromptAssemblyStage): string {
  if (stage.messageSlot === NOT_SENT_MESSAGE_SLOT) return stage.title
  return `${stage.messageSlot}: ${stage.title}`
}

function isModelInputDestination(destination: PromptDestination): boolean {
  return destination.role === MODEL_INPUT_STAGE_ROLE
}

function presetPromptCount(
  prompts: DashboardPromptItem[],
  report: KeeperPromptAssemblyReport,
  preset: PromptPresetId,
): number {
  if (preset === 'all') return prompts.length
  if (preset === 'attention') {
    return prompts.filter(prompt => prompt.has_override || prompt.source === 'missing').length
  }
  const allowed = promptPresetRows(report, preset)
  if (!allowed || allowed.size === 0) return 0
  return prompts.filter(prompt => allowed.has(prompt.key)).length
}

export function promptPresetOptions(
  prompts: DashboardPromptItem[],
  report: KeeperPromptAssemblyReport,
): PromptPreset[] {
  const stagePresets = report.stages
    .filter(stage => promptAssemblyRows(stage).length > 0)
    .map(stage => {
      const id: PromptPresetId = `${STAGE_PRESET_PREFIX}${stage.id}`
      const stagePromptKeys = new Set(promptAssemblyRows(stage).map(row => row.promptKey))
      return {
        id,
        label: stagePresetLabel(stage),
        description: stage.summary,
        count: prompts.filter(prompt => stagePromptKeys.has(prompt.key)).length,
      }
    })

  return [
    {
      id: 'all',
      label: '전체',
      description: '등록된 모든 프롬프트 파일과 오버라이드.',
      count: prompts.length,
    },
    ...stagePresets,
    {
      id: 'attention',
      label: '수정/누락',
      description: '저장된 오버라이드와 누락된 필수 프롬프트 파일.',
      count: presetPromptCount(prompts, report, 'attention'),
    },
  ]
}

export function promptDestinationsForKey(
  report: KeeperPromptAssemblyReport,
  key: string,
): PromptDestination[] {
  return report.stages
    .filter(stage => stage.rows.some(row => row.promptKey === key))
    .map(stage => ({
      stageTitle: stage.title,
      messageSlot: stage.messageSlot,
      role: stage.role,
      summary: stage.summary,
    }))
}

function normalizeDraft(prompt: DashboardPromptItem | null): string {
  if (!prompt) return ''
  return prompt.override_value ?? prompt.effective
}

function draftKeyForPrompt(prompt: DashboardPromptItem | null): string | null {
  return prompt?.key ?? null
}

// Pure helper: filter by source + substring search (case-insensitive).
// Exported for unit testing.
export function filterPrompts(
  prompts: DashboardPromptItem[],
  source: PromptSourceFilter,
  query: string,
  report: KeeperPromptAssemblyReport,
  preset: PromptPresetId = 'all',
): DashboardPromptItem[] {
  const q = query.trim().toLowerCase()
  const allowedPromptKeys =
    preset !== 'all' && preset !== 'attention'
      ? promptPresetRows(report, preset)
      : null
  return prompts.filter(p => {
    if (preset === 'attention' && !p.has_override && p.source !== 'missing') return false
    if (allowedPromptKeys && !allowedPromptKeys.has(p.key)) return false
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

export function PromptRegistryPanel({ embedded = false }: { embedded?: boolean } = {}) {
  const sourceFilter = useSignal<PromptSourceFilter>('all')
  const searchQuery = useSignal('')
  const [prompts, setPrompts] = useState<DashboardPromptItem[]>([])
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [status, setStatus] = useState<string | null>(null)
  const [selectedKey, setSelectedKey] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  const [draftPromptKey, setDraftPromptKey] = useState<string | null>(null)
  const [preset, setPreset] = useState<PromptPresetId>('all')
  // '레지스트리' = the existing effective/override editor; '라이브러리' = the
  // read-only curated prompt-library catalog (PromptBookPanel). Defaults to the
  // editor so the registry stays the landing view.
  const [surfaceView, setSurfaceView] = useState<'registry' | 'book'>('registry')

  const report = useMemo(() => buildKeeperPromptAssemblyReport(prompts), [prompts])
  const presets = promptPresetOptions(prompts, report)
  const activePreset = presets.some(item => item.id === preset) ? preset : 'all'
  const visiblePrompts = filterPrompts(prompts, sourceFilter.value, searchQuery.value, report, activePreset)
  const selectedPromptFromKey = selectedKey ? prompts.find(prompt => prompt.key === selectedKey) ?? null : null
  const selectedPromptVisible = selectedPromptFromKey
    ? visiblePrompts.some(prompt => prompt.key === selectedPromptFromKey.key)
    : false
  const selectedPrompt = selectedPromptFromKey ?? visiblePrompts[0] ?? null
  const selectedDestinations = selectedPrompt ? promptDestinationsForKey(report, selectedPrompt.key) : []
  const counts = promptSourceCounts(prompts)
  const draftDirty = selectedPrompt
    ? draftPromptKey === selectedPrompt.key
      ? draft !== normalizeDraft(selectedPrompt)
      : draft.length > 0
    : draft.length > 0

  function setDraftForPrompt(prompt: DashboardPromptItem | null) {
    setDraft(normalizeDraft(prompt))
    setDraftPromptKey(draftKeyForPrompt(prompt))
  }

  // Depend on the first visible prompt's stable key (a string) rather than the
  // freshly-allocated [visiblePrompts] array, which changes identity every
  // render (filterPrompts returns a new array) and would otherwise schedule
  // this effect after every render/keystroke. [prompts] is stable useState
  // identity, so re-selection only fires when the fallback target actually
  // changes.
  const firstVisibleKey = visiblePrompts[0]?.key ?? null

  useEffect(() => {
    if (draftDirty || selectedPromptVisible) return
    if (selectedKey === firstVisibleKey) return
    const nextPrompt = firstVisibleKey
      ? prompts.find(prompt => prompt.key === firstVisibleKey) ?? null
      : null
    setSelectedKey(firstVisibleKey)
    setDraftForPrompt(nextPrompt)
    setStatus(null)
  }, [draftDirty, selectedKey, selectedPromptVisible, firstVisibleKey, prompts])

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
      setDraftForPrompt(nextPrompt)
    } catch (err) {
      setStatus(null)
      setError(errorToString(err))
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    void loadPrompts()
  }, [])

  useEffect(() => {
    const nextDraftPromptKey = draftKeyForPrompt(selectedPrompt)
    if (draftPromptKey === nextDraftPromptKey) return
    setDraft(normalizeDraft(selectedPrompt))
    setDraftPromptKey(nextDraftPromptKey)
  }, [selectedPrompt, draftPromptKey])

  function confirmDiscardDraft(nextPrompt: DashboardPromptItem): boolean {
    if (!selectedPrompt || nextPrompt.key === selectedPrompt.key || !draftDirty) return true
    if (typeof window === 'undefined' || typeof window.confirm !== 'function') return false
    return window.confirm('저장하지 않은 override 초안을 버리고 다른 프롬프트를 열까요?')
  }

  function selectPrompt(prompt: DashboardPromptItem) {
    if (!confirmDiscardDraft(prompt)) return
    setSelectedKey(prompt.key)
    setDraftForPrompt(prompt)
    setStatus(null)
  }

  async function applyOverride() {
    if (!selectedPrompt) return
    if (draftPromptKey !== selectedPrompt.key) {
      setError('선택된 프롬프트가 바뀌어 초안을 다시 동기화했습니다. 내용을 확인한 뒤 다시 저장하세요.')
      setStatus(null)
      setDraftForPrompt(selectedPrompt)
      return
    }
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
      setError(errorToString(err))
    } finally {
      setSaving(false)
    }
  }

  async function clearOverride() {
    if (!selectedPrompt) return
    if (draftPromptKey !== selectedPrompt.key) setDraftForPrompt(selectedPrompt)
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
      setError(errorToString(err))
    } finally {
      setSaving(false)
    }
  }

  const body = html`
      <div class="mb-4 text-xs text-[var(--color-fg-muted)] leading-relaxed">
        <div>기준 원문은 resolved config root의 <code>prompts/*.md</code>입니다. 경로는 설정 경로 상세 패널에서 확인할 수 있습니다.</div>
        <div>이 화면에서는 현재 effective 값 확인과 runtime override 적용/해제만 합니다.</div>
      </div>

      <div class="mb-4 grid gap-2 md:grid-cols-4" data-prompt-registry-summary>
        <div class="v2-lab-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
          <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">registered</div>
          <div class="mt-1 font-mono text-sm text-[var(--color-fg-primary)]">${prompts.length}</div>
        </div>
        <div class="v2-lab-card rounded-[var(--r-1)] border border-[var(--warn-border)] bg-[var(--warn-soft)] px-3 py-2">
          <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">overrides</div>
          <div class="mt-1 font-mono text-sm text-[var(--color-fg-primary)]">${report.stats.overrideRows}</div>
        </div>
        <div class="v2-lab-card rounded-[var(--r-1)] border border-[var(--err-border)] bg-[var(--bad-soft)] px-3 py-2">
          <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">missing</div>
          <div class="mt-1 font-mono text-sm text-[var(--color-fg-primary)]">${report.stats.missingRows}</div>
        </div>
        <div class="v2-lab-card min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
          <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">prompt root</div>
          <div class="mt-1 truncate font-mono text-xs text-[var(--color-fg-primary)]" title=${report.activePromptRoots[0] ?? ''}>
            ${report.activePromptRoots[0] ?? '—'}
          </div>
        </div>
      </div>

      <${KeeperPromptAssemblyPanel}
        prompts=${prompts}
        activePreset=${activePreset}
        presets=${presets}
        onPresetChange=${(id: string) => {
          setPreset(id as PromptPresetId)
          setStatus(null)
        }}
      />

      ${error ? html`<${ErrorState} message=${error} class="mb-4" />` : null}
      ${status ? html`<div class="v2-lab-panel mb-4 rounded-[var(--r-1)] border border-[var(--sky-28)] bg-[var(--sky-8)] px-3 py-2 text-xs text-[var(--sky-light)]">${status}</div>` : null}

      <div class="grid gap-4 lg:grid-cols-[320px_minmax(0,1fr)]">
        <div class="v2-lab-panel min-h-65 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-2">
          <div class="mb-2 flex items-center justify-between gap-2 px-2">
            <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
              등록된 프롬프트
              ${activePreset !== 'all' || sourceFilter.value !== 'all' || searchQuery.value
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
              <div class="v2-lab-card rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] px-3 py-6 text-center text-2xs text-[var(--color-fg-muted)]">
                조건에 맞는 프롬프트가 없습니다.
              </div>
            ` : null}
            ${visiblePrompts.map(prompt => html`
              <button
                type="button"
                class="v2-lab-row rounded-[var(--r-1)] border px-3 py-2 text-left transition-colors ${selectedPrompt?.key === prompt.key
                  ? 'border-[var(--accent-30)] bg-[var(--accent-10)]'
                  : 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)] hover:bg-[var(--color-bg-elevated)]'}"
                onClick=${() => {
                  selectPrompt(prompt)
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

        <div class="v2-lab-panel min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4">
          ${selectedPrompt ? html`
            <div class="mb-4 flex flex-wrap items-center gap-2">
              <div class="font-mono text-sm text-[var(--color-fg-secondary)]">${selectedPrompt.key}</div>
              <${StatusChip} tone=${sourceBadgeClass(selectedPrompt.source)}>${selectedPrompt.source}<//>
              ${selectedPrompt.has_override
                ? html`<${StatusChip} tone="warn">오버라이드 활성<//>`
                : null}
            </div>

            <div class="mb-4 grid gap-3 md:grid-cols-2">
              <div class="v2-lab-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
                <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">마크다운 파일</div>
                <div class="mt-1 break-all font-mono text-xs text-[var(--color-fg-primary)]">${selectedPrompt.file_path ?? '미설정'}</div>
              </div>
              <div class="v2-lab-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
                <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">문자 수</div>
                <div class="mt-1 font-mono text-xs text-[var(--color-fg-primary)]">${selectedPrompt.char_count}</div>
              </div>
            </div>

            <div class="v2-lab-card mb-4 rounded-[var(--r-1)] border border-[var(--accent-22)] bg-[var(--accent-8)] px-3 py-2" data-prompt-destinations>
              <div class="mb-2 flex flex-wrap items-center gap-2">
                <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">들어가는 위치</div>
                ${selectedDestinations.length === 0 ? html`<${StatusChip} tone="neutral">not in keeper recipe<//>` : null}
              </div>
              ${selectedDestinations.length === 0 ? html`
                <div class="text-xs leading-relaxed text-[var(--color-fg-muted)]">
                  이 프롬프트는 registry에는 있지만 keeper turn prompt recipe의 고정 단계에는 포함되지 않습니다.
                </div>
              ` : html`
                <div class="grid gap-2">
                  ${selectedDestinations.map(destination => html`
                    <div class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-2">
                      <div class="mb-1 flex flex-wrap items-center gap-2">
                        <${StatusChip} tone=${isModelInputDestination(destination) ? 'info' : 'neutral'} uppercase=${false}>${destination.messageSlot}<//>
                        <span class="text-xs font-semibold text-[var(--color-fg-primary)]">${destination.stageTitle}</span>
                      </div>
                      <div class="text-2xs leading-relaxed text-[var(--color-fg-muted)]">${destination.summary}</div>
                    </div>
                  `)}
                </div>
              `}
            </div>

            ${selectedPrompt.template_variables.length > 0 ? html`
              <div class="v2-lab-card mb-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
                <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">허용된 플레이스홀더</div>
                <div class="mt-1 text-2xs leading-relaxed text-[var(--color-fg-muted)]">
                  값 치환은 registry render 호출자가 공급하며, 치환된 텍스트는 위 위치로 그대로 들어갑니다.
                </div>
                <div class="mt-2 grid gap-2 sm:grid-cols-2">
                  ${selectedPrompt.template_variables.map(variable => html`
                    <div class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5">
                      <div class="font-mono text-2xs text-[var(--color-fg-primary)]">${`{{${variable}}}`}</div>
                      <div class="mt-0.5 text-3xs text-[var(--color-fg-muted)]">${selectedDestinations.length > 0 ? `${selectedDestinations.length} prompt recipe slot(s)` : 'registry render variable'}</div>
                    </div>
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
                setDraftForPrompt(selectedPrompt)
                setStatus(null)
              }}>
                초안 초기화
              <//>
            </div>
          ` : html`
            <div class="v2-lab-card rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] px-4 py-10 text-center text-xs text-[var(--color-fg-muted)]">
              ${loading ? '프롬프트 목록을 불러오는 중입니다.' : '표시할 프롬프트가 없습니다.'}
            </div>
          `}
        </div>
      </div>
  `

  const viewTabs = html`
    <div class="mb-4 flex gap-1" role="tablist" data-prompt-view-switcher>
      <button
        type="button"
        role="tab"
        aria-selected=${surfaceView === 'registry'}
        class=${`rounded-[var(--r-0)] border px-3 py-1.5 text-xs ${
          surfaceView === 'registry'
            ? 'border-[var(--accent-22)] bg-[var(--accent-8)] text-[var(--color-fg-primary)]'
            : 'border-[var(--color-border-default)] text-[var(--color-fg-muted)]'
        }`}
        onClick=${() => setSurfaceView('registry')}
      >레지스트리</button>
      <button
        type="button"
        role="tab"
        aria-selected=${surfaceView === 'book'}
        class=${`rounded-[var(--r-0)] border px-3 py-1.5 text-xs ${
          surfaceView === 'book'
            ? 'border-[var(--accent-22)] bg-[var(--accent-8)] text-[var(--color-fg-primary)]'
            : 'border-[var(--color-border-default)] text-[var(--color-fg-muted)]'
        }`}
        onClick=${() => setSurfaceView('book')}
      >라이브러리</button>
    </div>
  `

  const content = html`
    ${viewTabs}
    ${surfaceView === 'book'
      ? html`<div class="set-promptbook-host"><${PromptBookPanel} prompts=${prompts} loading=${loading} /></div>`
      : body}
  `

  if (embedded) {
    return html`<div class="prompt-registry-panel prompt-registry-panel-embedded" data-testid="prompt-registry-panel">${content}</div>`
  }

  return html`
    <${SectionCard} label="프롬프트 레지스트리" class="section mb-4">
      <div data-testid="prompt-registry-panel">${content}</div>
    <//>
  `
}
