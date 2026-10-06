import { ModelSetupResumeControl } from './model-setup-resume-control'
import { html } from 'htm/preact'
import { Copy, RefreshCcw, RotateCcw, Save } from 'lucide-preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  fetchRuntimeTomlConfig,
  fetchRuntimeResolved,
  fetchStandaloneLanes,
  patchRuntimeAssignment,
  patchRuntimeExactSlot,
  patchRuntimeRouting,
  saveRuntimeTomlConfig,
  type RuntimeRoutingLane,
  type RuntimeExactSlotAction,
  type RuntimeExactSlotDirection,
  type RuntimeResolution,
  type StandaloneLaneSnapshotRow,
} from '../api/dashboard'
import { executionWorkspaceAuthority, refreshExecution, type ExecutionWorkspaceAuthority } from '../store'
import { runtimeTomlSessionFor, type RuntimeTomlSession, type RuntimeSectionId } from '../lib/runtime-toml-session'
import { errorToString } from '../lib/format-string'
import { refreshRuntimeConfigConsumers } from '../lib/runtime-config-refresh'
import {
  cascadeDeleteProvider,
  createRuntimeTomlBinding,
  enabledRuntimeIds,
  parseRuntimeTomlEnvironment,
  runtimeTomlImpactSummary,
  setRuntimeTomlBindingField,
  setRuntimeTomlModelField,
  setRuntimeTomlProviderCredential,
  setRuntimeTomlProviderField,
  type RuntimeTomlCredentialType,
  type RuntimeTomlImpactSummary,
} from '../lib/runtime-toml-config'
import { runtimeTomlSourceGeneration } from '../lib/runtime-toml-source-generation'
import { announceExactLaneObservationChanged, exactLaneObservationRevision } from '../lib/exact-lane-observation'
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
  type RuntimeProviderTransportEditableField,
  type RuntimeStructuredSection,
} from './runtime-environment-editor'
import { RuntimeExactLaneEditor } from './runtime-exact-lane-editor'
import { laneTargetLabel, runtimeTargetRange, type RuntimeLaneTarget } from '../lib/lane-navigation'

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

interface RuntimeSection {
  readonly id: RuntimeSectionId
  readonly label: string
  readonly glyph: string
}

