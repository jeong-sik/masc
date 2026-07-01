import { html } from 'htm/preact'
import { Copy, RefreshCcw, RotateCcw, Save } from 'lucide-preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  fetchRuntimeTomlConfig,
  patchRuntimeAssignment,
  patchRuntimeRouting,
  saveRuntimeTomlConfig,
  type RuntimeTomlConfig,
  type RuntimeRoutingLane,
} from '../api/dashboard'
import { errorToString } from '../lib/format-string'
import {
  createRuntimeTomlBinding,
  parseRuntimeTomlEnvironment,
  runtimeTomlImpactSummary,
  setRuntimeTomlBindingField,
  setRuntimeTomlModelField,
  setRuntimeTomlProviderCredential,
  setRuntimeTomlProviderField,
  type RuntimeTomlImpactSummary,
} from '../lib/runtime-toml-config'
import { ActionButton } from './common/button'
import { SectionCard } from './common/card'
import { copyToClipboard } from './common/copyable-code'
import { ErrorState, LoadingState } from './common/feedback-state'
import { ringFocusClasses } from './common/ring'
import {
  RuntimeEnvironmentEditor,
  type NewRuntimeModelInput,
  type NewRuntimeProviderInput,
  type RuntimeBindingEditableField,
  type RuntimeStructuredSection,
} from './runtime-environment-editor'

type LoadState = 'idle' | 'loading' | 'loaded'

interface RuntimeTomlDraftStats {
  readonly lineCount: number
  readonly charCount: number
}

function runtimeTomlStatusLabel(
  loadState: LoadState,
  dirty: boolean,
  saving: boolean,
): string {
  if (saving) return 'saving'
  if (loadState === 'loading') return 'loading'
  if (dirty) return 'modified'
  if (loadState === 'loaded') return 'saved'
  return 'idle'
}

function runtimeTomlDraftStats(sourceText: string): RuntimeTomlDraftStats {
  return {
    lineCount: sourceText.length === 0 ? 1 : sourceText.split('\n').length,
    charCount: sourceText.length,
  }
}

function runtimeTomlLineNumbers(lineCount: number): string {
  return Array.from({ length: lineCount }, (_, index) => String(index + 1)).join('\n')
}

function signedDelta(value: number): string {
  if (value > 0) return `+${value}`
  return String(value)
}

function runtimeLabel(value: string): string {
  return value.trim() || 'unset'
}

function RuntimeTomlImpactPreview({ impact }: { impact: RuntimeTomlImpactSummary }) {
  const catalogDelta =
    impact.providerCountDelta !== 0 || impact.modelCountDelta !== 0 || impact.bindingCountDelta !== 0

  return html`
    <div
      class="mt-2 flex flex-wrap items-center gap-2 border-t border-[var(--color-border-subtle)] pt-2 text-2xs text-[var(--color-fg-muted)]"
      data-testid="runtime-toml-impact-preview"
    >
      <span class="uppercase tracking-[var(--track-caps)] text-[var(--color-fg-secondary)]">적용 미리보기</span>
      <span
        class="rounded-[var(--r-0)] border border-[var(--color-border-subtle)] px-2 py-0.5 font-mono"
        data-testid="runtime-toml-default-impact"
      >
        default ${impact.defaultRuntimeChanged
          ? `${runtimeLabel(impact.defaultRuntimeBefore)} -> ${runtimeLabel(impact.defaultRuntimeAfter)}`
          : 'unchanged'}
      </span>
      <span
        class="rounded-[var(--r-0)] border border-[var(--color-border-subtle)] px-2 py-0.5"
        data-testid="runtime-toml-assignments-impact"
      >
        assignments ${impact.runtimeAssignmentsChanged ? 'changed' : 'unchanged'}
      </span>
      <span class="rounded-[var(--r-0)] border border-[var(--color-border-subtle)] px-2 py-0.5">
        lines ${signedDelta(impact.lineDelta)}
      </span>
      <span class="rounded-[var(--r-0)] border border-[var(--color-border-subtle)] px-2 py-0.5">
        chars ${signedDelta(impact.charDelta)}
      </span>
      <span
        class="rounded-[var(--r-0)] border border-[var(--color-border-subtle)] px-2 py-0.5"
        data-testid="runtime-toml-catalog-impact"
      >
        catalog ${catalogDelta
          ? `p${signedDelta(impact.providerCountDelta)} m${signedDelta(impact.modelCountDelta)} b${signedDelta(impact.bindingCountDelta)}`
          : 'unchanged'}
      </span>
    </div>
  `
}

