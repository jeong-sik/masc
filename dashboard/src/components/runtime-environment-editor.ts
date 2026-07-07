import { html } from 'htm/preact'
import { formatContextTokens } from '../lib/format-number'
import { useEffect, useMemo, useState } from 'preact/hooks'
import type { DashboardRuntimeProviderSnapshot } from '../api/dashboard'
import {
  findRuntimeCatalogEntry,
  loadRuntimeCatalog,
  runtimeCatalogState,
} from '../lib/runtime-catalog-resource'
import {
  runtimeCatalogDeclaredSpec,
  runtimeCatalogEffectiveCapabilities,
  runtimeCatalogParameterPolicy,
  runtimeCatalogRequestConfig,
  runtimeCatalogSnapshotFacts,
} from '../lib/runtime-provider-summary'
import {
  isRuntimeTomlNonMaterializableProtocol,
  isReservedRuntimeTomlId,
  isValidRuntimeTomlIdFormat,
  parseRuntimeTomlEnvironment,
  RUNTIME_TOML_CREATABLE_PROTOCOLS,
  type RuntimeTomlCredentialType,
  type RuntimeTomlEnvironment,
  type RuntimeTomlProtocol,
  type RuntimeTomlProvider,
} from '../lib/runtime-toml-config'
import { keepers } from '../store'
import { StatusDot } from './common/status-dot'

// rt-* section ids. Mirrors RUNTIME_SECTIONS in runtime-toml-editor.ts so the
// nav can drive which prototype body is visible. 'toml' is rendered by the
// parent, not here.
export type RuntimeStructuredSection =
  | 'routing'
  | 'providers'
  | 'models'
  | 'bindings'
  | 'assignments'

export type RuntimeBindingEditableField = 'max-concurrent' | 'keep-alive' | 'num-ctx'
export type RuntimeProviderTransportEditableField = 'endpoint' | 'command'

// Basic-field-only payloads (RFC-0273 §3.2 reuse boundary). Per-model
// [models.X.capabilities] flags (supports-tool-choice, thinking-control-format,
// ...) are deliberately excluded — those are semantically coupled to real,
// per-model verified behavior (see runtime.toml's own inline caveats), not
// something a generic add form can default safely. They stay raw-TOML-only.
// transportKind is fixed to 'endpoint': CLI (`command`) transport providers
// resolve to no provider_kind on the backend today and get silently dropped
// from the live runtime list rather than failing the save (see
// RUNTIME_TOML_CREATABLE_PROTOCOLS in lib/runtime-toml-config.ts). Until that
// backend limitation is lifted, this form cannot offer command transport.
export interface NewRuntimeProviderInput {
  id: string
  displayName: string
  protocol: RuntimeTomlProtocol
  transportKind: 'endpoint'
  transportValue: string
  credentialType: RuntimeTomlCredentialType
  credentialValue: string
}

export interface NewRuntimeModelInput {
  id: string
  apiName: string
  maxContext: number
  toolsSupport: boolean
  thinkingSupport: boolean
  streaming: boolean
  jsonSupport: boolean | null
}

interface RuntimeEnvironmentEditorProps {
  sourceText: string
  section: RuntimeStructuredSection
  disabled?: boolean
  draftDirty?: boolean
  saving?: boolean
  onRoutingChange: (
    lane: 'default' | 'librarian' | 'structured_judge' | 'hitl_summary' | 'cross_verifier',
    runtimeId: string | null,
  ) => void
  onAssignmentChange: (keeperName: string, runtimeId: string | null) => void
  onBindingFieldChange: (
    runtimeId: string,
    field: RuntimeBindingEditableField,
    value: string | number | null,
  ) => void
  onAddProvider: (input: NewRuntimeProviderInput) => void
  onAddModel: (input: NewRuntimeModelInput) => void
  onAddBinding: (providerId: string, modelId: string) => void
  onDeleteProvider: (providerId: string) => void
  onProviderTransportChange: (
    providerId: string,
    field: RuntimeProviderTransportEditableField,
    value: string,
  ) => void
  onProviderCredentialChange: (
    providerId: string,
    credentialType: RuntimeTomlCredentialType,
    value: string,
  ) => void
}

function firstId<T extends { id: string }>(items: T[]): string {
  return items[0]?.id ?? ''
}

function runtimeOptions(environment: RuntimeTomlEnvironment): string[] {
  return environment.bindings.map(binding => binding.id)
}

function credentialValue(provider: RuntimeTomlProvider): string {
  if (provider.credentialType === 'env') return provider.credentialKey
  if (provider.credentialType === 'file') return provider.credentialPath
  if (provider.credentialType === 'inline') return provider.credentialValue
  return ''
}

function transportValue(provider: RuntimeTomlProvider): string {
  if (provider.transportKind === 'command') return provider.command
  return provider.endpoint
}

interface NewProviderDraft {
  id: string
  displayName: string
  protocol: RuntimeTomlProtocol
  transportKind: 'endpoint'
  transportValue: string
  credentialType: RuntimeTomlCredentialType
  credentialValue: string
}

const DEFAULT_NEW_PROVIDER: NewProviderDraft = {
  id: '',
  displayName: '',
  protocol: RUNTIME_TOML_CREATABLE_PROTOCOLS[0],
  transportKind: 'endpoint',
  transportValue: '',
  credentialType: 'env',
  credentialValue: '',
}

// jsonSupport as a 3-way string enum (not boolean|null) because <select> values
// must be strings; 'unset' means omit the key (backend default: unconfirmed).
interface NewModelDraft {
  id: string
  apiName: string
  maxContext: string
  toolsSupport: boolean
  thinkingSupport: boolean
  streaming: boolean
  jsonSupport: 'unset' | 'true' | 'false'
}

const DEFAULT_NEW_MODEL: NewModelDraft = {
  id: '',
  apiName: '',
  maxContext: '',
  toolsSupport: false,
  thinkingSupport: false,
  streaming: true,
  jsonSupport: 'unset',
}

function parseRequiredPositiveInteger(raw: string): number | undefined {
  const trimmed = raw.trim()
  if (!/^\d+$/.test(trimmed)) return undefined
  const parsed = Number.parseInt(trimmed, 10)
  return parsed > 0 ? parsed : undefined
}

