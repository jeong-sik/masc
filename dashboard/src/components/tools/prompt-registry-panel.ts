import { html } from 'htm/preact'
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
import { TextArea } from '../common/input'

function sourceBadgeClass(source: PromptSource): string {
  switch (source) {
    case 'override':
      return 'text-[var(--warn)] bg-[rgba(250,204,21,0.12)] border-[rgba(250,204,21,0.28)]'
    case 'file':
      return 'text-[var(--ok-20)] bg-[rgba(34,197,94,0.12)] border-[rgba(34,197,94,0.28)]'
    case 'missing':
      return 'text-[var(--bad-light)] bg-[rgba(244,63,94,0.12)] border-[rgba(244,63,94,0.28)]'
    default:
      return 'text-[var(--text-muted)] bg-[var(--white-6)] border-[var(--card-border)]'
  }
}

function normalizeDraft(prompt: DashboardPromptItem | null): string {
  if (!prompt) return ''
  return prompt.override_value ?? prompt.effective
}

export function PromptRegistryPanel() {
  const [prompts, setPrompts] = useState<DashboardPromptItem[]>([])
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [status, setStatus] = useState<string | null>(null)
  const [selectedKey, setSelectedKey] = useState<string | null>(null)
  const [draft, setDraft] = useState('')

  const selectedPrompt = prompts.find(prompt => prompt.key === selectedKey) ?? prompts[0] ?? null

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
        throw new Error(response.error ?? 'prompt override failed')
      }
      setStatus(response.message ?? 'override set')
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
      <div class="mb-4 text-[12px] text-[var(--text-muted)] leading-relaxed">
        <div>기준 원문은 <code>config/prompts/*.md</code>입니다.</div>
        <div>이 화면에서는 현재 effective 값 확인과 runtime override 적용/해제만 합니다.</div>
      </div>

      ${error ? html`<${ErrorState} message=${error} class="mb-4" />` : null}
      ${status ? html`<div class="mb-4 rounded-lg border border-[rgba(56,189,248,0.28)] bg-[rgba(56,189,248,0.08)] px-3 py-2 text-[12px] text-[#bae6fd]">${status}</div>` : null}

      <div class="grid gap-4 lg:grid-cols-[320px_minmax(0,1fr)]">
        <div class="min-h-[260px] rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] p-2">
          <div class="mb-2 flex items-center justify-between gap-2 px-2">
            <div class="text-[11px] uppercase tracking-[0.08em] text-[var(--text-muted)]">등록된 프롬프트</div>
            <${ActionButton} variant="ghost" size="sm" disabled=${loading || saving} onClick=${() => { void loadPrompts(selectedPrompt?.key ?? null) }}>
              ${loading ? '새로고침 중' : '새로고침'}
            <//>
          </div>
          <div class="flex max-h-[520px] flex-col gap-2 overflow-y-auto pr-1">
            ${prompts.map(prompt => html`
              <button
                type="button"
                class="rounded-lg border px-3 py-2 text-left transition-colors ${selectedPrompt?.key === prompt.key
                  ? 'border-[var(--accent-30)] bg-[var(--accent-10)]'
                  : 'border-[var(--card-border)] bg-[var(--white-2)] hover:bg-[var(--white-4)]'}"
                onClick=${() => {
                  setSelectedKey(prompt.key)
                  setDraft(normalizeDraft(prompt))
                  setStatus(null)
                }}
              >
                <div class="mb-1 flex items-start justify-between gap-2">
                  <div class="font-mono text-[12px] text-[var(--text-strong)]">${prompt.key}</div>
                  <span class="rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-[0.08em] ${sourceBadgeClass(prompt.source)}">${prompt.source}</span>
                </div>
                <div class="mb-1 text-[11px] text-[var(--text-muted)]">${prompt.category}</div>
                <div class="text-[12px] text-[var(--text-body)] leading-relaxed">${prompt.description}</div>
              </button>
            `)}
          </div>
        </div>

        <div class="min-w-0 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] p-4">
          ${selectedPrompt ? html`
            <div class="mb-4 flex flex-wrap items-center gap-2">
              <div class="font-mono text-[13px] text-[var(--text-strong)]">${selectedPrompt.key}</div>
              <span class="rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-[0.08em] ${sourceBadgeClass(selectedPrompt.source)}">${selectedPrompt.source}</span>
              ${selectedPrompt.has_override
                ? html`<span class="rounded-full border border-[rgba(250,204,21,0.28)] bg-[var(--warn-10)] px-2 py-0.5 text-[10px] uppercase tracking-[0.08em] text-[#fde68a]">오버라이드 활성</span>`
                : null}
            </div>

            <div class="mb-4 grid gap-3 md:grid-cols-2">
              <div class="rounded-lg border border-[var(--card-border)] bg-[var(--white-2)] px-3 py-2">
                <div class="text-[11px] uppercase tracking-[0.08em] text-[var(--text-muted)]">마크다운 파일</div>
                <div class="mt-1 break-all font-mono text-[12px] text-[var(--text-body)]">${selectedPrompt.file_path ?? '미설정'}</div>
              </div>
              <div class="rounded-lg border border-[var(--card-border)] bg-[var(--white-2)] px-3 py-2">
                <div class="text-[11px] uppercase tracking-[0.08em] text-[var(--text-muted)]">문자 수</div>
                <div class="mt-1 font-mono text-[12px] text-[var(--text-body)]">${selectedPrompt.char_count}</div>
              </div>
            </div>

            ${selectedPrompt.template_variables.length > 0 ? html`
              <div class="mb-4 rounded-lg border border-[var(--card-border)] bg-[var(--white-2)] px-3 py-2">
                <div class="text-[11px] uppercase tracking-[0.08em] text-[var(--text-muted)]">허용된 플레이스홀더</div>
                <div class="mt-2 flex flex-wrap gap-2">
                  ${selectedPrompt.template_variables.map(variable => html`
                    <span class="rounded-full border border-[var(--card-border)] bg-[var(--white-4)] px-2 py-0.5 font-mono text-[11px] text-[var(--text-body)]">${`{{${variable}}}`}</span>
                  `)}
                </div>
              </div>
            ` : null}

            <div class="mb-4">
              <div class="mb-2 text-[11px] uppercase tracking-[0.08em] text-[var(--text-muted)]">파일 기준값</div>
              <div class="max-h-[220px] overflow-auto rounded-lg border border-[var(--card-border)] bg-[var(--bg-0)] custom-scrollbar"><${Markdown} text=${'```markdown\n' + (selectedPrompt.file_value ?? '없음') + '\n```'} /></div>
            </div>

            <div class="mb-2 flex items-center justify-between gap-2">
              <div class="text-[11px] uppercase tracking-[0.08em] text-[var(--text-muted)]">런타임 오버라이드</div>
              <div class="text-[11px] text-[var(--text-muted)]">저장 후 effective 미리보기가 오버라이드를 반영합니다</div>
            </div>
            <${TextArea}
              rows=${18}
              value=${draft}
              class="min-h-[320px] font-mono text-[12px]"
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
            <div class="rounded-lg border border-dashed border-[var(--card-border)] px-4 py-10 text-center text-[12px] text-[var(--text-muted)]">
              ${loading ? '프롬프트 목록을 불러오는 중입니다.' : '표시할 프롬프트가 없습니다.'}
            </div>
          `}
        </div>
      </div>
    <//>
  `
}