const editorFocusClasses = ringFocusClasses({
  tone: 'accent-medium',
  width: 2,
  offset: 0,
})

// rt-* shell section nav. Section ids + Korean labels + glyphs are lifted 1:1
// from the Claude-Design prototype runtime-editor.jsx:8-15 (RT_SECS). The
// glyphs are the prototype's exact characters — do not substitute lucide icons,
// the prototype uses these literal glyphs.
type RuntimeSectionId =
  | 'routing'
  | 'providers'
  | 'models'
  | 'bindings'
  | 'assignments'
  | 'toml'

interface RuntimeSection {
  readonly id: RuntimeSectionId
  readonly label: string
  readonly glyph: string
}

const RUNTIME_SECTIONS: readonly RuntimeSection[] = [
  { id: 'routing', label: '라우팅', glyph: '◷' },
  { id: 'providers', label: '프로바이더', glyph: '◇' },
  { id: 'models', label: '모델', glyph: '▤' },
  { id: 'bindings', label: '바인딩 · 런타임 id', glyph: '◈' },
  { id: 'assignments', label: 'keeper 배정', glyph: '⊙' },
  { id: 'toml', label: 'runtime.toml', glyph: '{ }' },
]

function runtimeSectionTitle(sec: RuntimeSectionId): string {
  return RUNTIME_SECTIONS.find(s => s.id === sec)?.label ?? ''
}

function runtimeStatusToneClass(statusLabel: string): string {
  if (statusLabel === 'modified' || statusLabel === 'saving') return 'is-modified'
  if (statusLabel === 'saved') return 'is-saved'
  return ''
}

export interface RuntimeTomlEditorProps {
  onClose?: () => void
}

