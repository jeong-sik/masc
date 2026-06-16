import { html } from 'htm/preact'
import { Copy, RefreshCcw, RotateCcw, Save } from 'lucide-preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  fetchRuntimeTomlConfig,
  saveRuntimeTomlConfig,
  type RuntimeTomlConfig,
} from '../api/dashboard'
import { errorToString } from '../lib/format-string'
import { ActionButton } from './common/button'
import { SectionCard } from './common/card'
import { copyToClipboard } from './common/copyable-code'
import { ErrorState, LoadingState } from './common/feedback-state'
import { ringFocusClasses } from './common/ring'
import { RuntimeEnvironmentEditor } from './runtime-environment-editor'

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

const editorFocusClasses = ringFocusClasses({
  tone: 'accent-medium',
  width: 2,
  offset: 0,
})

export function RuntimeTomlEditor() {
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const lineGutterRef = useRef<HTMLPreElement | null>(null)
  const [loadState, setLoadState] = useState<LoadState>('loading')
  const [config, setConfig] = useState<RuntimeTomlConfig | null>(null)
  const [draft, setDraft] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)

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
      setNotice('저장됨')
    } catch (err: unknown) {
      setError(errorToString(err))
    } finally {
      setSaving(false)
    }
  }

  async function handleRefresh() {
    if (dirty) {
      const confirmed =
        typeof window === 'undefined' ||
        typeof window.confirm !== 'function' ||
        window.confirm('저장하지 않은 runtime.toml 변경을 버리고 다시 불러올까요?')
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

  return html`
    <${SectionCard}
      class="v2-monitoring-panel"
      label="runtime.toml"
      testId="runtime-toml-editor"
      right=${html`
        <span
          class="rounded-[var(--r-0)] border border-[var(--color-border-subtle)] px-2 py-0.5 text-2xs font-medium uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]"
          data-testid="runtime-toml-status"
        >
          ${statusLabel}
        </span>
      `}
    >
      <div class="flex flex-col gap-3">
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
                ariaLabel="runtime.toml 저장"
                title="저장"
                testId="runtime-toml-save"
                class="inline-flex items-center gap-1"
              >
                <${Save} size=${13} strokeWidth=${2.25} aria-hidden="true" />
                <span>${saving ? '저장 중' : '저장'}</span>
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
        </div>

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

        ${loadState === 'loading'
          ? html`<${LoadingState}>runtime.toml 불러오는 중...<//>`
          : html`
            <${RuntimeEnvironmentEditor}
              sourceText=${draft}
              dirty=${dirty}
              disabled=${loadState !== 'loaded'}
              saving=${saving}
              onDraftChange=${(nextSourceText: string) => {
                setDraft(nextSourceText)
                setNotice(null)
              }}
              onSave=${(nextSourceText?: string) => {
                void handleSave(nextSourceText)
              }}
            />
            <div
              class="v2-monitoring-code-frame mt-4 grid min-h-[32rem] max-h-[72vh] grid-cols-[3.5rem_minmax(0,1fr)] overflow-hidden rounded-[var(--r-1)] border border-[var(--input-border)] bg-[var(--input-bg)]"
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
          `}
      </div>
    <//>
  `
}
