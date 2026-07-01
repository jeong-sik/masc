import { html } from 'htm/preact'
import { useMemo, useState } from 'preact/hooks'
import {
  parseRuntimeTomlEnvironment,
  type RuntimeTomlEnvironment,
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

interface RuntimeEnvironmentEditorProps {
  sourceText: string
  section: RuntimeStructuredSection
  disabled?: boolean
  draftDirty?: boolean
  saving?: boolean
  onRoutingChange: (lane: 'default' | 'librarian' | 'cross_verifier', runtimeId: string | null) => void
  onAssignmentChange: (keeperName: string, runtimeId: string | null) => void
  onBindingFieldChange: (
    runtimeId: string,
    field: RuntimeBindingEditableField,
    value: string | number | null,
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

// Prototype rt-model-ctx label — runtime-editor.jsx:176 `(max/1000).toFixed(0)}k ctx`.
function protoContext(value: number | null | undefined): string {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return '— ctx'
  return `${(value / 1000).toFixed(0)}k ctx`
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
}: RuntimeEnvironmentEditorProps) {
  const environment = useMemo(() => parseRuntimeTomlEnvironment(sourceText), [sourceText])
  const [modelQuery, setModelQuery] = useState('')

  const runtimeIds = runtimeOptions(environment)
  const isDisabled = disabled === true || saving === true

  const librarianLane = environment.librarianRuntimeId
  const crossVerifierLane = environment.crossVerifierRuntimeId
  const assignments = environment.assignments
  const keeperList = keepers.value
  const typedPatchDisabled = isDisabled || draftDirty === true

  const filteredModels = environment.models.filter(model => {
    if (modelQuery.trim() === '') return true
    const query = modelQuery.toLowerCase()
    return model.id.toLowerCase().includes(query) || model.apiName.toLowerCase().includes(query)
  })

  function updateDefault(runtimeId: string) {
    if (runtimeId !== '') onRoutingChange('default', runtimeId)
  }

  function updateRoutingLane(lane: 'librarian' | 'cross_verifier', runtimeId: string) {
    onRoutingChange(lane, runtimeId === '' ? null : runtimeId)
  }

  function updateAssignment(keeperName: string, runtimeId: string) {
    if (runtimeId === environment.defaultRuntimeId) {
      onAssignmentChange(keeperName, null)
      return
    }
    onAssignmentChange(keeperName, runtimeId)
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

  // rt-select — runtime.css:43. Inline width cap so the 248px min-width never
  // Layout is now handled by keeper-v2/runtime.css (.rt-lane/.rt-lane-c/.rt-select)
  // so the narrow Settings embed stacks label above control instead of squeezing
  // the label to one-word-per-line.

  function laneRow(
    lane: 'default' | 'librarian' | 'cross_verifier',
    label: string,
    hint: string,
    value: string,
    onChange: (runtimeId: string) => void,
    needsJson: boolean,
  ) {
    const canUnset = lane !== 'default'
    const binding = environment.bindings.find(b => b.id === value)
    const model = binding ? environment.models.find(m => m.id === binding.modelId) : null
    const hasJsonCap = model ? (typeof model.jsonSupport === 'boolean' ? model.jsonSupport : null) : false
    const capWarning = needsJson && hasJsonCap === false && model
      ? html`<span class="rt-warn">JSON 모드 필요 · ${model.apiName} 미지원</span>`
      : needsJson && hasJsonCap === null && model
        ? html`<span class="rt-ok">JSON 모드 필요 · 모델 capability 미확인</span>`
        : needsJson && !model
          ? html`<span class="rt-ok">JSON 모드 필요 · 모델 capability 미확인</span>`
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
    const current = assignments[keeper.name] ?? environment.defaultRuntimeId
    return { keeper, current, isDefault: current === environment.defaultRuntimeId }
  })
  const pinnedAssignments = assignmentRows.filter(row => !row.isDefault)
  const fallbackAssignments = assignmentRows.filter(row => row.isDefault)

  function assignRow(row: (typeof assignmentRows)[number]) {
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
        ${row.isDefault
          ? html`<span class="rt-assign-tag mono">↳ default 폴백</span>`
          : html`<span class="rt-assign-tag pin mono">고정</span>`}
      </div>
    `
  }

  return html`
    <div data-testid="runtime-environment-editor">
      <div class="rt-head-actions" style=${{ justifyContent: 'flex-end', marginBottom: '14px' }}>
        <span class="rt-nav-sub mono" style=${{ marginRight: 'auto' }}>런타임 환경</span>
        <span class="rt-nav-sub mono">${saving ? '저장 중' : 'routing live · bindings draft'}</span>
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
           cross_verifier are read from [runtime] and written back. -->
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
          false,
        )}
        ${laneRow(
          'librarian',
          'memory-os 라이브러리안',
          '[runtime].librarian — 턴 후 에피소드 추출, JSON 모드 필요',
          librarianLane,
          runtimeId => updateRoutingLane('librarian', runtimeId),
          true,
        )}
        ${laneRow(
          'cross_verifier',
          'cross-verifier',
          '[runtime].cross_verifier — 반-합리화 평가, JSON 모드 필요',
          crossVerifierLane,
          runtimeId => updateRoutingLane('cross_verifier', runtimeId),
          true,
        )}
      </div>

      <!-- providers — runtime-editor.jsx:144-165. Read-only projection. Live
           writes stay behind backend typed routes or the raw editor's validated
           save; this component does not rewrite TOML text. -->
      <div class=${section === 'providers' ? '' : 'hidden'} data-testid="runtime-section-providers">
        <div class="rt-cards">
          ${environment.providers.map(provider => html`
            <div key=${provider.id} class="rt-card">
              <div class="rt-card-h">
                <span class="rt-card-id mono">${provider.id}</span>
                <span class="rt-card-name">${provider.displayName}</span>
                <span class="rt-proto mono">${provider.protocol || '—'}</span>
              </div>
              <div class="rt-field">
                <span class="sub-k">endpoint</span>
                <input
                  class="rt-input mono"
                  value=${transportValue(provider)}
                  readOnly
                  aria-label="provider transport value"
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
                      readOnly
                      aria-label="provider credential value"
                    />
                  </span>
                  `}
              </div>
              ${/* Provider capability chips (mcp-tools/tool-events/mcp-http-headers)
                   had no live source and rendered as if confirmed. Removed until a
                   provider-capability source exists, rather than implying support
                   with no backing (PR #22081 review P1: no stub). */ ''}
            </div>
          `)}
        </div>
      </div>

      <!-- models — runtime-editor.jsx:167-191. search + read-only chips. Live
           model parse exposes tools/thinking/streaming/maxContext only; the
           prototype's json/structured/multimodal/tool-choice/effort chips have
           no live source. -->
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
                ${/* json/structured/multimodal chips had no live source yet rendered
                     styled identically to the real tools/thinking/streaming capChips,
                     implying support. Removed until a model-capability source exists
                     (PR #22081 review P1: no stub). effort stays — it states "미수집"
                     honestly rather than faking a value. */ ''}
                <span class="rt-cap tcf mono" data-stub="no-effort-source">effort: 미수집</span>
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
        </div>
      </div>

      <!-- bindings — runtime-editor.jsx:193-214. radio sets the default runtime;
           max-conc / keep-alive / num-ctx edit the draft runtime.toml and are
           applied through the existing validated Save path. price / effort
           sub-line has no live source. -->
      <div class=${section === 'bindings' ? '' : 'hidden'} data-testid="runtime-section-bindings">
        <div class="rt-binds">
          <div class="rt-note">
            바인딩 = 런타임 id <span class="mono">provider.model</span>. 라디오는 기본 런타임을 즉시 적용하고, 숫자/keep-alive 변경은 draft를 만든 뒤 라이브 적용 버튼으로 저장합니다.
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
                  <div class="rt-bind-sub mono" data-stub="no-price-or-effort-source">
                    ${protoContext(model?.maxContext ?? null)} · 가격/effort 미수집
                  </div>
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
            [runtime.assignments] — keeper → 런타임 id. <span class="mono">default</span>와 같으면 toml에서 생략(폴백).
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
