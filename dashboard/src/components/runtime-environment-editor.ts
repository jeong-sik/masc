import { html } from 'htm/preact'
import { Save } from 'lucide-preact'
import { useMemo, useState } from 'preact/hooks'
import {
  deleteRuntimeTomlKey,
  parseRuntimeTomlEnvironment,
  setRuntimeTomlBindingField,
  setRuntimeTomlDefault,
  setRuntimeTomlKey,
  setRuntimeTomlProviderCredential,
  setRuntimeTomlProviderField,
  type RuntimeTomlBinding,
  type RuntimeTomlCredentialType,
  type RuntimeTomlEnvironment,
  type RuntimeTomlProvider,
} from '../lib/runtime-toml-config'
import { keepers } from '../store'
import { ActionButton } from './common/button'
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

interface RuntimeEnvironmentEditorProps {
  sourceText: string
  section: RuntimeStructuredSection
  dirty: boolean
  disabled?: boolean
  saving?: boolean
  onDraftChange: (sourceText: string) => void
  onSave: (sourceText?: string) => void
}

function firstId<T extends { id: string }>(items: T[]): string {
  return items[0]?.id ?? ''
}

function parsePositiveInt(value: string): number | null {
  const parsed = Number.parseInt(value, 10)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null
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

// rt-cap chip — runtime-editor.jsx:17 rtCapChip. `on` toggles the ✓/· glyph
// and the .on tone (runtime.css:64). Read-only capability readout.
function capChip(on: boolean, label: string) {
  return html`<span class="rt-cap ${on ? 'on' : ''}">${on ? '✓' : '·'} ${label}</span>`
}

// Read a bare [runtime] string value (librarian / cross_verifier) straight from
// the draft. The parser only surfaces `default`, so the extra routing lanes are
// read here from the same source text the parser consumes. Matches the
// parser's [section] header + key = "value" grammar.
function readRuntimeLaneValue(sourceText: string, key: string): string {
  const lines = sourceText.split('\n')
  let inRuntime = false
  for (const rawLine of lines) {
    const headerMatch = rawLine.match(/^\s*\[([^\]]+)\]\s*(?:#.*)?$/)
    if (headerMatch) {
      inRuntime = headerMatch[1]?.trim() === 'runtime'
      continue
    }
    if (!inRuntime) continue
    const keyMatch = rawLine.match(/^\s*([A-Za-z0-9_-]+)\s*=\s*"([^"]*)"\s*(?:#.*)?$/)
    if (keyMatch && keyMatch[1] === key) return keyMatch[2] ?? ''
  }
  return ''
}

// Read [runtime.assignments] keeper -> runtime id from the draft. Same grammar
// as the parser; surfaces explicit assignments so each keeper row reflects what
// runtime.toml actually pins (and falls back to default when absent).
function readRuntimeAssignments(sourceText: string): Record<string, string> {
  const lines = sourceText.split('\n')
  let inSection = false
  const assignments: Record<string, string> = {}
  for (const rawLine of lines) {
    const headerMatch = rawLine.match(/^\s*\[([^\]]+)\]\s*(?:#.*)?$/)
    if (headerMatch) {
      inSection = headerMatch[1]?.trim() === 'runtime.assignments'
      continue
    }
    if (!inSection) continue
    const keyMatch = rawLine.match(/^\s*([A-Za-z0-9_.-]+)\s*=\s*"([^"]*)"\s*(?:#.*)?$/)
    if (keyMatch?.[1]) assignments[keyMatch[1]] = keyMatch[2] ?? ''
  }
  return assignments
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
  dirty,
  disabled,
  saving,
  onDraftChange,
  onSave,
}: RuntimeEnvironmentEditorProps) {
  const environment = useMemo(() => parseRuntimeTomlEnvironment(sourceText), [sourceText])
  const [modelQuery, setModelQuery] = useState('')

  const runtimeIds = runtimeOptions(environment)
  const isDisabled = disabled === true || saving === true

  const librarianLane = readRuntimeLaneValue(sourceText, 'librarian')
  const crossVerifierLane = readRuntimeLaneValue(sourceText, 'cross_verifier')
  const assignments = readRuntimeAssignments(sourceText)
  const keeperList = keepers.value

  const filteredModels = environment.models.filter(model => {
    if (modelQuery.trim() === '') return true
    const query = modelQuery.toLowerCase()
    return model.id.toLowerCase().includes(query) || model.apiName.toLowerCase().includes(query)
  })

  function updateDefault(runtimeId: string) {
    onDraftChange(setRuntimeTomlDefault(sourceText, runtimeId))
  }

  function updateRoutingLane(lane: 'librarian' | 'cross_verifier', runtimeId: string) {
    onDraftChange(setRuntimeTomlKey(sourceText, 'runtime', lane, runtimeId))
  }

  function updateProvider(providerId: string, field: 'endpoint', value: string) {
    onDraftChange(setRuntimeTomlProviderField(sourceText, providerId, field, value))
  }

  function updateCredential(providerId: string, type: RuntimeTomlCredentialType, value: string) {
    onDraftChange(setRuntimeTomlProviderCredential(sourceText, providerId, type, value))
  }

  function setDefaultBinding(binding: RuntimeTomlBinding) {
    onDraftChange(setRuntimeTomlDefault(sourceText, binding.id))
  }

  function updateBinding(
    runtimeId: string,
    field: 'max-concurrent' | 'num-ctx',
    value: number | null,
  ) {
    onDraftChange(setRuntimeTomlBindingField(sourceText, runtimeId, field, value))
  }

  function updateAssignment(keeperName: string, runtimeId: string) {
    if (runtimeId === environment.defaultRuntimeId) {
      // default == fallback; drop the explicit pin so toml stays minimal.
      onDraftChange(deleteRuntimeTomlKey(sourceText, 'runtime.assignments', keeperName))
      return
    }
    onDraftChange(setRuntimeTomlKey(sourceText, 'runtime.assignments', keeperName, runtimeId))
  }

  // rt-select — runtime.css:43. Inline width cap so the 248px min-width never
  // crushes the flex sibling label in the narrow Settings embed (the prototype
  // ran full-screen). flex-wrap on the row lets the control drop below the
  // label instead of squeezing it to one-word-per-line.
  const selectStyle = { minWidth: 0, maxWidth: '248px', flex: '1 1 200px' }
  const laneStyle = { flexWrap: 'wrap' as const }

  function laneRow(
    lane: 'default' | 'librarian' | 'cross_verifier',
    label: string,
    hint: string,
    value: string,
    onChange: (runtimeId: string) => void,
    needsJson: boolean,
  ) {
    return html`
      <div class="rt-lane" style=${laneStyle}>
        <div class="rt-lane-l">
          <div class="rt-lane-lbl">${label}</div>
          <div class="rt-lane-hint">${hint}</div>
        </div>
        <div class="rt-lane-c">
          <select
            class="rt-select mono"
            style=${selectStyle}
            value=${value}
            disabled=${isDisabled}
            aria-label=${lane === 'default' ? 'default runtime' : `${lane} runtime`}
            onChange=${(event: Event) => onChange((event.currentTarget as HTMLSelectElement).value)}
          >
            ${runtimeIds.map(id => html`<option value=${id}>${id}</option>`)}
          </select>
          ${needsJson
            ? html`<span class="rt-ok" data-stub="no-per-model-json-cap">JSON 모드 필요 · 모델 capability 미수집</span>`
            : null}
        </div>
      </div>
    `
  }

  return html`
    <div data-testid="runtime-environment-editor">
      <div class="rt-head-actions" style=${{ justifyContent: 'flex-end', marginBottom: '14px' }}>
        <span class="rt-nav-sub mono" style=${{ marginRight: 'auto' }}>런타임 환경</span>
        <${ActionButton}
          variant="primary"
          size="sm"
          onClick=${() => onSave(sourceText)}
          disabled=${!dirty || isDisabled}
          ariaBusy=${saving === true}
          ariaLabel="런타임 환경 저장"
          title="런타임 환경 저장"
          testId="runtime-environment-save"
          class="inline-flex shrink-0 items-center gap-1"
        >
          <${Save} size=${13} strokeWidth=${2.25} aria-hidden="true" />
          <span>${saving ? '저장 중' : '환경 저장'}</span>
        <//>
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

      <!-- providers — runtime-editor.jsx:144-165. endpoint + credential editable;
           protocol shown read-only. provider capability chips
           (mcp-tools/tool-events/mcp-http-headers) have no live source. -->
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
                  disabled=${isDisabled}
                  aria-label="provider transport value"
                  onInput=${(event: Event) => updateProvider(provider.id, 'endpoint', (event.currentTarget as HTMLInputElement).value)}
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
                        aria-label="provider credential value"
                        onInput=${(event: Event) => updateCredential(provider.id, provider.credentialType, (event.currentTarget as HTMLInputElement).value)}
                      />
                    </span>
                  `}
              </div>
              <div class="rt-caps" data-stub="no-provider-capability-source">
                <span class="rt-cap">· mcp-tools</span>
                <span class="rt-cap">· tool-events</span>
                <span class="rt-cap">· mcp-http-headers</span>
              </div>
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
                <span class="rt-cap" data-stub="no-json-cap">· json</span>
                <span class="rt-cap" data-stub="no-structured-cap">· structured</span>
                <span class="rt-cap" data-stub="no-multimodal-cap">· multimodal</span>
                <span class="rt-cap tcf mono" data-stub="no-effort-source">effort: 미수집</span>
              </div>
            </div>
          `)}
          ${filteredModels.length === 0 ? html`
            <div class="rt-note" data-testid="runtime-models-empty">일치하는 모델이 없습니다.</div>
          ` : null}
        </div>
      </div>

      <!-- bindings — runtime-editor.jsx:193-214. radio sets the default runtime;
           max-conc / num-ctx editable. price / effort sub-line has no live
           source. -->
      <div class=${section === 'bindings' ? '' : 'hidden'} data-testid="runtime-section-bindings">
        <div class="rt-binds">
          <div class="rt-note">
            바인딩 = 런타임 id <span class="mono">provider.model</span>. 라디오로 기본 런타임 지정.
          </div>
          ${environment.bindings.map(binding => {
            const isDefault = binding.id === environment.defaultRuntimeId || binding.isDefault
            const model = environment.models.find(m => m.id === binding.modelId) ?? null
            return html`
              <div key=${binding.id} class="rt-bind ${isDefault ? 'is-default' : ''}">
                <button
                  type="button"
                  class="rt-radio ${isDefault ? 'on' : ''}"
                  disabled=${isDisabled}
                  title="기본 런타임으로"
                  aria-label=${`${binding.id} 기본 런타임으로`}
                  aria-pressed=${isDefault}
                  onClick=${() => setDefaultBinding(binding)}
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
                      value=${binding.maxConcurrent == null ? '' : String(binding.maxConcurrent)}
                      placeholder="∞"
                      disabled=${isDisabled}
                      aria-label=${`${binding.id} max-concurrent`}
                      onInput=${(event: Event) => {
                        const raw = (event.currentTarget as HTMLInputElement).value
                        updateBinding(binding.id, 'max-concurrent', raw.trim() === '' ? null : parsePositiveInt(raw))
                      }}
                    />
                  </label>
                  <label class="rt-mini">
                    <span>num-ctx</span>
                    <input
                      class="rt-input-sm mono"
                      value=${binding.numCtx == null ? '' : String(binding.numCtx)}
                      placeholder="—"
                      disabled=${isDisabled}
                      aria-label=${`${binding.id} num-ctx`}
                      onInput=${(event: Event) => {
                        const raw = (event.currentTarget as HTMLInputElement).value
                        updateBinding(binding.id, 'num-ctx', raw.trim() === '' ? null : parsePositiveInt(raw))
                      }}
                    />
                  </label>
                </div>
              </div>
            `
          })}
        </div>
      </div>

      <!-- assignments — runtime-editor.jsx:216-231. keeper -> runtime id from
           the live keepers signal + [runtime.assignments]. -->
      <div class=${section === 'assignments' ? '' : 'hidden'} data-testid="runtime-section-assignments">
        <div class="rt-assigns">
          <div class="rt-note">
            [runtime.assignments] — keeper → 런타임 id. <span class="mono">default</span>와 같으면 toml에서 생략(폴백).
          </div>
          ${keeperList.length === 0 ? html`
            <div class="rt-note" data-testid="runtime-assignments-empty">표시할 keeper가 없습니다.</div>
          ` : keeperList.map(keeper => {
            const current = assignments[keeper.name] ?? environment.defaultRuntimeId
            const isDefault = current === environment.defaultRuntimeId
            return html`
              <div key=${keeper.name} class="rt-assign">
                <span class="rt-assign-k">
                  <${StatusDot} size="sm" class=${keeperDotTone(keeper.status)} />
                  <span class="mono">${keeper.name}</span>
                </span>
                <select
                  class="rt-select mono"
                  style=${selectStyle}
                  value=${current}
                  disabled=${isDisabled}
                  aria-label=${`${keeper.name} 런타임 배정`}
                  onChange=${(event: Event) => updateAssignment(keeper.name, (event.currentTarget as HTMLSelectElement).value)}
                >
                  ${runtimeIds.map(id => html`<option value=${id}>${id}</option>`)}
                </select>
                ${isDefault
                  ? html`<span class="rt-assign-tag mono">↳ default 폴백</span>`
                  : html`<span class="rt-assign-tag pin mono">고정</span>`}
              </div>
            `
          })}
        </div>
      </div>
    </div>
  `
}