function transportField(provider: RuntimeTomlProvider): RuntimeProviderTransportEditableField {
  return provider.transportKind === 'command' ? 'command' : 'endpoint'
}

// Prototype rt-model-ctx label (runtime-editor.jsx:176) — now via the shared
// formatContextTokens SSOT so 1M-class contexts read '1M ctx', not '1000k ctx'.
function protoContext(value: number | null | undefined): string {
  return formatContextTokens(value) ?? '— ctx'
}

function parseOptionalPositiveInteger(raw: string): number | null | undefined {
  const trimmed = raw.trim()
  if (trimmed === '') return null
  if (!/^\d+$/.test(trimmed)) return undefined
  const parsed = Number.parseInt(trimmed, 10)
  return parsed > 0 ? parsed : undefined
}

// rt-cap chip — runtime-editor.jsx:17 rtCapChip. `on` toggles the ✓/· glyph
// and the .on tone (runtime.css:64). Read-only capability readout.
function capChip(on: boolean, label: string) {
  return html`<span class="rt-cap ${on ? 'on' : ''}">${on ? '✓' : '·'} ${label}</span>`
}

interface RuntimeCatalogBindingRow {
  readonly key: string
  readonly label: string
  readonly value: string | null
}

interface RuntimeCatalogBindingResolvedRow extends RuntimeCatalogBindingRow {
  readonly value: string
}

function runtimeCatalogBindingRows(entry: DashboardRuntimeProviderSnapshot): ReadonlyArray<RuntimeCatalogBindingRow> {
  return [
    { key: 'runtime', label: 'runtime catalog', value: entry.runtime_id ?? entry.provider },
    { key: 'provider', label: 'provider', value: entry.provider_display_name ?? entry.provider_id ?? entry.provider },
    { key: 'model', label: 'model', value: entry.model_api_name ?? entry.model_id ?? null },
    { key: 'snapshot', label: 'snapshot', value: runtimeCatalogSnapshotFacts(entry) },
    { key: 'effective', label: 'effective', value: runtimeCatalogEffectiveCapabilities(entry) },
    { key: 'request', label: 'request', value: runtimeCatalogRequestConfig(entry) },
    { key: 'declared', label: 'declared', value: runtimeCatalogDeclaredSpec(entry) },
    { key: 'policy', label: 'policy', value: runtimeCatalogParameterPolicy(entry) },
  ]
}

function RuntimeBindingCatalogSpec({ runtimeId }: { runtimeId: string }) {
  const state = runtimeCatalogState.value
  if (state.status === 'idle' || state.status === 'loading') {
    return html`
      <div class="rt-bind-catalog mono" data-testid=${`runtime-binding-${runtimeId}-catalog-spec`}>
        <span class="rt-bind-catalog-state">runtime catalog loading: ${runtimeId}</span>
      </div>
    `
  }
  if (state.status === 'error') {
    return html`
      <div class="rt-bind-catalog mono" data-testid=${`runtime-binding-${runtimeId}-catalog-spec`}>
        <span class="rt-bind-catalog-state">runtime catalog error for ${runtimeId}: ${state.message}</span>
      </div>
    `
  }
  const entry = findRuntimeCatalogEntry(state.data, runtimeId)
  if (!entry) {
    return html`
      <div class="rt-bind-catalog mono" data-testid=${`runtime-binding-${runtimeId}-catalog-spec`}>
        <span class="rt-bind-catalog-state">runtime catalog missing exact entry: ${runtimeId}</span>
      </div>
    `
  }
  const rows = runtimeCatalogBindingRows(entry).filter((row): row is RuntimeCatalogBindingResolvedRow =>
    typeof row.value === 'string' && row.value.trim() !== '',
  )
  return html`
    <div class="rt-bind-catalog mono" data-testid=${`runtime-binding-${runtimeId}-catalog-spec`}>
      ${rows.map(row => html`
        <div class="rt-bind-catalog-row" data-testid=${`runtime-binding-${runtimeId}-catalog-${row.key}`}>
          <span class="rt-bind-catalog-k">${row.label}</span>
          <span class="rt-bind-catalog-v">${row.value}</span>
        </div>
      `)}
    </div>
  `
}

// keeper.status -> StatusDot tone (bg). Mirrors copilot-dock's run/idle/bad
// split; tone classes are the existing --color-status-* tokens.
function keeperDotTone(status: string): string {
  const normalized = status.toLowerCase()
  if (normalized === 'run' || normalized === 'running' || normalized === 'active') {
    return 'bg-[var(--color-status-ok)]'
  }
  if (normalized === 'pause' || normalized === 'paused' || normalized === 'idle') {
    return 'bg-[var(--color-status-warn)]'
  }
  return 'bg-[var(--color-status-err)]'
}