export function RuntimeTomlEditor({ onClose }: RuntimeTomlEditorProps = {}) {
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const lineGutterRef = useRef<HTMLPreElement | null>(null)
  const [loadState, setLoadState] = useState<LoadState>('loading')
  const [config, setConfig] = useState<RuntimeTomlConfig | null>(null)
  const [draft, setDraft] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [section, setSection] = useState<RuntimeSectionId>('routing')

  useEffect(() => {
    if (!onClose) return undefined
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        onClose()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  const dirty = config !== null && draft !== config.source_text

  const refresh = useCallback(async () => {
    setLoadState('loading')
    setError(null)
    setNotice(null)
    try {
      const next = await fetchRuntimeTomlConfig()
      setConfig(next)
      setDraft(next.source_text)
      setLoadState('loaded')
    } catch (err: unknown) {
      setError(errorToString(err))
      setLoadState('idle')
    }
  }, [])

  useEffect(() => {
    void refresh()
  }, [refresh])

  useEffect(() => {
    if (!dirty || typeof window === 'undefined') return undefined
    const onBeforeUnload = (event: BeforeUnloadEvent) => {
      event.preventDefault()
      event.returnValue = ''
    }
    window.addEventListener('beforeunload', onBeforeUnload)
    return () => window.removeEventListener('beforeunload', onBeforeUnload)
  }, [dirty])

  async function handleSave(sourceText?: string) {
    const nextSourceText = typeof sourceText === 'string' ? sourceText : textareaRef.current?.value ?? draft
    const nextDirty = config !== null && nextSourceText !== config.source_text
    if (!nextDirty || saving || loadState === 'loading') return
    setSaving(true)
    setError(null)
    setNotice(null)
    try {
      const saved = await saveRuntimeTomlConfig(nextSourceText)
      setConfig(saved)
      setDraft(saved.source_text)
      setNotice('적용됨')
    } catch (err: unknown) {
      setError(errorToString(err))
    } finally {
      setSaving(false)
    }
  }

  async function handleRoutingPatch(lane: RuntimeRoutingLane, runtimeId: string | null) {
    if (saving || loadState === 'loading' || dirty) return
    setSaving(true)
    setError(null)
    setNotice(null)
    try {
      const saved = await patchRuntimeRouting(lane, runtimeId)
      setConfig(saved)
      setDraft(saved.source_text)
      setNotice('적용됨')
    } catch (err: unknown) {
      setError(errorToString(err))
    } finally {
      setSaving(false)
    }
  }

  async function handleAssignmentPatch(keeperName: string, runtimeId: string | null) {
    if (saving || loadState === 'loading' || dirty) return
    setSaving(true)
    setError(null)
    setNotice(null)
    try {
      const saved = await patchRuntimeAssignment(keeperName, runtimeId)
      setConfig(saved)
      setDraft(saved.source_text)
      setNotice('적용됨')
    } catch (err: unknown) {
      setError(errorToString(err))
    } finally {
      setSaving(false)
    }
  }

  function handleBindingFieldChange(
    runtimeId: string,
    field: RuntimeBindingEditableField,
    value: string | number | null,
  ) {
    if (saving || loadState !== 'loaded') return
    setDraft(current => setRuntimeTomlBindingField(current, runtimeId, field, value))
    setNotice(null)
    setError(null)
  }

  // The three handlers below mutate the draft the same way handleBindingFieldChange
  // does — no direct API call. The new provider/model/binding only reaches
  // runtime.toml when the operator hits the existing "저장"/라이브 적용 button,
  // which re-validates the full text through the same POST /api/v1/runtime/config/raw
  // -> Runtime.save_config_text path (RFC-0273 §3.2: reuse, don't reimplement).
  function handleAddProvider(input: NewRuntimeProviderInput) {
    if (saving || loadState !== 'loaded') return
    setDraft(current => {
      let next = setRuntimeTomlProviderField(current, input.id, 'display-name', input.displayName || input.id)
      next = setRuntimeTomlProviderField(next, input.id, 'protocol', input.protocol)
      next = setRuntimeTomlProviderField(next, input.id, input.transportKind, input.transportValue)
      if (input.credentialType !== 'none' && input.credentialValue.trim() !== '') {
        next = setRuntimeTomlProviderCredential(next, input.id, input.credentialType, input.credentialValue)
      }
      return next
    })
    setNotice(null)
    setError(null)
  }

  function handleAddModel(input: NewRuntimeModelInput) {
    if (saving || loadState !== 'loaded') return
    setDraft(current => {
      let next = setRuntimeTomlModelField(current, input.id, 'api-name', input.apiName || input.id)
      next = setRuntimeTomlModelField(next, input.id, 'max-context', input.maxContext)
      next = setRuntimeTomlModelField(next, input.id, 'tools-support', input.toolsSupport)
      next = setRuntimeTomlModelField(next, input.id, 'thinking-support', input.thinkingSupport)
      next = setRuntimeTomlModelField(next, input.id, 'streaming', input.streaming)
      if (input.jsonSupport !== null) {
        next = setRuntimeTomlModelField(next, input.id, 'json-support', input.jsonSupport)
      }
      return next
    })
    setNotice(null)
    setError(null)
  }

  function handleAddBinding(providerId: string, modelId: string) {
    if (saving || loadState !== 'loaded') return
    setDraft(current => createRuntimeTomlBinding(current, providerId, modelId))
    setNotice(null)
    setError(null)
  }

  async function handleRefresh() {
    if (dirty) {
      const confirmed =
        typeof window === 'undefined' ||
        typeof window.confirm !== 'function' ||
        window.confirm('적용하지 않은 runtime.toml 변경을 버리고 다시 불러올까요?')
      if (!confirmed) return
    }
    await refresh()
  }

  function handleReset() {
    if (!config || !dirty || saving) return
    setDraft(config.source_text)
    setError(null)
    setNotice('되돌림')
  }

  async function handleCopyPath() {
    const ok = await copyToClipboard(path)
    if (ok) {
      setNotice('경로 복사됨')
      setError(null)
    } else {
      setError('경로 복사 실패')
    }
  }

  async function handleCopySource() {
    const ok = await copyToClipboard(draft)
    if (ok) {
      setNotice('runtime.toml 복사됨')
      setError(null)
    } else {
      setError('runtime.toml 복사 실패')
    }
  }

  function handleEditorScroll(event: Event) {
    const gutter = lineGutterRef.current
    if (!gutter) return
    gutter.scrollTop = (event.currentTarget as HTMLTextAreaElement).scrollTop
  }

  function handleEditorInput(event: Event) {
    setDraft((event.target as HTMLTextAreaElement).value)
    setNotice(null)
  }

  function handleEditorKeyDown(event: KeyboardEvent) {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's') {
      event.preventDefault()
      void handleSave((event.currentTarget as HTMLTextAreaElement).value)
      return
    }

    if (event.key !== 'Tab') return
    event.preventDefault()
    const textarea = event.currentTarget as HTMLTextAreaElement
    const start = textarea.selectionStart
    const end = textarea.selectionEnd
    const sourceText = textarea.value
    const next = `${sourceText.slice(0, start)}  ${sourceText.slice(end)}`
    setDraft(next)
    setNotice(null)
    window.setTimeout(() => {
      textareaRef.current?.setSelectionRange(start + 2, start + 2)
    }, 0)
  }

  const statusLabel = runtimeTomlStatusLabel(loadState, dirty, saving)
  const path = config?.path ?? 'runtime.toml'
  const stats = useMemo(() => runtimeTomlDraftStats(draft), [draft])
  const lineNumbers = useMemo(
    () => runtimeTomlLineNumbers(stats.lineCount),
    [stats.lineCount],
  )
  const impact = useMemo(
    () => (config !== null && dirty ? runtimeTomlImpactSummary(config.source_text, draft) : null),
    [config, dirty, draft],
  )
  const environment = useMemo(() => parseRuntimeTomlEnvironment(draft), [draft])
  const runtimeCount = environment.bindings.length
  const providerCount = environment.providers.length

  // Structured sections (routing/providers/models/bindings/assignments) all map
  // to RuntimeEnvironmentEditor, which already wires the parsed Provider × Model
  // × Binding state to the runtime.toml draft. The toml section keeps the raw
  // textarea + toolbar. All section bodies stay mounted in the DOM and visibility
  // is toggled via the nav, so the editor wiring is never torn down on switch.
  const structuredActive = section !== 'toml'
  const tomlActive = section === 'toml'
  // When the toml section is active, RuntimeEnvironmentEditor is hidden anyway;
  // fall back to 'routing' so its `section` prop stays a valid structured id.
  const structuredSection: RuntimeStructuredSection = section === 'toml' ? 'routing' : section

  const toolbar = html`
    <div class="v2-monitoring-toolbar sticky top-0 z-10 -mx-1 bg-[var(--color-bg-surface)]/95 px-1 py-2 backdrop-blur">
      <div class="flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
        <div class="min-w-0">
          <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">path</div>
          <div class="truncate font-mono text-xs text-[var(--color-fg-primary)]" data-testid="runtime-toml-path">
            ${path}
          </div>
        </div>
        <div class="flex shrink-0 flex-wrap items-center gap-2">
          <${ActionButton}
            variant="ghost"
            size="sm"
            onClick=${handleCopyPath}
            disabled=${loadState === 'loading'}
            ariaLabel="runtime.toml 경로 복사"
            title="경로 복사"
            testId="runtime-toml-copy-path"
            class="inline-flex items-center gap-1"
          >
            <${Copy} size=${13} strokeWidth=${2.25} aria-hidden="true" />
            <span>경로</span>
          <//>
          <${ActionButton}
            variant="ghost"
            size="sm"
            onClick=${handleReset}
            disabled=${!dirty || saving}
            ariaLabel="runtime.toml 변경 되돌리기"
            title="변경 되돌리기"
            testId="runtime-toml-reset"
            class="inline-flex items-center gap-1"
          >
            <${RotateCcw} size=${13} strokeWidth=${2.25} aria-hidden="true" />
            <span>되돌리기</span>
          <//>
          <${ActionButton}
            variant="ghost"
            size="sm"
            onClick=${handleRefresh}
            disabled=${saving || loadState === 'loading'}
            ariaBusy=${loadState === 'loading'}
            ariaLabel="runtime.toml 다시 불러오기"
            title="다시 불러오기"
            testId="runtime-toml-refresh"
            class="inline-flex items-center gap-1"
          >
            <${RefreshCcw} size=${13} strokeWidth=${2.25} aria-hidden="true" />
            <span>새로고침</span>
          <//>
          <${ActionButton}
            variant="primary"
            size="sm"
            onClick=${handleSave}
            disabled=${!dirty || saving || loadState === 'loading'}
            ariaBusy=${saving}
            ariaLabel="runtime.toml 라이브 적용"
            title="라이브 적용"
            testId="runtime-toml-save"
            class="inline-flex items-center gap-1"
          >
            <${Save} size=${13} strokeWidth=${2.25} aria-hidden="true" />
            <span>${saving ? '적용 중' : '라이브 적용'}</span>
          <//>
        </div>
      </div>
      <div
        class="mt-2 flex flex-wrap items-center gap-2 text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]"
        data-testid="runtime-toml-stats"
      >
        <span>${stats.lineCount} lines</span>
        <span>${stats.charCount} chars</span>
        <span>${dirty ? 'unsaved' : 'synced'}</span>
      </div>
      ${impact ? html`<${RuntimeTomlImpactPreview} impact=${impact} />` : null}
    </div>
  `

  const statusPill = html`
    <span
      class="rt-status ${runtimeStatusToneClass(statusLabel)}"
      data-testid="runtime-toml-status"
    >
      ${statusLabel}
    </span>
  `

  const headerActions = onClose
    ? html`
      <div class="rt-head-actions">
        ${statusPill}
        <button
          type="button"
          class="rt-close"
          onClick=${onClose}
          title="닫기 (Esc)"
          data-testid="runtime-toml-close"
        >${'✕'}</button>
      </div>
    `
    : null

  const body = loadState === 'loading'
    ? html`
      ${toolbar}
      ${error ? html`<${ErrorState} message=${error} />` : null}
      <${LoadingState}>runtime.toml 불러오는 중...<//>
    `
    : html`
      <!-- rt-shell: 218px section-nav + fluid content (runtime-editor.jsx:110,
           runtime.css:6). -->
      <div class="rt-shell">
        <nav class="rt-nav" aria-label="런타임 편집기 섹션">
          <div class="rt-nav-h">
            <div class="eyebrow">Operator</div>
            <div class="rt-nav-title">런타임 편집기</div>
            <div class="rt-nav-sub mono">config/runtime.toml</div>
          </div>
          ${RUNTIME_SECTIONS.map(s => html`
            <button
              key=${s.id}
              type="button"
              class="rt-nav-item ${section === s.id ? 'on' : ''}"
              aria-pressed=${section === s.id}
              data-testid=${`runtime-toml-nav-${s.id}`}
              onClick=${() => setSection(s.id)}
            >
              <span class="rt-nav-gl mono">${s.glyph}</span><span>${s.label}</span>
            </button>
          `)}
          <div class="rt-nav-foot mono">${runtimeCount} 런타임 · ${providerCount} 프로바이더</div>
        </nav>

        <div class="rt-content">
          <header class="rt-head">
            <h1 data-testid="runtime-toml-section-title">${runtimeSectionTitle(section)}</h1>
            ${headerActions}
          </header>

          <div class="rt-body">
            ${toolbar}
            ${error ? html`<${ErrorState} message=${error} />` : null}
            ${notice ? html`
              <div
                class="px-1 text-xs text-[var(--color-status-ok)]"
                role="status"
                data-testid="runtime-toml-notice"
              >
                ${notice}
              </div>
            ` : null}

            <div class=${structuredActive ? '' : 'hidden'} data-testid="runtime-toml-structured">
              <${RuntimeEnvironmentEditor}
                sourceText=${draft}
                section=${structuredSection}
                disabled=${loadState !== 'loaded'}
                draftDirty=${dirty}
                saving=${saving}
                onRoutingChange=${(lane: RuntimeRoutingLane, runtimeId: string | null) => {
                  void handleRoutingPatch(lane, runtimeId)
                }}
                onAssignmentChange=${(keeperName: string, runtimeId: string | null) => {
                  void handleAssignmentPatch(keeperName, runtimeId)
                }}
                onBindingFieldChange=${handleBindingFieldChange}
                onAddProvider=${handleAddProvider}
                onAddModel=${handleAddModel}
                onAddBinding=${handleAddBinding}
              />
            </div>

            <div class=${tomlActive ? 'flex flex-col gap-3' : 'hidden'} data-testid="runtime-toml-section">
              <div class="rt-toml-wrap">
                <div class="rt-toml-bar">
                  <span class="mono">${path}</span>
                  <span class="rt-toml-ro">직접 편집 가능 · 저장 시 라이브 적용</span>
                  <button
                    type="button"
                    class="rt-copy"
                    onClick=${handleCopySource}
                    title="runtime.toml 복사"
                    data-testid="runtime-toml-copy-source"
                  >복사</button>
                </div>
                <div
                  class="v2-monitoring-code-frame grid min-h-[32rem] max-h-[72vh] grid-cols-[3.5rem_minmax(0,1fr)] overflow-hidden rounded-[var(--r-1)] border border-[var(--input-border)] bg-[var(--input-bg)]"
                  data-testid="runtime-toml-code-frame"
                >
                  <pre
                    ref=${lineGutterRef}
                    class="select-none overflow-hidden border-r border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2 py-3 text-right font-mono text-xs leading-relaxed text-[var(--color-fg-disabled)]"
                    aria-hidden="true"
                    data-testid="runtime-toml-line-numbers"
                  >${lineNumbers}</pre>
                  <textarea
                    ref=${textareaRef}
                    class="min-h-[32rem] w-full resize-y overflow-auto border-0 bg-transparent px-3 py-3 font-mono text-xs leading-relaxed text-[var(--color-fg-primary)] outline-none ${editorFocusClasses}"
                    aria-label="runtime.toml source"
                    data-testid="runtime-toml-source"
                    value=${draft}
                    rows=${32}
                    wrap="off"
                    spellcheck=${false}
                    autocapitalize="off"
                    autocorrect="off"
                    disabled=${saving}
                    onInput=${handleEditorInput}
                    onKeyDown=${handleEditorKeyDown}
                    onScroll=${handleEditorScroll}
                  ></textarea>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    `

  if (onClose) {
    return html`
      <div class="rt-overlay" data-testid="runtime-toml-editor" onClick=${onClose}>
        ${body}
      </div>
    `
  }

  return html`
    <${SectionCard}
      class="v2-monitoring-panel"
      label="runtime.toml"
      testId="runtime-toml-editor"
      right=${statusPill}
    >
      ${body}
    <//>
  `
}
