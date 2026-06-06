import { html } from 'htm/preact'
import { useCallback, useEffect, useState } from 'preact/hooks'
import {
  fetchRuntimeTomlConfig,
  saveRuntimeTomlConfig,
  type RuntimeTomlConfig,
} from '../api/dashboard'
import { errorToString } from '../lib/format-string'
import { ActionButton } from './common/button'
import { SectionCard } from './common/card'
import { ErrorState, LoadingState } from './common/feedback-state'
import { TextArea } from './common/input'

type LoadState = 'idle' | 'loading' | 'loaded'

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

export function RuntimeTomlEditor() {
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

  async function handleSave() {
    if (!dirty || saving || loadState === 'loading') return
    setSaving(true)
    setError(null)
    setNotice(null)
    try {
      const saved = await saveRuntimeTomlConfig(draft)
      setConfig(saved)
      setDraft(saved.source_text)
      setNotice('저장됨')
    } catch (err: unknown) {
      setError(errorToString(err))
    } finally {
      setSaving(false)
    }
  }

  const statusLabel = runtimeTomlStatusLabel(loadState, dirty, saving)
  const path = config?.path ?? 'runtime.toml'

  return html`
    <${SectionCard}
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
              onClick=${refresh}
              disabled=${saving || loadState === 'loading'}
              ariaBusy=${loadState === 'loading'}
              testId="runtime-toml-refresh"
            >
              새로고침
            <//>
            <${ActionButton}
              variant="primary"
              size="sm"
              onClick=${handleSave}
              disabled=${!dirty || saving || loadState === 'loading'}
              ariaBusy=${saving}
              testId="runtime-toml-save"
            >
              ${saving ? '저장 중' : '저장'}
            <//>
          </div>
        </div>

        ${error ? html`<${ErrorState} message=${error} />` : null}
        ${notice ? html`
          <div
            class="rounded-[var(--r-0)] border border-[var(--ok-30)] bg-[var(--ok-12)] px-3 py-2 text-xs text-[var(--ok-light)]"
            role="status"
          >
            ${notice}
          </div>
        ` : null}

        ${loadState === 'loading'
          ? html`<${LoadingState}>runtime.toml 불러오는 중...<//>`
          : html`
            <${TextArea}
              ariaLabel="runtime.toml source"
              value=${draft}
              rows=${28}
              class="min-h-[28rem] font-mono text-xs leading-relaxed"
              disabled=${saving}
              onInput=${(event: Event) => {
                setDraft((event.target as HTMLTextAreaElement).value)
                setNotice(null)
              }}
            />
          `}
      </div>
    <//>
  `
}