const RUNTIME_SECTIONS: readonly RuntimeSection[] = [
  { id: 'routing', label: '라우팅', glyph: '◷' },
  { id: 'lanes', label: 'Lane 후보', glyph: '⇄' },
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

function stopOverlayContentClick(event: MouseEvent) {
  event.stopPropagation()
}

export interface RuntimeTomlEditorProps {
  navigationTarget?: RuntimeLaneTarget
  onClose?: () => void
  /** Called after a successful backend write (raw save, routing patch, or
   *  assignment patch). Use this in parent surfaces that also display derived
   *  runtime state so they can re-fetch and stay in sync with the editor. */
  onSaved?: () => void
}

export function RuntimeTomlEditor(props: RuntimeTomlEditorProps = {}) {
  const authority = executionWorkspaceAuthority.value
  const [recovering, setRecovering] = useState(false)
  const [error, setError] = useState<string | null>(null)
  async function verify() {
    setRecovering(true); setError(null)
    try { await refreshExecution({ force: true }); if (executionWorkspaceAuthority.peek() === null) setError('작업공간을 확인하지 못했습니다. 다시 시도하세요.') }
    catch (error) { setError(errorToString(error)) }
    finally { setRecovering(false) }
  }
  if (authority === null) return html`<section aria-label="runtime.toml 작업공간 확인">
    <p>작업공간을 확인한 뒤 런타임 설정을 편집할 수 있습니다. 보관된 초안은 유지됩니다.</p>
    <button type="button" disabled=${recovering} onClick=${verify}>${recovering ? '작업공간 확인 중' : '작업공간 확인'}</button>
    ${error && html`<p role="alert">${error}</p>`}
    ${props.onClose && html`<button type="button" onClick=${props.onClose}>닫기</button>`}
  </section>`
  return html`<${RuntimeTomlEditorContent} key=${authority.workspaceRoot} ...${props}
    authority=${authority} session=${runtimeTomlSessionFor(authority)} />`
}

function RuntimeTomlEditorContent({ onClose, onSaved, navigationTarget, authority, session }: RuntimeTomlEditorProps & {
  authority: ExecutionWorkspaceAuthority; session: RuntimeTomlSession;
}) {
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const lineGutterRef = useRef<HTMLPreElement | null>(null)
  const mounted = useRef(true)
  useEffect(() => { mounted.current = true; return () => { mounted.current = false } }, [])
  const { config, draft, modelContextDrafts, error, notice, currentSource, section, phase, needsRead, projectionRevision } = session.state.value
  const saving = phase === 'saving_raw' || phase === 'saving_patch', readingCurrent = phase === 'reading'
  const loadState: LoadState = phase === 'loading' || config === null && error === null
    ? 'loading' : config === null ? 'idle' : 'loaded'
  const setDraft = (value: string | ((current: string) => string)) => session.edit('draft', value)
  const setModelContextDrafts = (value: Record<string, string> | ((current: Record<string, string>) => Record<string, string>)) => session.edit('modelContextDrafts', value)
  const setError = (value: string | null) => session.edit('error', value)
  const setNotice = (value: string | null) => session.edit('notice', value)
  const setSection = (value: RuntimeSectionId) => session.edit('section', value)
  // A target is selected once, when it is found. Until then every draft
  // change looks it up again so the notice follows the text; the first
  // attempt also moves focus into the editor. A target that only becomes
  // locatable after the reader edits is offered, not selected: selecting it
  // under the caret would let the next keystroke overwrite the declaration.
  const focusedNavigation = useRef<RuntimeLaneTarget | undefined>(undefined)
  const attemptedNavigation = useRef<RuntimeLaneTarget | undefined>(undefined)
  const [navigationNotice, setNavigationNotice] = useState<string | null>(null)
  const [locatedNavigation, setLocatedNavigation] = useState<[number, number] | null>(null)
  useEffect(() => {
    if (navigationTarget) session.edit('section', navigationTarget.kind === 'exact' ? 'lanes' : 'toml')
    setNavigationNotice(null); setLocatedNavigation(null)
  }, [navigationTarget, session])
  const selectNavigation = (range: [number, number] | null) => {
    const textarea = textareaRef.current
    if (!textarea) return
    textarea.focus()
    const start = range?.[0] ?? draft.length, end = range?.[1] ?? start
    textarea.setSelectionRange(start, end)
    const lineHeight = Number.parseFloat(getComputedStyle(textarea).lineHeight)
    if (Number.isFinite(lineHeight)) {
      textarea.scrollTop = draft.slice(0, start).split('\n').length * lineHeight - lineHeight
      if (lineGutterRef.current) lineGutterRef.current.scrollTop = textarea.scrollTop
    }
  }
  useEffect(() => {
    if (!navigationTarget || navigationTarget.kind === 'exact' || config === null || section !== 'toml'
      || focusedNavigation.current === navigationTarget || !textareaRef.current) return
    let range: [number, number] | null = null, notice: string | null = null
    try {
      range = runtimeTargetRange(draft, navigationTarget)
      if (range === null) notice = 'This target is not declared in the current draft. No configuration was inserted; edit the original TOML to add it.'
    } catch (cause) { notice = `Cannot locate the target in this draft: ${errorToString(cause)}. Your text is unchanged.` }
    setNavigationNotice(notice)
    const firstAttempt = attemptedNavigation.current !== navigationTarget
    attemptedNavigation.current = navigationTarget
    if (firstAttempt) selectNavigation(range)
    if (range !== null && firstAttempt) { focusedNavigation.current = navigationTarget; setLocatedNavigation(null) }
    else setLocatedNavigation(range)
  }, [navigationTarget, config, section, draft])
  // Returning to the TOML section while a Browser/Machine target is linked
  // gives keyboard focus back to the editor. Only focus moves: the reader's
  // selection stays where they left it, never jumping to the declaration.
  const inToml = useRef(section === 'toml')
  useEffect(() => {
    const entering = section === 'toml' && !inToml.current
    inToml.current = section === 'toml'
    if (entering && navigationTarget && navigationTarget.kind !== 'exact'
      && attemptedNavigation.current === navigationTarget) textareaRef.current?.focus()
  }, [section, navigationTarget])
  const ready = session.writable(authority)
  const canAdopt = session.ready(authority)
  const observationRevision = exactLaneObservationRevision(authority)
  const [projection, setProjection] = useState<{
    authority: ExecutionWorkspaceAuthority; config: typeof config; revision: number; observationRevision: number;
    lanes: StandaloneLaneSnapshotRow[] | null; runtimes: RuntimeResolution[] | null; error: string | null;
  } | null>(null)
  const projectionRequest = useRef(0)
  const currentProjection = projection?.authority === authority && projection.config === config
    && projection.revision === projectionRevision && projection.observationRevision === observationRevision ? projection : null
  const exactLanes = currentProjection?.lanes ?? null, laneRuntimes = currentProjection?.runtimes ?? null
  const exactLaneError = currentProjection?.error ?? null
  useEffect(() => {
    const request = ++projectionRequest.current
    if (config === null) return
    void Promise.all([fetchStandaloneLanes(), fetchRuntimeResolved()]).then(([snapshot, resolved]) => {
      if (mounted.current && session.admits(authority) && projectionRequest.current === request)
        setProjection({ authority, config, revision: projectionRevision, observationRevision, lanes: snapshot.lanes, runtimes: resolved.runtimes, error: null })
    }, error => {
      if (mounted.current && session.admits(authority) && projectionRequest.current === request)
        setProjection({ authority, config, revision: projectionRevision, observationRevision, lanes: null, runtimes: null, error: errorToString(error) })
    })
    return () => { ++projectionRequest.current }
  }, [session, authority, config, projectionRevision, observationRevision])

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

  const invalidModelContexts = Object.keys(modelContextDrafts).length > 0
  const dirty = invalidModelContexts || (config !== null && draft !== config.source_text)

  const refresh = () => session.read(authority, 'reload')
  const sourceGeneration = runtimeTomlSourceGeneration.value
  useEffect(() => {
    void session.ensure(authority)
  }, [session, authority, sourceGeneration])

  async function afterSetupResume() {
    if (!session.admits(authority)) return
    announceExactLaneObservationChanged(authority)
    try { await refreshRuntimeConfigConsumers() }
    catch (error) {
      if (mounted.current && session.admits(authority)) setError(`런타임 목록 갱신 실패: ${errorToString(error)}`)
    }
  }

  async function afterWrite(committed: boolean) {
    if (!committed || !mounted.current || !session.admits(authority)) return
    onSaved?.()
  }

  async function handleSave(sourceText?: string) {
    const nextSourceText = typeof sourceText === 'string' ? sourceText : textareaRef.current?.value ?? draft
    if (!ready || config === null || saving || readingCurrent || currentSource !== null || loadState === 'loading' || invalidModelContexts) return
    if (nextSourceText === config.source_text) return
    const expectedSourcePath = config.path
    if (expectedSourcePath === null || expectedSourcePath === '') {
      setError('runtime.toml 저장 기준 path를 확인하지 못했습니다. 현재 파일을 다시 읽으세요.')
      return
    }
    const nextEnvironment = parseRuntimeTomlEnvironment(nextSourceText, config.reserved_provider_ids)
    for (const provider of nextEnvironment.providers) {
      const protocol = config?.provider_protocols.find(item => item.protocol === provider.protocol)
      if (!protocol?.provider_fields.includes('account-home')) continue
      const home = provider.accountHome.trim()
      if (provider.enabled && protocol.required_provider_fields.includes('account-home') && home === '') {
        setError(`${provider.id}: 사용할 계정 홈을 선택하세요`)
        return
      }
      if (home !== '' && !home.startsWith('/')) {
        setError(`${provider.id}: 계정 홈은 절대 경로여야 합니다`)
        return
      }
    }
    await afterWrite(await session.write(authority,
      options => saveRuntimeTomlConfig(nextSourceText, config.source_revision, { ...options, expectedSourcePath }), nextSourceText))
  }

  async function handleReadCurrent() { await session.read(authority, 'compare') }
  function useCurrentSource(replaceDraft: boolean) { session.useCurrent(authority, replaceDraft) }

  async function handleRoutingPatch(lane: RuntimeRoutingLane, runtimeId: string | null) {
    await afterWrite(await session.write(authority, options => patchRuntimeRouting(lane, runtimeId, options)))
  }

  async function handleAssignmentPatch(keeperName: string, runtimeId: string | null) {
    if (!config) return
    await afterWrite(await session.write(authority, async options => {
      const environment = parseRuntimeTomlEnvironment(config.source_text, config.reserved_provider_ids)
      if (environment.parseError !== null) throw new Error(environment.parseError)
      const currentRuntimeId = environment.assignments[keeperName]
      const expectedAssignmentRevision = {
        state: 'runtime_config_present' as const, source_revision: config.source_revision,
        assignment: currentRuntimeId ? { state: 'assigned' as const, runtime_id: currentRuntimeId }
          : { state: 'missing' as const },
      }
      const saved = await patchRuntimeAssignment(keeperName, runtimeId, expectedAssignmentRevision, options)
      return 'assignment_revision' in saved ? { unchanged: await fetchRuntimeTomlConfig(options) } : saved
    }))
  }

  function editDraft(edit: (current: string) => string) {
    setNotice(null)
    setDraft(current => {
      try {
        const next = edit(current)
        setError(null)
        return next
      } catch (error: unknown) {
        setError(errorToString(error))
        return current
      }
    })
  }

  function handleBindingFieldChange(
    runtimeId: string,
    field: RuntimeBindingEditableField,
    value: string | number | boolean | null,
  ) {
    if (saving || loadState !== 'loaded') return
    editDraft(current => setRuntimeTomlBindingField(current, runtimeId, field, value))
  }

  async function handleExactSlotAction(laneId: string, action: RuntimeExactSlotAction,
    runtimeId: string, direction?: RuntimeExactSlotDirection) {
    await afterWrite(await session.write(authority,
      options => patchRuntimeExactSlot(laneId, action, runtimeId, direction, options)))
  }

  function handleExactBodyDeadlineChange(providerId: string, seconds: number | null) {
    if (saving || loadState !== 'loaded') return
    editDraft(current => setRuntimeTomlProviderField(current, providerId, 'exact-body-timeout-s', seconds))
  }

  // The three handlers below mutate the draft the same way handleBindingFieldChange
  // does — no direct API call. The new provider/model/binding only reaches
  // runtime.toml when the operator hits the existing "저장"/라이브 적용 button,
  // which re-validates the full text through the same POST /api/v1/runtime/config/raw
  // -> Runtime.save_config_text path (RFC-0273 §3.2: reuse, don't reimplement).
  function handleAddProvider(input: NewRuntimeProviderInput) {
    if (saving || loadState !== 'loaded') return
    editDraft(current => {
      let next = setRuntimeTomlProviderField(current, input.id, 'display-name', input.displayName || input.id)
      next = setRuntimeTomlProviderField(next, input.id, 'protocol', input.protocol)
      next = setRuntimeTomlProviderField(next, input.id, input.transportKind, input.transportValue)
      if (input.isNonInteractive) {
        next = setRuntimeTomlProviderField(next, input.id, 'is-non-interactive', true)
      }
      if (input.credentialType !== 'none' && input.credentialValue.trim() !== '') {
        next = setRuntimeTomlProviderCredential(next, input.id, input.credentialType, input.credentialValue)
      }
      if (input.agent !== '') {
        next = setRuntimeTomlProviderField(next, input.id, 'agent', input.agent)
      }
      if (input.accountHome !== '') {
        next = setRuntimeTomlProviderField(next, input.id, 'account-home', input.accountHome)
      }
      if (input.effort !== '') {
        next = setRuntimeTomlProviderField(next, input.id, 'effort', input.effort)
      }
      if (input.timeoutS !== null) {
        next = setRuntimeTomlProviderField(next, input.id, 'timeout-s', input.timeoutS)
      }
      return next
    })
  }

  function handleProviderOptionChange(
    providerId: string,
    field: 'agent' | 'effort' | 'timeout-s' | 'account-home',
    value: string | number | null,
  ) {
    if (saving || loadState !== 'loaded') return
    editDraft(current => setRuntimeTomlProviderField(current, providerId, field, value))
  }

  function handleModelContextChange(modelId: string, raw: string) {
    if (saving || loadState !== 'loaded') return
    const trimmed = raw.trim()
    const tokens = Number(trimmed)
    const valid = /^\d+$/.test(trimmed) && Number.isSafeInteger(tokens) && tokens > 0
    setModelContextDrafts(current => {
      if (!valid) return { ...current, [modelId]: raw }
      const next = { ...current }
      delete next[modelId]
      return next
    })
    if (valid) editDraft(current => setRuntimeTomlModelField(current, modelId, 'max-context', tokens))
  }

  function handleAddModel(input: NewRuntimeModelInput) {
    if (saving || loadState !== 'loaded') return
    editDraft(current => {
      let next = setRuntimeTomlModelField(current, input.id, 'api-name', input.apiName || input.id)
      next = setRuntimeTomlModelField(next, input.id, 'max-context', input.maxContext)
      if (input.maxPromptBytes !== undefined) next = setRuntimeTomlModelField(next, input.id, 'max-prompt-bytes', input.maxPromptBytes)
      next = setRuntimeTomlModelField(next, input.id, 'tools-support', input.toolsSupport)
      next = setRuntimeTomlModelField(next, input.id, 'thinking-support', input.thinkingSupport)
      next = setRuntimeTomlModelField(next, input.id, 'streaming', input.streaming)
      if (input.jsonSupport !== null) {
        next = setRuntimeTomlModelField(next, input.id, 'json-support', input.jsonSupport)
      }
      return next
    })
  }

  function handleAddBinding(providerId: string, modelId: string) {
    if (saving || loadState !== 'loaded') return
    editDraft(current => createRuntimeTomlBinding(current, providerId, modelId))
  }

  function handleDeleteProvider(providerId: string) {
    if (saving || loadState !== 'loaded' || !config) return
    const reservedProviderIds = config.reserved_provider_ids
    editDraft(current => cascadeDeleteProvider(current, providerId, reservedProviderIds))
  }

  function handleProviderTransportChange(
    providerId: string,
    field: RuntimeProviderTransportEditableField,
    value: string,
  ) {
    if (saving || loadState !== 'loaded') return
    editDraft(current => setRuntimeTomlProviderField(current, providerId, field, value))
  }

  function handleProviderEnabledChange(providerId: string, enabled: boolean) {
    if (saving || loadState !== 'loaded') return
    editDraft(current => setRuntimeTomlProviderField(current, providerId, 'enabled', enabled))
  }

  function handleProviderCredentialChange(
    providerId: string,
    credentialType: RuntimeTomlCredentialType,
    value: string,
  ) {
    if (saving || loadState !== 'loaded') return
    editDraft(current => setRuntimeTomlProviderCredential(current, providerId, credentialType, value))
  }

  async function handleRefresh() {
    if (saving || readingCurrent) return
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
    setModelContextDrafts({})
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
    if (!session.admits(authority)) return
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
    () => (config !== null && dirty
      ? runtimeTomlImpactSummary(config.source_text, draft, config.reserved_provider_ids)
      : null),
    [config, dirty, draft],
  )
  // Bindings are read with the server's reserved list, so there is no
  // environment before the config that carries it has loaded.
  const environment = useMemo(
    () => (config === null ? null : parseRuntimeTomlEnvironment(draft, config.reserved_provider_ids)),
    [config, draft],
  )
  useEffect(() => {
    // Raw TOML can remove or rename a model while its structured input has an
    // invalid draft. Only models still present may retain that input state.
    if (environment === null || environment.parseError !== null) return
    const modelIds = new Set(environment.models.map(model => model.id))
    setModelContextDrafts(current => {
      const retained = Object.entries(current).filter(([id]) => modelIds.has(id))
      return retained.length === Object.keys(current).length ? current : Object.fromEntries(retained)
    })
  }, [environment])
  const parseError = environment === null ? null : environment.parseError
  const runtimeCount = environment !== null && parseError === null ? enabledRuntimeIds(environment).length : '—'
  const providerCount = environment !== null && parseError === null ? environment.providers.length : '—'
  const keeperSettings = config?.keeper_settings ?? []
  const keeperPendingCount = keeperSettings.filter(setting =>
    setting.application_status === 'pending_restart'
    || setting.application_status === 'pending_effect_boundary').length

  // Structured sections (routing/providers/models/bindings/assignments) all map
  // to RuntimeEnvironmentEditor, which already wires the parsed Provider × Model
  // × Binding state to the runtime.toml draft. The toml section keeps the raw
  // textarea + toolbar. All section bodies stay mounted in the DOM and visibility
  // is toggled via the nav, so the editor wiring is never torn down on switch.
  const structuredActive = section !== 'toml' && section !== 'lanes'
  const tomlActive = section === 'toml'
  // When the toml section is active, RuntimeEnvironmentEditor is hidden anyway;
  // fall back to 'routing' so its `section` prop stays a valid structured id.
  const structuredSection: RuntimeStructuredSection = section === 'toml' || section === 'lanes' ? 'routing' : section

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
            disabled=${saving || readingCurrent || loadState === 'loading'}
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
            variant="ghost"
            size="sm"
            onClick=${handleReadCurrent}
            disabled=${saving || readingCurrent || loadState !== 'loaded' || config === null}
            testId="runtime-toml-read-current"
          >${readingCurrent ? '현재 파일 읽는 중' : '현재 파일 읽고 비교'}<//>
          <${ActionButton}
            variant="primary"
            size="sm"
            onClick=${handleSave}
            disabled=${!ready || !dirty || saving || readingCurrent || currentSource !== null || loadState === 'loading' || invalidModelContexts}
            ariaBusy=${saving}
            ariaLabel="runtime.toml 저장 및 적용"
            title="저장 및 적용 경계 확인"
            testId="runtime-toml-save"
            class="inline-flex items-center gap-1"
          >
            <${Save} size=${13} strokeWidth=${2.25} aria-hidden="true" />
            <span>${saving ? '적용 중' : '저장/적용'}</span>
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
      ${needsRead ? html`<p role="status">현재 파일을 읽고 비교한 뒤 저장 기준을 선택하세요. 초안은 유지됩니다.</p>` : null}
      ${invalidModelContexts ? html`<p role="alert">모델 컨텍스트 입력을 수정하거나 되돌린 뒤 저장하세요.</p>` : null}
      ${parseError !== null ? html`<p role="alert" data-testid="runtime-toml-parse-error">${parseError}</p>` : null}
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
            ${currentSource !== null && config !== null ? html`
              <section class="space-y-3 rounded border border-[var(--color-border-default)] p-3" aria-label="runtime.toml 현재 파일 비교" data-testid="runtime-toml-conflict">
                <p>현재 파일과 초안을 비교하세요. 읽기만으로 저장 기준이 바뀌지 않습니다.</p>
                <p class="break-all">${currentSource.source_path}</p>
                <div class="grid gap-3 md:grid-cols-2">
                  <div><h2>편집 기준 원문</h2><code class="break-all">${config.source_revision}</code>
                    <pre class="max-h-64 overflow-auto whitespace-pre-wrap break-all" aria-label="편집 기준 원문">${config.source_text}</pre></div>
                  <div><h2>현재 서버 원문</h2><code class="break-all">${currentSource.source_revision}</code>
                    <pre class="max-h-64 overflow-auto whitespace-pre-wrap break-all" aria-label="현재 서버 원문">${currentSource.source_text}</pre></div>
                </div>
                <p>초안을 유지하고 현재 revision을 채택하면, 다음 저장 시 현재 파일을 아래 초안으로 교체합니다. 필요한 변경을 먼저 합치세요.</p>
                <div class="flex flex-wrap gap-2">
                  <${ActionButton} disabled=${!canAdopt || saving || readingCurrent} onClick=${() => useCurrentSource(false)} testId="runtime-toml-adopt-revision">현재 revision 채택 · 초안 유지<//>
                  <${ActionButton} disabled=${!canAdopt || saving || readingCurrent} onClick=${() => useCurrentSource(true)} testId="runtime-toml-replace-draft">현재 원문으로 초안 교체<//>
                </div>
              </section>
            ` : null}
            ${notice ? html`
              <div
                class="px-1 text-xs text-[var(--color-status-ok)]"
                role="status"
                data-testid="runtime-toml-notice"
              >
                ${notice}
              </div>
            ` : null}
            ${keeperSettings.length > 0 ? html`
              <details
                class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] p-3"
                data-testid="runtime-keeper-setting-matrix"
              >
                <summary class="cursor-pointer text-xs font-semibold text-[var(--color-fg-primary)]">
                  Keeper 설정 authority · ${keeperSettings.length}개
                  ${keeperPendingCount > 0 ? ` · 재시작 대기 ${keeperPendingCount}개` : ''}
                </summary>
                <div class="mt-3 overflow-x-auto">
                  <table class="w-full min-w-[64rem] text-left text-xs">
                    <thead class="text-[var(--color-fg-muted)]">
                      <tr>
                        <th class="p-2">key / env</th>
                        <th class="p-2">configured → effective</th>
                        <th class="p-2">source / status</th>
                        <th class="p-2">effect boundary</th>
                        <th class="p-2">consumers</th>
                      </tr>
                    </thead>
                    <tbody>
                      ${keeperSettings.map(setting => html`
                        <tr key=${setting.env} class="border-t border-[var(--color-border-default)] align-top">
                          <td class="p-2 font-mono">
                            <div>${setting.key ?? 'env_only'}</div>
                            <div class="text-[var(--color-fg-muted)]">${setting.env}</div>
                          </td>
                          <td class="p-2 font-mono">
                            ${setting.configured_value ?? '—'} → ${setting.effective_value ?? '—'}
                            ${setting.effective_error ? html`
                              <div
                                class="mt-1 text-[var(--color-status-error)]"
                                data-testid=${`runtime-keeper-setting-error-${setting.env}`}
                              >${setting.effective_error}</div>
                            ` : null}
                          </td>
                          <td class="p-2">
                            <div>${setting.source}</div>
                            <div class="text-[var(--color-fg-muted)]">${setting.application_status}</div>
                          </td>
                          <td class="p-2">
                            ${setting.reload_class}${setting.requires_restart ? ' · restart' : ''}
                            ${setting.applied_at !== null ? html`<div class="font-mono text-[var(--color-fg-muted)]">${setting.applied_at}</div>` : null}
                          </td>
                          <td class="p-2">${setting.consumers.join(', ') || '—'}</td>
                        </tr>
                      `)}
                    </tbody>
                  </table>
                </div>
              </details>
            ` : null}

            <div class=${structuredActive ? '' : 'hidden'} data-testid="runtime-toml-structured">
              ${config ? html`<${RuntimeEnvironmentEditor}
                sourceText=${draft}
                providerProtocols=${config.provider_protocols}
                reservedProviderIds=${config.reserved_provider_ids}
                section=${structuredSection}
                disabled=${loadState !== 'loaded' || parseError !== null}
                draftDirty=${!ready || dirty || readingCurrent || currentSource !== null}
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
                modelContextDrafts=${modelContextDrafts}
                onModelContextChange=${handleModelContextChange}
                onAddBinding=${handleAddBinding}
                onDeleteProvider=${handleDeleteProvider}
              onProviderTransportChange=${handleProviderTransportChange}
              onProviderEnabledChange=${handleProviderEnabledChange}
                onProviderCredentialChange=${handleProviderCredentialChange}
                onProviderOptionChange=${handleProviderOptionChange}
              />` : null}
            </div>

            <div class=${section === 'lanes' ? '' : 'hidden'} data-testid="runtime-toml-lanes">
              ${navigationTarget?.kind === 'exact' && html`<p role="status">Selected Lane: ${navigationTarget.lane}</p>`}
              ${navigationTarget?.kind === 'exact' && exactLanes && !exactLanes.some(lane => lane.laneId === navigationTarget.lane)
                && html`<p role="alert">The selected Lane is absent from the current runtime reading.</p>`}
              ${exactLaneError ? html`<p role="alert">Lane 투영을 읽지 못했습니다: ${exactLaneError}</p>` : null}
              ${parseError !== null ? html`<p role="alert">${parseError}</p>` : exactLanes && laneRuntimes ? html`<${RuntimeExactLaneEditor}
                selectedLane=${section === 'lanes' && navigationTarget?.kind === 'exact' ? navigationTarget.lane : undefined}
                sourceText=${draft} lanes=${exactLanes} runtimes=${laneRuntimes}
                slotsDisabled=${!ready || saving || readingCurrent || currentSource !== null || loadState !== 'loaded' || dirty}
                deadlineDisabled=${saving || loadState !== 'loaded'}
                onSlotAction=${(laneId: string, action: RuntimeExactSlotAction, runtimeId: string,
                  direction?: RuntimeExactSlotDirection) => { void handleExactSlotAction(laneId, action, runtimeId, direction) }}
                onDeadlineChange=${handleExactBodyDeadlineChange} />` : null}
            </div>

            <div class=${tomlActive ? 'flex flex-col gap-3' : 'hidden'} data-testid="runtime-toml-section">
              ${navigationTarget && navigationTarget.kind !== 'exact' && html`<p role="status">Selected configuration: ${laneTargetLabel(navigationTarget)}. Existing draft text is retained.</p>`}
              ${navigationNotice && html`<p role="status">${navigationNotice}</p>`}
              ${locatedNavigation && navigationTarget && navigationTarget.kind !== 'exact' && html`<p role="status">The selected configuration is now declared in this draft.
                <button type="button" onClick=${() => { selectNavigation(locatedNavigation); focusedNavigation.current = navigationTarget; setLocatedNavigation(null) }}>Select target</button></p>`}
              <div class="rt-toml-wrap">
                <div class="rt-toml-bar">
                  <span class="mono">${path}</span>
                  <span class="rt-toml-ro">직접 편집 가능 · routing 즉시 적용 / Keeper overlay 재시작 적용</span>
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
                    disabled=${phase === 'saving_patch'}
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
        <div class="rt-overlay-content" onClick=${stopOverlayContentClick}>
          <${ModelSetupResumeControl} disabled=${saving} onComplete=${afterSetupResume} />
          ${body}
        </div>
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
      <${ModelSetupResumeControl} disabled=${saving} onComplete=${afterSetupResume} />
      ${body}
    <//>
  `
}