export function RuntimeEnvironmentEditor({
  sourceText,
  section,
  disabled,
  draftDirty,
  saving,
  onRoutingChange,
  onAssignmentChange,
  onBindingFieldChange,
  onAddProvider,
  onAddModel,
  onAddBinding,
  onDeleteProvider,
  onProviderTransportChange,
  onProviderCredentialChange,
}: RuntimeEnvironmentEditorProps) {
  const environment = useMemo(() => parseRuntimeTomlEnvironment(sourceText), [sourceText])
  const [modelQuery, setModelQuery] = useState('')

  const [providerFormOpen, setProviderFormOpen] = useState(false)
  const [newProvider, setNewProvider] = useState<NewProviderDraft>(DEFAULT_NEW_PROVIDER)
  const [providerFormError, setProviderFormError] = useState<string | null>(null)
  const [providerDeleteError, setProviderDeleteError] = useState<string | null>(null)

  const [modelFormOpen, setModelFormOpen] = useState(false)
  const [newModel, setNewModel] = useState<NewModelDraft>(DEFAULT_NEW_MODEL)
  const [modelFormError, setModelFormError] = useState<string | null>(null)

  const [bindingProviderId, setBindingProviderId] = useState('')
  const [bindingModelId, setBindingModelId] = useState('')
  const [bindingFormError, setBindingFormError] = useState<string | null>(null)

  const runtimeIds = runtimeOptions(environment)
  const isDisabled = disabled === true || saving === true

  const librarianLane = environment.librarianRuntimeId
  const hitlSummaryLane = environment.hitlSummaryRuntimeId
  const crossVerifierLane = environment.crossVerifierRuntimeId
  const assignments = environment.assignments
  const keeperList = keepers.value
  const typedPatchDisabled = isDisabled || draftDirty === true

  const filteredModels = environment.models.filter(model => {
    if (modelQuery.trim() === '') return true
    const query = modelQuery.toLowerCase()
    return model.id.toLowerCase().includes(query) || model.apiName.toLowerCase().includes(query)
  })

  useEffect(() => {
    if (section === 'bindings' && runtimeIds.length > 0) {
      loadRuntimeCatalog()
    }
  }, [section, runtimeIds.length])

  function updateDefault(runtimeId: string) {
    if (runtimeId !== '') onRoutingChange('default', runtimeId)
  }

  function updateRoutingLane(lane: 'librarian' | 'structured_judge' | 'hitl_summary' | 'cross_verifier', runtimeId: string) {
    onRoutingChange(lane, runtimeId === '' ? null : runtimeId)
  }

  function updateAssignment(keeperName: string, runtimeId: string) {
    onAssignmentChange(keeperName, runtimeId)
  }

  function clearAssignment(keeperName: string) {
    onAssignmentChange(keeperName, null)
  }

  function updateBindingNumber(
    runtimeId: string,
    field: 'max-concurrent' | 'num-ctx',
    raw: string,
  ) {
    const next = parseOptionalPositiveInteger(raw)
    if (next === undefined) return
    onBindingFieldChange(runtimeId, field, next)
  }

  function updateBindingKeepAlive(runtimeId: string, raw: string) {
    const next = raw.trim()
    onBindingFieldChange(runtimeId, 'keep-alive', next === '' ? null : next)
  }

  // Shared id checks for the three add-forms below: format (TOML-header-safe),
  // reserved namespace (would collide with providers./models./runtime. etc.),
  // and uniqueness against the current draft (never silently overwrite).
  function runtimeTomlIdError(id: string, taken: readonly string[]): string | null {
    if (id === '') return 'id를 입력하세요'
    if (!isValidRuntimeTomlIdFormat(id)) {
      return 'id는 영문·숫자·-·_ 만 사용할 수 있습니다'
    }
    if (isReservedRuntimeTomlId(id)) return `"${id}"는 예약된 이름입니다`
    if (taken.includes(id)) return `이미 존재하는 id입니다: ${id}`
    return null
  }

  function submitAddProvider() {
    const id = newProvider.id.trim()
    const idError = runtimeTomlIdError(id, environment.providers.map(p => p.id))
    if (idError) {
      setProviderFormError(idError)
      return
    }
    const transportValue = newProvider.transportValue.trim()
    if (transportValue === '') {
      setProviderFormError('endpoint를 입력하세요')
      return
    }
    const trimmedCredentialValue = newProvider.credentialValue.trim()
    if (newProvider.credentialType !== 'none' && trimmedCredentialValue === '') {
      setProviderFormError('credential 값을 입력하거나 credential 타입을 "없음"으로 두세요')
      return
    }
    onAddProvider({
      ...newProvider,
      id,
      displayName: newProvider.displayName.trim(),
      transportValue,
      credentialValue: trimmedCredentialValue,
    })
    setNewProvider(DEFAULT_NEW_PROVIDER)
    setProviderFormError(null)
    setProviderDeleteError(null)
    setProviderFormOpen(false)
  }

  function deleteProvider(providerId: string) {
    const providerBindings = environment.bindings.filter(b => b.providerId === providerId)
    const remainingBindings = environment.bindings.filter(b => b.providerId !== providerId)
    if (providerBindings.length > 0 && remainingBindings.length === 0) {
      setProviderDeleteError(
        '마지막 runtime binding을 가진 provider alias는 삭제할 수 없습니다. 새 provider/model/binding을 먼저 추가하세요.',
      )
      return
    }
    setProviderDeleteError(null)
    onDeleteProvider(providerId)
  }

  function submitAddModel() {
    const id = newModel.id.trim()
    const idError = runtimeTomlIdError(id, environment.models.map(m => m.id))
    if (idError) {
      setModelFormError(idError)
      return
    }
    const maxContext = parseRequiredPositiveInteger(newModel.maxContext)
    if (maxContext === undefined) {
      setModelFormError('max-context는 1 이상의 정수여야 합니다')
      return
    }
    onAddModel({
      id,
      apiName: newModel.apiName.trim(),
      maxContext,
      toolsSupport: newModel.toolsSupport,
      thinkingSupport: newModel.thinkingSupport,
      streaming: newModel.streaming,
      jsonSupport: newModel.jsonSupport === 'unset' ? null : newModel.jsonSupport === 'true',
    })
    setNewModel(DEFAULT_NEW_MODEL)
    setModelFormError(null)
    setModelFormOpen(false)
  }

  function submitAddBinding() {
    if (bindingProviderId === '' || bindingModelId === '') {
      setBindingFormError('provider와 model을 모두 선택하세요')
      return
    }
    // A binding pin is written as a top-level `[providerId.modelId]` table.
    // bindingSections() on read already excludes RESERVED_TOP_LEVEL first
    // segments (providers/models/runtime/...), so a provider id that collides
    // with one of those is silently unreadable after save -- or worse, if the
    // model id also matches an existing `[models.<id>]` model definition, the
    // binding table collides with it outright. New providers can never get a
    // reserved id (runtimeTomlIdError), but this dropdown lists whatever is
    // already in environment.providers, which can include a legacy/hand-edited
    // provider that predates that check -- so guard here too.
    if (isReservedRuntimeTomlId(bindingProviderId)) {
      setBindingFormError(`"${bindingProviderId}"는 예약된 이름이라 바인딩 provider로 쓸 수 없습니다`)
      return
    }
    // A `command` transport provider always resolves to no provider_kind on the
    // backend, so materialize_config's filter_map silently drops any binding
    // pinned to it from the live runtime list. The add-provider form can no
    // longer create one, but this dropdown lists every parsed provider,
    // including a `command` one that already exists via raw TOML / legacy config.
    const selectedProvider = environment.providers.find(p => p.id === bindingProviderId)
    if (selectedProvider?.transportKind === 'command') {
      setBindingFormError(
        `"${bindingProviderId}"는 command(CLI) transport라 바인딩을 생성할 수 없습니다 (백엔드가 아직 CLI provider를 라우팅하지 못합니다)`,
      )
      return
    }
    // Protocol-only non-materialization is limited to Messages_api. Other
    // protocols, including openai-compatible-cli, are valid when the provider
    // uses endpoint/HTTP transport.
    if (selectedProvider && isRuntimeTomlNonMaterializableProtocol(selectedProvider.protocol)) {
      setBindingFormError(
        `"${bindingProviderId}"는 ${selectedProvider.protocol} protocol이라 바인딩을 생성할 수 없습니다 (백엔드가 아직 이 provider를 라우팅하지 못합니다)`,
      )
      return
    }
    const exists = environment.bindings.some(
      b => b.providerId === bindingProviderId && b.modelId === bindingModelId,
    )
    if (exists) {
      setBindingFormError(`이미 존재하는 바인딩입니다: ${bindingProviderId}.${bindingModelId}`)
      return
    }
    onAddBinding(bindingProviderId, bindingModelId)
    setBindingProviderId('')
    setBindingModelId('')
    setBindingFormError(null)
  }

  // rt-select — runtime.css:43. Inline width cap so the 248px min-width never
  // Layout is now handled by keeper-v2/runtime.css (.rt-lane/.rt-lane-c/.rt-select)
  // so the narrow Settings embed stacks label above control instead of squeezing
  // the label to one-word-per-line.

  function laneRow(
    lane: 'default' | 'librarian' | 'structured_judge' | 'hitl_summary' | 'cross_verifier',
    label: string,
    hint: string,
    value: string,
    onChange: (runtimeId: string) => void,
    requirement: 'none' | 'json' | 'structured',
  ) {
    const canUnset = lane !== 'default'
    const binding = environment.bindings.find(b => b.id === value)
    const model = binding ? environment.models.find(m => m.id === binding.modelId) : null
    // structured_judge requires provider-native structured output, not just JSON
    // mode: the server rejects a structured_judge runtime whose model does not
    // declare supports-structured-output (lib/runtime/runtime.ml:142-151, "must
    // declare structured output, not just JSON mode"). librarian / cross_verifier
    // need JSON mode (grounding.md). Both read the already-parsed capability off
    // the model — no /api/v1/providers projection needed.
    const capValue =
      !model || requirement === 'none'
        ? null
        : requirement === 'structured'
          ? (typeof model.structuredOutput === 'boolean' ? model.structuredOutput : null)
          : (typeof model.jsonSupport === 'boolean' ? model.jsonSupport : null)
    const capLabel = requirement === 'structured' ? 'structured output 필요' : 'JSON 모드 필요'
    const capWarning =
      requirement === 'none'
        ? null
        : capValue === false && model
          ? html`<span class="rt-warn">${capLabel} · ${model.apiName} 미지원</span>`
          : (capValue === null && model) || !model
            ? html`<span class="rt-ok">${capLabel} · 모델 capability 미확인</span>`
            : null

    return html`
      <div class="rt-lane">
        <div class="rt-lane-l">
          <div class="rt-lane-lbl">${label}</div>
          <div class="rt-lane-hint">${hint}</div>
        </div>
        <div class="rt-lane-c">
          <select
            class="rt-select mono"
            value=${value}
            disabled=${typedPatchDisabled}
            aria-label=${lane === 'default' ? 'default runtime' : `${lane} runtime`}
            onChange=${(event: Event) => onChange((event.currentTarget as HTMLSelectElement).value)}
          >
            ${canUnset ? html`<option value="">미설정</option>` : null}
            ${runtimeIds.map(id => html`<option value=${id}>${id}</option>`)}
          </select>
          ${capWarning}
        </div>
      </div>
    `
  }

  // Explicit ([runtime.assignments]) entries surfaced first, [runtime].default
  // fallbacks grouped below — the flat alphabetical list made it hard to tell
  // at a glance which keepers actually have a pinned runtime vs. which are
  // just inheriting whatever [runtime].default happens to be.
  const assignmentRows = keeperList.map(keeper => {
    const explicitRuntime = assignments[keeper.name]
    const isPinned = explicitRuntime !== undefined
    const current = explicitRuntime ?? environment.defaultRuntimeId
    return {
      keeper,
      current,
      isPinned,
      matchesDefault: isPinned && explicitRuntime === environment.defaultRuntimeId,
    }
  })
  const pinnedAssignments = assignmentRows.filter(row => row.isPinned)
  const fallbackAssignments = assignmentRows.filter(row => !row.isPinned)

  function assignRow(row: (typeof assignmentRows)[number]) {
    const canPinCurrent = row.current !== ''
    return html`
      <div key=${row.keeper.name} class="rt-assign">
        <span class="rt-assign-k">
          <${StatusDot} size="sm" class=${keeperDotTone(row.keeper.status)} />
          <span class="mono">${row.keeper.name}</span>
        </span>
        <select
          class="rt-select mono"
          value=${row.current}
          disabled=${typedPatchDisabled}
          aria-label=${`${row.keeper.name} 런타임 배정`}
          onChange=${(event: Event) => updateAssignment(row.keeper.name, (event.currentTarget as HTMLSelectElement).value)}
        >
          ${runtimeIds.map(id => html`<option value=${id}>${id}</option>`)}
        </select>
        ${row.isPinned
          ? html`<span class="rt-assign-tag pin mono">
              고정${row.matchesDefault ? ' · default와 같음' : ''}
            </span>`
          : html`<span class="rt-assign-tag mono">↳ default 폴백</span>`}
        ${row.isPinned
          ? html`
              <button
                type="button"
                class="rt-add-cancel"
                disabled=${typedPatchDisabled}
                data-testid=${`runtime-assignment-${row.keeper.name}-clear`}
                onClick=${() => clearAssignment(row.keeper.name)}
              >폴백</button>
            `
          : html`
              <button
                type="button"
                class="rt-save"
                disabled=${typedPatchDisabled || !canPinCurrent}
                data-testid=${`runtime-assignment-${row.keeper.name}-pin-current`}
                onClick=${() => updateAssignment(row.keeper.name, row.current)}
              >고정</button>
            `}
      </div>
    `
  }

  return html`
    <div data-testid="runtime-environment-editor">
      <div class="rt-head-actions" style=${{ justifyContent: 'flex-end', marginBottom: '14px' }}>
        <span class="rt-nav-sub mono" style=${{ marginRight: 'auto' }}>런타임 환경</span>
        <span class="rt-nav-sub mono">${saving ? '저장 중' : 'routing live · providers/bindings draft'}</span>
      </div>

      ${environment.warnings.length > 0 ? html`
        <div class="rt-note" data-testid="runtime-environment-warnings">
          ${environment.warnings.join(' · ')}
        </div>
      ` : null}

      ${runtimeIds.length === 0 ? html`
        <div class="rt-note" data-testid="runtime-environment-empty">
          구조화해서 편집할 provider.model binding이 없습니다. runtime.toml 섹션에서 먼저 추가하세요.
        </div>
      ` : null}

      <!-- routing — runtime-editor.jsx:135-141. default lane is live; librarian /
           structured_judge / hitl_summary / cross_verifier are read from
           [runtime] and written back. -->
      <div class=${section === 'routing' ? '' : 'hidden'} data-testid="runtime-section-routing">
        <div class="rt-note">
          런타임 id = <span class="mono">provider.model</span> (binding key). 레인은 등록된 바인딩 중에서 고릅니다.
        </div>
        ${laneRow(
          'default',
          '기본 런타임',
          '[runtime].default — 배정 없는 keeper가 사용',
          environment.defaultRuntimeId || firstId(environment.bindings),
          updateDefault,
          'none',
        )}
        ${laneRow(
          'librarian',
          'memory-os 라이브러리안',
          '[runtime].librarian — 턴 후 에피소드 추출, JSON 모드 필요',
          librarianLane,
          runtimeId => updateRoutingLane('librarian', runtimeId),
          'json',
        )}
        ${laneRow(
          'structured_judge',
          'structured judge',
          '[runtime].structured_judge — provider-native schema 심판 호출',
          environment.structuredJudgeRuntimeId,
          runtimeId => updateRoutingLane('structured_judge', runtimeId),
          'structured',
        )}
        ${laneRow(
          'hitl_summary',
          'HITL summary',
          '[runtime].hitl_summary — approval context summary',
          hitlSummaryLane,
          runtimeId => updateRoutingLane('hitl_summary', runtimeId),
          'none',
        )}
        ${laneRow(
          'cross_verifier',
          'cross-verifier',
          '[runtime].cross_verifier — 반-합리화 평가, JSON 모드 필요',
          crossVerifierLane,
          runtimeId => updateRoutingLane('cross_verifier', runtimeId),
          'json',
        )}
      </div>

      <!-- providers — runtime-editor.jsx:144-165. Existing providers' endpoint/
           command and credential fields are draft-editable in place (onProvider
           TransportChange/onProviderCredentialChange) and applied through the
           validated Save path. Adding a brand-new provider uses a separate typed
           form below the list instead of reusing those in-place editors — a typo
           while creating a new id can never silently rewrite an already-wired
           provider — but both paths write through the same draft + validated
           save. -->
      <div class=${section === 'providers' ? '' : 'hidden'} data-testid="runtime-section-providers">
        <div class="rt-cards">
          ${providerDeleteError ? html`
            <div class="rt-warn" role="alert" data-testid="runtime-delete-provider-error">${providerDeleteError}</div>
          ` : null}
          ${environment.providers.map(provider => {
            const providerTransportField = transportField(provider)
            return html`
            <div key=${provider.id} class="rt-card" data-testid=${`runtime-provider-${provider.id}`}>
              <div class="rt-card-h">
                <span class="rt-card-id mono">${provider.id}</span>
                <span class="rt-card-name">${provider.displayName}</span>
                <span class="rt-proto mono">${provider.protocol || '—'}</span>
                <button
                  type="button"
                  class="rt-delete-provider"
                  disabled=${isDisabled}
                  data-testid=${`runtime-provider-${provider.id}-delete`}
                  onClick=${() => deleteProvider(provider.id)}
                >삭제</button>
              </div>
              <div class="rt-field">
                <span class="sub-k">${providerTransportField}</span>
                <input
                  class="rt-input mono"
                  value=${transportValue(provider)}
                  disabled=${isDisabled}
                  aria-label=${`${provider.id} provider transport value`}
                  onInput=${(event: Event) => {
                    onProviderTransportChange(
                      provider.id,
                      providerTransportField,
                      (event.currentTarget as HTMLInputElement).value,
                    )
                  }}
                  data-testid=${`runtime-provider-${provider.id}-transport`}
                  data-runtime-provider-transport=${provider.id}
                />
              </div>
              <div class="rt-field">
                <span class="sub-k">credential</span>
                ${provider.credentialType === 'none'
                  ? html`<span class="rt-cred-none mono">없음 (로컬)</span>`
                  : html`
                    <span class="rt-cred">
                      <span class="rt-cred-type mono">${provider.credentialType}</span>
                      <input
                      class="rt-input mono"
                      type=${provider.credentialType === 'inline' ? 'password' : 'text'}
                      value=${credentialValue(provider)}
                      disabled=${isDisabled}
                      aria-label=${`${provider.id} provider credential value`}
                      onInput=${(event: Event) => {
                        onProviderCredentialChange(
                          provider.id,
                          provider.credentialType,
                          (event.currentTarget as HTMLInputElement).value,
                        )
                      }}
                      data-testid=${`runtime-provider-${provider.id}-credential`}
                      data-runtime-provider-credential=${provider.id}
                    />
                  </span>
                  `}
              </div>
              ${/* Provider capability chips (mcp-tools/tool-events/mcp-http-headers)
                   had no live source and rendered as if confirmed. Removed until a
                   provider-capability source exists, rather than implying support
                   with no backing (PR #22081 review P1: no stub). */ ''}
            </div>
            `
          })}
          <div class="rt-card rt-card-add" data-testid="runtime-add-provider-card">
            ${!providerFormOpen ? html`
              <button
                type="button"
                class="rt-add-toggle"
                disabled=${isDisabled}
                data-testid="runtime-add-provider-toggle"
                onClick=${() => setProviderFormOpen(true)}
              >+ 프로바이더 추가</button>
            ` : html`
              <div class="rt-add-form">
                <div class="rt-field">
                  <span class="sub-k">id</span>
                  <input
                    class="rt-input mono"
                    value=${newProvider.id}
                    placeholder="예: my-provider"
                    disabled=${isDisabled}
                    aria-label="새 provider id"
                    data-testid="runtime-add-provider-id"
                    onInput=${(event: Event) => setNewProvider({ ...newProvider, id: (event.currentTarget as HTMLInputElement).value })}
                  />
                </div>
                <div class="rt-field">
                  <span class="sub-k">표시 이름</span>
                  <input
                    class="rt-input"
                    value=${newProvider.displayName}
                    placeholder="비우면 id 사용"
                    disabled=${isDisabled}
                    aria-label="새 provider 표시 이름"
                    onInput=${(event: Event) => setNewProvider({ ...newProvider, displayName: (event.currentTarget as HTMLInputElement).value })}
                  />
                </div>
                <div class="rt-field">
                  <span class="sub-k">protocol</span>
                  <select
                    class="rt-select"
                    value=${newProvider.protocol}
                    disabled=${isDisabled}
                    aria-label="새 provider protocol"
                    onChange=${(event: Event) => setNewProvider({ ...newProvider, protocol: (event.currentTarget as HTMLSelectElement).value as RuntimeTomlProtocol })}
                  >
                    ${RUNTIME_TOML_CREATABLE_PROTOCOLS.map(p => html`<option value=${p}>${p}</option>`)}
                  </select>
                </div>
                <div class="rt-field">
                  <span class="sub-k">endpoint</span>
                  <input
                    class="rt-input mono"
                    value=${newProvider.transportValue}
                    placeholder="https://..."
                    disabled=${isDisabled}
                    aria-label="새 provider transport 값"
                    onInput=${(event: Event) => setNewProvider({ ...newProvider, transportValue: (event.currentTarget as HTMLInputElement).value })}
                  />
                </div>
                <div class="rt-note">CLI(command) provider는 현재 백엔드에서 라우팅되지 않아 이 폼에서 생성할 수 없습니다. raw TOML 탭을 이용하세요.</div>
                <div class="rt-field">
                  <span class="sub-k">credential</span>
                  <select
                    class="rt-select rt-select-narrow"
                    value=${newProvider.credentialType}
                    disabled=${isDisabled}
                    aria-label="새 provider credential 종류"
                    onChange=${(event: Event) => setNewProvider({ ...newProvider, credentialType: (event.currentTarget as HTMLSelectElement).value as RuntimeTomlCredentialType })}
                  >
                    <option value="none">없음</option>
                    <option value="env">env</option>
                    <option value="file">file</option>
                    <option value="inline">inline</option>
                  </select>
                  ${newProvider.credentialType !== 'none' ? html`
                    <input
                      class="rt-input mono"
                      type=${newProvider.credentialType === 'inline' ? 'password' : 'text'}
                      value=${newProvider.credentialValue}
                      placeholder=${newProvider.credentialType === 'env' ? 'ENV 변수명' : newProvider.credentialType === 'file' ? '파일 경로' : '값'}
                      disabled=${isDisabled}
                      aria-label="새 provider credential 값"
                      onInput=${(event: Event) => setNewProvider({ ...newProvider, credentialValue: (event.currentTarget as HTMLInputElement).value })}
                    />
                  ` : null}
                </div>
                ${providerFormError ? html`<div class="rt-warn" role="alert" data-testid="runtime-add-provider-error">${providerFormError}</div>` : null}
                <div class="rt-add-actions">
                  <button
                    type="button"
                    class="rt-save"
                    disabled=${isDisabled}
                    data-testid="runtime-add-provider-submit"
                    onClick=${submitAddProvider}
                  >추가</button>
                  <button
                    type="button"
                    class="rt-add-cancel"
                    disabled=${isDisabled}
                    onClick=${() => { setProviderFormOpen(false); setNewProvider(DEFAULT_NEW_PROVIDER); setProviderFormError(null) }}
                  >취소</button>
                </div>
              </div>
            `}
          </div>
        </div>
      </div>

      <!-- models — runtime-editor.jsx:167-191. search + read-only chips. The
           model parse now reads [models.<id>.capabilities], so tool-choice /
           json / structured / multimodal chips and the effort (thinking-control
           -format) label render from the live config when the key is present. -->
      <div class=${section === 'models' ? '' : 'hidden'} data-testid="runtime-section-models">
        <input
          class="rt-search mono"
          placeholder="모델 검색 — id / api-name"
          value=${modelQuery}
          disabled=${isDisabled}
          aria-label="모델 검색"
          onInput=${(event: Event) => setModelQuery((event.currentTarget as HTMLInputElement).value)}
        />
        <div class="rt-models">
          ${filteredModels.map(model => html`
            <div key=${model.id} class="rt-model">
              <div class="rt-model-h">
                <span class="rt-model-id mono">${model.id}</span>
                <span class="rt-model-api mono">${model.apiName}</span>
                <span class="rt-model-ctx mono">${protoContext(model.maxContext)}</span>
              </div>
              <div class="rt-caps">
                ${capChip(model.toolsSupport, 'tools')}
                ${capChip(model.thinkingSupport, 'thinking')}
                ${capChip(model.streaming, 'streaming')}
                ${/* Capability chips now read the live [models.<id>.capabilities]
                     projection (runtime-toml-config.ts). A chip renders only when
                     the config declared the key; a `null` (absent) capability stays
                     hidden so the card never implies support the config never stated. */ ''}
                ${model.toolChoice !== null ? capChip(model.toolChoice, 'tool-choice') : null}
                ${model.jsonSupport !== null ? capChip(model.jsonSupport, 'json') : null}
                ${model.structuredOutput !== null ? capChip(model.structuredOutput, 'structured') : null}
                ${model.multimodal !== null ? capChip(model.multimodal, 'multimodal') : null}
                <span class="rt-cap tcf mono">effort: ${model.thinkingControlFormat ?? '없음'}</span>
              </div>
              <div class="rt-field" style=${{ marginTop: '9px' }}>
                <span class="sub-k">max-ctx</span>
                <input
                  class="rt-input-sm mono"
                  value=${model.maxContext == null ? '' : String(model.maxContext)}
                  placeholder="—"
                  readOnly
                  aria-label=${`${model.id} max-context`}
                />
              </div>
            </div>
          `)}
          ${filteredModels.length === 0 ? html`
            <div class="rt-note" data-testid="runtime-models-empty">일치하는 모델이 없습니다.</div>
          ` : null}
          <div class="rt-model rt-card-add" data-testid="runtime-add-model-card">
            ${!modelFormOpen ? html`
              <button
                type="button"
                class="rt-add-toggle"
                disabled=${isDisabled}
                data-testid="runtime-add-model-toggle"
                onClick=${() => setModelFormOpen(true)}
              >+ 모델 추가</button>
            ` : html`
              <div class="rt-add-form">
                <div class="rt-field">
                  <span class="sub-k">id</span>
                  <input
                    class="rt-input mono"
                    value=${newModel.id}
                    placeholder="예: my-model"
                    disabled=${isDisabled}
                    aria-label="새 model id"
                    data-testid="runtime-add-model-id"
                    onInput=${(event: Event) => setNewModel({ ...newModel, id: (event.currentTarget as HTMLInputElement).value })}
                  />
                </div>
                <div class="rt-field">
                  <span class="sub-k">api-name</span>
                  <input
                    class="rt-input mono"
                    value=${newModel.apiName}
                    placeholder="비우면 id 사용"
                    disabled=${isDisabled}
                    aria-label="새 model api-name"
                    onInput=${(event: Event) => setNewModel({ ...newModel, apiName: (event.currentTarget as HTMLInputElement).value })}
                  />
                </div>
                <div class="rt-field">
                  <span class="sub-k">max-context</span>
                  <input
                    class="rt-input-sm mono"
                    type="number"
                    min="1"
                    step="1"
                    value=${newModel.maxContext}
                    placeholder="필수"
                    disabled=${isDisabled}
                    aria-label="새 model max-context"
                    data-testid="runtime-add-model-max-context"
                    onInput=${(event: Event) => setNewModel({ ...newModel, maxContext: (event.currentTarget as HTMLInputElement).value })}
                  />
                </div>
                <div class="rt-field">
                  <span class="sub-k">json 지원</span>
                  <select
                    class="rt-select rt-select-narrow"
                    value=${newModel.jsonSupport}
                    disabled=${isDisabled}
                    aria-label="새 model json 지원 여부"
                    onChange=${(event: Event) => setNewModel({ ...newModel, jsonSupport: (event.currentTarget as HTMLSelectElement).value as 'unset' | 'true' | 'false' })}
                  >
                    <option value="unset">미확인</option>
                    <option value="true">지원</option>
                    <option value="false">미지원</option>
                  </select>
                </div>
                <div class="rt-check-row">
                  <label class="rt-check">
                    <input
                      type="checkbox"
                      checked=${newModel.toolsSupport}
                      disabled=${isDisabled}
                      onChange=${(event: Event) => setNewModel({ ...newModel, toolsSupport: (event.currentTarget as HTMLInputElement).checked })}
                    /><span>tools</span>
                  </label>
                  <label class="rt-check">
                    <input
                      type="checkbox"
                      checked=${newModel.thinkingSupport}
                      disabled=${isDisabled}
                      onChange=${(event: Event) => setNewModel({ ...newModel, thinkingSupport: (event.currentTarget as HTMLInputElement).checked })}
                    /><span>thinking</span>
                  </label>
                  <label class="rt-check">
                    <input
                      type="checkbox"
                      checked=${newModel.streaming}
                      disabled=${isDisabled}
                      onChange=${(event: Event) => setNewModel({ ...newModel, streaming: (event.currentTarget as HTMLInputElement).checked })}
                    /><span>streaming</span>
                  </label>
                </div>
                <div class="rt-note">capability 세부 항목(tool-choice, thinking-control-format 등)은 runtime.toml 탭에서 편집하세요.</div>
                ${modelFormError ? html`<div class="rt-warn" role="alert" data-testid="runtime-add-model-error">${modelFormError}</div>` : null}
                <div class="rt-add-actions">
                  <button
                    type="button"
                    class="rt-save"
                    disabled=${isDisabled}
                    data-testid="runtime-add-model-submit"
                    onClick=${submitAddModel}
                  >추가</button>
                  <button
                    type="button"
                    class="rt-add-cancel"
                    disabled=${isDisabled}
                    onClick=${() => { setModelFormOpen(false); setNewModel(DEFAULT_NEW_MODEL); setModelFormError(null) }}
                  >취소</button>
                </div>
              </div>
            `}
          </div>
        </div>
      </div>

      <!-- bindings — runtime-editor.jsx:193-214. radio sets the default runtime;
           max-conc / keep-alive / num-ctx edit the draft runtime.toml and are
           applied through the existing validated Save path. The sub-line shows
           context, the model effort mode, and per-M price when the binding
           declares price-input/price-output (runtime_toml.ml:600-601). -->
      <div class=${section === 'bindings' ? '' : 'hidden'} data-testid="runtime-section-bindings">
        <div class="rt-binds">
          <div class="rt-note">
            바인딩 = 런타임 id <span class="mono">provider.model</span>. 라디오는 기본 런타임을 즉시 적용하고, 숫자/keep-alive 변경은 draft를 만든 뒤 라이브 적용 버튼으로 저장합니다.
          </div>
          <div class="rt-add-form rt-add-binding" data-testid="runtime-add-binding-form">
            <div class="rt-field">
              <span class="sub-k">provider</span>
              <select
                class="rt-select"
                value=${bindingProviderId}
                disabled=${isDisabled}
                aria-label="새 바인딩 provider"
                data-testid="runtime-add-binding-provider"
                onChange=${(event: Event) => setBindingProviderId((event.currentTarget as HTMLSelectElement).value)}
              >
                <option value="">선택</option>
                ${environment.providers.map(p => html`<option value=${p.id}>${p.id}</option>`)}
              </select>
              <span class="mono">.</span>
              <select
                class="rt-select"
                value=${bindingModelId}
                disabled=${isDisabled}
                aria-label="새 바인딩 model"
                data-testid="runtime-add-binding-model"
                onChange=${(event: Event) => setBindingModelId((event.currentTarget as HTMLSelectElement).value)}
              >
                <option value="">선택</option>
                ${environment.models.map(m => html`<option value=${m.id}>${m.id}</option>`)}
              </select>
              <button
                type="button"
                class="rt-save"
                disabled=${isDisabled}
                data-testid="runtime-add-binding-submit"
                onClick=${submitAddBinding}
              >+ 바인딩 추가</button>
            </div>
            ${bindingFormError ? html`<div class="rt-warn" role="alert" data-testid="runtime-add-binding-error">${bindingFormError}</div>` : null}
          </div>
          ${environment.bindings.map(binding => {
            const isDefault = binding.id === environment.defaultRuntimeId || binding.isDefault
            const model = environment.models.find(m => m.id === binding.modelId) ?? null
            return html`
              <div key=${binding.id} class="rt-bind ${isDefault ? 'is-default' : ''}">
                <button
                  type="button"
                  class="rt-radio ${isDefault ? 'on' : ''}"
                  disabled=${typedPatchDisabled}
                  title="기본 런타임으로"
                  aria-label=${`${binding.id} 기본 런타임으로`}
                  aria-pressed=${isDefault}
                  onClick=${() => updateDefault(binding.id)}
                >${isDefault ? '◉' : '○'}</button>
                <div class="rt-bind-main">
                  <div class="rt-bind-key mono">
                    ${binding.id}${isDefault ? html`<span class="rt-default-tag">default</span>` : null}
                  </div>
                  <div class="rt-bind-sub mono">
                    ${protoContext(model?.maxContext ?? null)}${model?.thinkingControlFormat
                      ? html` · effort ${model.thinkingControlFormat}`
                      : null}${binding.priceInput != null
                      ? html` · $${binding.priceInput}/$${binding.priceOutput ?? '—'} per M`
                      : null}
                  </div>
                  <${RuntimeBindingCatalogSpec} runtimeId=${binding.id} />
                </div>
                <div class="rt-bind-fields">
                  <label class="rt-mini">
                    <span>max-conc</span>
                    <input
                      class="rt-input-sm mono"
                      type="number"
                      min="1"
                      step="1"
                      value=${binding.maxConcurrent == null ? '' : String(binding.maxConcurrent)}
                      placeholder="∞"
                      disabled=${isDisabled}
                      aria-label=${`${binding.id} max-concurrent`}
                      onInput=${(event: Event) => updateBindingNumber(binding.id, 'max-concurrent', (event.currentTarget as HTMLInputElement).value)}
                      data-testid=${`runtime-binding-${binding.id}-max-concurrent`}
                    />
                  </label>
                  <label class="rt-mini">
                    <span>keep-alive</span>
                    <input
                      class="rt-input-sm mono"
                      value=${binding.keepAlive}
                      placeholder="—"
                      disabled=${isDisabled}
                      aria-label=${`${binding.id} keep-alive`}
                      onInput=${(event: Event) => updateBindingKeepAlive(binding.id, (event.currentTarget as HTMLInputElement).value)}
                      data-testid=${`runtime-binding-${binding.id}-keep-alive`}
                    />
                  </label>
                  <label class="rt-mini">
                    <span>num-ctx</span>
                    <input
                      class="rt-input-sm mono"
                      type="number"
                      min="1"
                      step="1"
                      value=${binding.numCtx == null ? '' : String(binding.numCtx)}
                      placeholder="—"
                      disabled=${isDisabled}
                      aria-label=${`${binding.id} num-ctx`}
                      onInput=${(event: Event) => updateBindingNumber(binding.id, 'num-ctx', (event.currentTarget as HTMLInputElement).value)}
                      data-testid=${`runtime-binding-${binding.id}-num-ctx`}
                    />
                  </label>
                </div>
              </div>
            `
          })}
        </div>
      </div>

      <!-- assignments — runtime-editor.jsx:216-231. keeper -> runtime id from
           the live keepers signal + [runtime.assignments]. Pinned entries are
           grouped ahead of default-fallback entries so a long keeper list
           doesn't force scanning every row to see who is actually pinned. -->
      <div class=${section === 'assignments' ? '' : 'hidden'} data-testid="runtime-section-assignments">
        <div class="rt-assigns">
          <div class="rt-note">
            [runtime.assignments] — keeper → 런타임 id.
          </div>
          ${keeperList.length === 0 ? html`
            <div class="rt-note" data-testid="runtime-assignments-empty">표시할 keeper가 없습니다.</div>
          ` : html`
            <div class="rt-assign-summary mono" data-testid="runtime-assignments-summary">
              고정 ${pinnedAssignments.length}개 · default 폴백 ${fallbackAssignments.length}개
            </div>
            ${pinnedAssignments.length > 0 ? html`
              <div class="rt-assign-group" data-testid="runtime-assignments-group-pinned">
                <div class="rt-assign-group-h mono">고정 배정</div>
                ${pinnedAssignments.map(row => assignRow(row))}
              </div>
            ` : null}
            ${fallbackAssignments.length > 0 ? html`
              <div class="rt-assign-group" data-testid="runtime-assignments-group-fallback">
                <div class="rt-assign-group-h mono">default 폴백</div>
                ${fallbackAssignments.map(row => assignRow(row))}
              </div>
            ` : null}
          `}
        </div>
      </div>
    </div>
  `
}
