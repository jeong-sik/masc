import { html } from 'htm/preact'
import { Save } from 'lucide-preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import {
  parseRuntimeTomlEnvironment,
  setRuntimeTomlBindingField,
  setRuntimeTomlDefault,
  setRuntimeTomlModelField,
  setRuntimeTomlProviderCredential,
  setRuntimeTomlProviderField,
  type RuntimeTomlBinding,
  type RuntimeTomlCredentialType,
  type RuntimeTomlEnvironment,
  type RuntimeTomlModel,
  type RuntimeTomlProvider,
  type RuntimeTomlTransportKind,
} from '../lib/runtime-toml-config'
import { ActionButton } from './common/button'

interface RuntimeEnvironmentEditorProps {
  sourceText: string
  dirty: boolean
  disabled?: boolean
  saving?: boolean
  onDraftChange: (sourceText: string) => void
  onSave: (sourceText?: string) => void
}

const FIELD_CLASS = 'w-full rounded-[var(--r-1)] border border-[var(--input-border)] bg-[var(--input-bg)] px-2 py-1.5 text-xs text-[var(--color-fg-primary)] outline-none focus:border-[var(--color-accent-fg)]'
const CHECKBOX_CLASS = 'h-4 w-4 rounded-[var(--r-0)] border border-[var(--input-border)] bg-[var(--input-bg)]'

function firstId<T extends { id: string }>(items: T[]): string {
  return items[0]?.id ?? ''
}

function selectedItem<T extends { id: string }>(items: T[], selectedId: string): T | null {
  return items.find(item => item.id === selectedId) ?? items[0] ?? null
}

function numberValue(value: number | null): string {
  return typeof value === 'number' && Number.isFinite(value) ? String(value) : ''
}

function parsePositiveInt(value: string): number | null {
  const parsed = Number.parseInt(value, 10)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null
}

function FieldShell({
  label,
  hint,
  children,
}: {
  label: string
  hint?: string
  children: unknown
}) {
  return html`
    <label class="min-w-0">
      <span class="mb-1 block text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${label}</span>
      ${children}
      ${hint ? html`<span class="mt-1 block text-3xs text-[var(--color-fg-disabled)]">${hint}</span>` : null}
    </label>
  `
}

function ToggleField({
  label,
  checked,
  disabled,
  onChange,
}: {
  label: string
  checked: boolean
  disabled?: boolean
  onChange: (checked: boolean) => void
}) {
  return html`
    <label class="flex min-h-9 items-center justify-between gap-3 rounded-[var(--r-1)] border border-[var(--color-border-subtle)] px-2 py-1.5">
      <span class="text-xs text-[var(--color-fg-secondary)]">${label}</span>
      <input
        type="checkbox"
        class=${CHECKBOX_CLASS}
        checked=${checked}
        disabled=${disabled}
        onChange=${(event: Event) => onChange((event.currentTarget as HTMLInputElement).checked)}
      />
    </label>
  `
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

function credentialLabel(type: RuntimeTomlCredentialType): string {
  if (type === 'env') return 'env key'
  if (type === 'file') return 'file path'
  if (type === 'inline') return 'inline value'
  return 'credential'
}

function transportValue(provider: RuntimeTomlProvider): string {
  if (provider.transportKind === 'command') return provider.command
  return provider.endpoint
}

function SectionTitle({ children }: { children: unknown }) {
  return html`
    <div class="text-2xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-primary)]">
      ${children}
    </div>
  `
}

interface RuntimeCatalogEntry {
  id: string
  binding: RuntimeTomlBinding
  provider: RuntimeTomlProvider | null
  model: RuntimeTomlModel | null
  isDefault: boolean
}

function runtimeCatalogEntries(environment: RuntimeTomlEnvironment): RuntimeCatalogEntry[] {
  return environment.bindings.map(binding => ({
    id: binding.id,
    binding,
    provider: environment.providers.find(provider => provider.id === binding.providerId) ?? null,
    model: environment.models.find(model => model.id === binding.modelId) ?? null,
    isDefault: binding.id === environment.defaultRuntimeId || binding.isDefault,
  }))
}

function compactContext(value: number | null | undefined): string {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return 'ctx -'
  if (value >= 1_000_000) return `${Number.parseFloat((value / 1_000_000).toFixed(1))}M ctx`
  if (value >= 1_000) return `${Math.round(value / 1_000)}K ctx`
  return `${value} ctx`
}

function compactTransport(provider: RuntimeTomlProvider | null): string {
  if (!provider) return 'transport -'
  if (provider.transportKind === 'command') return 'cli'
  if (provider.endpoint.startsWith('http://127.0.0.1') || provider.endpoint.startsWith('http://localhost')) return 'local'
  if (provider.endpoint !== '') return 'cloud'
  return provider.transportKind
}

function boolToken(label: string, value: boolean | undefined): string {
  return `${label}:${value === true ? 'on' : 'off'}`
}

function RuntimeCatalogStrip({
  entries,
  selectedRuntimeId,
  disabled,
  onSelect,
}: {
  entries: RuntimeCatalogEntry[]
  selectedRuntimeId: string
  disabled: boolean
  onSelect: (entry: RuntimeCatalogEntry) => void
}) {
  if (entries.length === 0) return null
  return html`
    <div class="grid gap-2 md:grid-cols-2 xl:grid-cols-3" data-testid="runtime-catalog-strip">
      ${entries.map(entry => {
        const active = entry.id === selectedRuntimeId
        const providerLabel = entry.provider?.displayName || entry.provider?.id || entry.binding.providerId
        const modelLabel = entry.model?.apiName || entry.model?.id || entry.binding.modelId
        return html`
          <button
            type="button"
            class="min-w-0 rounded-[var(--r-1)] border px-3 py-2 text-left transition-colors ${active ? 'border-[var(--color-accent-fg)] bg-[var(--accent-10)]' : 'border-[var(--color-border-subtle)] bg-[var(--color-bg-surface)] hover:border-[var(--color-border-strong)]'}"
            disabled=${disabled}
            onClick=${() => onSelect(entry)}
            aria-pressed=${active}
          >
            <div class="flex items-center justify-between gap-2">
              <span class="truncate font-mono text-xs font-semibold text-[var(--color-fg-primary)]">${entry.id}</span>
              ${entry.isDefault ? html`<span class="shrink-0 rounded-[var(--r-1)] border border-[var(--accent-30)] px-1.5 py-0.5 text-3xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-accent-fg)]">default</span>` : null}
            </div>
            <div class="mt-1 truncate text-xs text-[var(--color-fg-secondary)]">${providerLabel}</div>
            <div class="truncate text-2xs text-[var(--color-fg-muted)]">${modelLabel} · ${compactContext(entry.model?.maxContext)} · ${compactTransport(entry.provider)}</div>
            <div class="mt-1 flex flex-wrap gap-1 text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">
              <span>${boolToken('tools', entry.model?.toolsSupport)}</span>
              <span>${boolToken('thinking', entry.model?.thinkingSupport)}</span>
              <span>${boolToken('stream', entry.model?.streaming)}</span>
              <span>concurrency:${entry.binding.maxConcurrent ?? '-'}</span>
            </div>
          </button>
        `
      })}
    </div>
  `
}

export function RuntimeEnvironmentEditor({
  sourceText,
  dirty,
  disabled,
  saving,
  onDraftChange,
  onSave,
}: RuntimeEnvironmentEditorProps) {
  const environment = useMemo(() => parseRuntimeTomlEnvironment(sourceText), [sourceText])
  const [selectedRuntimeId, setSelectedRuntimeId] = useState('')
  const [selectedProviderId, setSelectedProviderId] = useState('')
  const [selectedModelId, setSelectedModelId] = useState('')

  useEffect(() => {
    const nextRuntimeId = environment.bindings.some(binding => binding.id === selectedRuntimeId)
      ? selectedRuntimeId
      : environment.defaultRuntimeId || firstId(environment.bindings)
    const runtime = environment.bindings.find(binding => binding.id === nextRuntimeId) ?? environment.bindings[0] ?? null
    const nextProviderId = environment.providers.some(provider => provider.id === selectedProviderId)
      ? selectedProviderId
      : runtime?.providerId ?? firstId(environment.providers)
    const nextModelId = environment.models.some(model => model.id === selectedModelId)
      ? selectedModelId
      : runtime?.modelId ?? firstId(environment.models)
    if (nextRuntimeId !== selectedRuntimeId) setSelectedRuntimeId(nextRuntimeId)
    if (nextProviderId !== selectedProviderId) setSelectedProviderId(nextProviderId)
    if (nextModelId !== selectedModelId) setSelectedModelId(nextModelId)
  }, [environment, selectedModelId, selectedProviderId, selectedRuntimeId])

  const bindings = runtimeOptions(environment)
  const selectedRuntime = selectedItem<RuntimeTomlBinding>(environment.bindings, selectedRuntimeId)
  const selectedProvider = selectedItem<RuntimeTomlProvider>(environment.providers, selectedProviderId)
  const selectedModel = selectedItem<RuntimeTomlModel>(environment.models, selectedModelId)
  const isDisabled = disabled === true || saving === true
  const catalogEntries = runtimeCatalogEntries(environment)

  function selectRuntimeEntry(entry: RuntimeCatalogEntry) {
    setSelectedRuntimeId(entry.id)
    setSelectedProviderId(entry.binding.providerId)
    setSelectedModelId(entry.binding.modelId)
  }

  function updateDefault(runtimeId: string) {
    setSelectedRuntimeId(runtimeId)
    const runtime = environment.bindings.find(binding => binding.id === runtimeId)
    if (runtime) {
      setSelectedProviderId(runtime.providerId)
      setSelectedModelId(runtime.modelId)
    }
    onDraftChange(setRuntimeTomlDefault(sourceText, runtimeId))
  }

  function updateProvider(field: 'display-name' | 'protocol' | 'endpoint' | 'command', value: string) {
    if (!selectedProvider) return
    onDraftChange(setRuntimeTomlProviderField(sourceText, selectedProvider.id, field, value))
  }

  function updateProviderTransport(kind: RuntimeTomlTransportKind) {
    if (!selectedProvider || kind === 'missing') return
    const value = kind === 'command'
      ? selectedProvider.command || selectedProvider.endpoint
      : selectedProvider.endpoint || selectedProvider.command
    onDraftChange(setRuntimeTomlProviderField(sourceText, selectedProvider.id, kind, value))
  }

  function updateCredential(type: RuntimeTomlCredentialType, value: string) {
    if (!selectedProvider) return
    onDraftChange(setRuntimeTomlProviderCredential(sourceText, selectedProvider.id, type, value))
  }

  function updateModel(
    field: 'api-name' | 'max-context' | 'tools-support' | 'thinking-support' | 'streaming',
    value: string | number | boolean,
  ) {
    if (!selectedModel) return
    onDraftChange(setRuntimeTomlModelField(sourceText, selectedModel.id, field, value))
  }

  function updateBinding(
    field: 'is-default' | 'max-concurrent' | 'keep-alive' | 'num-ctx',
    value: string | number | boolean | null,
  ) {
    if (!selectedRuntime) return
    onDraftChange(setRuntimeTomlBindingField(sourceText, selectedRuntime.id, field, value))
  }

  return html`
    <div class="v2-monitoring-detail border-t border-[var(--color-border-divider)] pt-3" data-testid="runtime-environment-editor">
      <div class="mb-3 flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
        <div class="min-w-0">
          <div class="text-2xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-accent-fg)]">
            런타임 환경
          </div>
        </div>
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
        <div class="mb-3 rounded-[var(--r-1)] border border-[var(--color-status-warn)]/35 bg-[var(--warn-10)] px-3 py-2 text-xs text-[var(--color-status-warn)]">
          ${environment.warnings.join(' · ')}
        </div>
      ` : null}

      ${bindings.length === 0 ? html`
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-3 py-4 text-xs text-[var(--color-fg-muted)]">
          구조화해서 편집할 provider.model binding이 없습니다. 아래 raw editor에서 runtime.toml을 먼저 추가하세요.
        </div>
      ` : html`
        <div class="mb-3 grid gap-2">
          <${SectionTitle}>런타임 카탈로그<//>
          <${RuntimeCatalogStrip}
            entries=${catalogEntries}
            selectedRuntimeId=${selectedRuntime?.id ?? ''}
            disabled=${isDisabled}
            onSelect=${selectRuntimeEntry}
          />
        </div>
        <div class="grid gap-3 xl:grid-cols-[minmax(16rem,0.8fr)_minmax(0,1.1fr)_minmax(0,1.1fr)_minmax(0,1fr)]">
          <div class="grid content-start gap-3 border-b border-[var(--color-border-divider)] pb-3 xl:border-b-0 xl:border-r xl:pb-0 xl:pr-3">
            <${SectionTitle}>기본 런타임<//>
            <${FieldShell} label="default runtime" hint="runtime.toml [runtime].default">
              <select
                class=${FIELD_CLASS}
                value=${environment.defaultRuntimeId || selectedRuntimeId}
                disabled=${isDisabled}
                aria-label="default runtime"
                onChange=${(event: Event) => updateDefault((event.currentTarget as HTMLSelectElement).value)}
              >
                ${bindings.map(id => html`<option value=${id}>${id}</option>`)}
              </select>
            <//>
            <${FieldShell} label="binding" hint="편집할 provider.model">
              <select
                class=${FIELD_CLASS}
                value=${selectedRuntime?.id ?? ''}
                disabled=${isDisabled}
                aria-label="runtime binding"
                onChange=${(event: Event) => {
                  const runtimeId = (event.currentTarget as HTMLSelectElement).value
                  setSelectedRuntimeId(runtimeId)
                  const runtime = environment.bindings.find(binding => binding.id === runtimeId)
                  if (runtime) {
                    setSelectedProviderId(runtime.providerId)
                    setSelectedModelId(runtime.modelId)
                  }
                }}
              >
                ${bindings.map(id => html`<option value=${id}>${id}</option>`)}
              </select>
            <//>
          </div>

          <div class="grid content-start gap-3 border-b border-[var(--color-border-divider)] pb-3 xl:border-b-0 xl:border-r xl:pb-0 xl:pr-3">
            <${SectionTitle}>Provider 연결<//>
            <${FieldShell} label="provider">
              <select
                class=${FIELD_CLASS}
                value=${selectedProvider?.id ?? ''}
                disabled=${isDisabled}
                aria-label="provider"
                onChange=${(event: Event) => setSelectedProviderId((event.currentTarget as HTMLSelectElement).value)}
              >
                ${environment.providers.map(provider => html`<option value=${provider.id}>${provider.id}</option>`)}
              </select>
            <//>
            <${FieldShell} label="display-name">
              <input
                class=${FIELD_CLASS}
                value=${selectedProvider?.displayName ?? ''}
                disabled=${isDisabled || !selectedProvider}
                aria-label="provider display-name"
                onInput=${(event: Event) => updateProvider('display-name', (event.currentTarget as HTMLInputElement).value)}
              />
            <//>
            <${FieldShell} label="protocol">
              <input
                class=${FIELD_CLASS}
                value=${selectedProvider?.protocol ?? ''}
                disabled=${isDisabled || !selectedProvider}
                aria-label="provider protocol"
                onInput=${(event: Event) => updateProvider('protocol', (event.currentTarget as HTMLInputElement).value)}
              />
            <//>
            <div class="grid grid-cols-[8rem_minmax(0,1fr)] gap-2">
              <${FieldShell} label="transport">
                <select
                  class=${FIELD_CLASS}
                  value=${selectedProvider?.transportKind === 'command' ? 'command' : 'endpoint'}
                  disabled=${isDisabled || !selectedProvider}
                  aria-label="provider transport"
                  onChange=${(event: Event) => updateProviderTransport((event.currentTarget as HTMLSelectElement).value as RuntimeTomlTransportKind)}
                >
                  <option value="endpoint">endpoint</option>
                  <option value="command">command</option>
                </select>
              <//>
              <${FieldShell} label=${selectedProvider?.transportKind === 'command' ? 'command' : 'endpoint'}>
                <input
                  class=${FIELD_CLASS}
                  value=${selectedProvider ? transportValue(selectedProvider) : ''}
                  disabled=${isDisabled || !selectedProvider}
                  aria-label="provider transport value"
                  onInput=${(event: Event) => {
                    const kind = selectedProvider?.transportKind === 'command' ? 'command' : 'endpoint'
                    updateProvider(kind, (event.currentTarget as HTMLInputElement).value)
                  }}
                />
              <//>
            </div>
            <div class="grid grid-cols-[8rem_minmax(0,1fr)] gap-2">
              <${FieldShell} label="credential">
                <select
                  class=${FIELD_CLASS}
                  value=${selectedProvider?.credentialType ?? 'none'}
                  disabled=${isDisabled || !selectedProvider}
                  aria-label="provider credential type"
                  onChange=${(event: Event) => {
                    const type = (event.currentTarget as HTMLSelectElement).value as RuntimeTomlCredentialType
                    updateCredential(type, credentialValue(selectedProvider as RuntimeTomlProvider))
                  }}
                >
                  <option value="none">none</option>
                  <option value="env">env</option>
                  <option value="file">file</option>
                  <option value="inline">inline</option>
                </select>
              <//>
              <${FieldShell} label=${credentialLabel(selectedProvider?.credentialType ?? 'none')}>
                <input
                  class=${FIELD_CLASS}
                  type=${selectedProvider?.credentialType === 'inline' ? 'password' : 'text'}
                  value=${selectedProvider ? credentialValue(selectedProvider) : ''}
                  disabled=${isDisabled || !selectedProvider || selectedProvider.credentialType === 'none'}
                  aria-label="provider credential value"
                  onInput=${(event: Event) => {
                    const type = selectedProvider?.credentialType ?? 'none'
                    updateCredential(type, (event.currentTarget as HTMLInputElement).value)
                  }}
                />
              <//>
            </div>
          </div>

          <div class="grid content-start gap-3 border-b border-[var(--color-border-divider)] pb-3 xl:border-b-0 xl:border-r xl:pb-0 xl:pr-3">
            <${SectionTitle}>Model<//>
            <${FieldShell} label="model">
              <select
                class=${FIELD_CLASS}
                value=${selectedModel?.id ?? ''}
                disabled=${isDisabled}
                aria-label="model"
                onChange=${(event: Event) => setSelectedModelId((event.currentTarget as HTMLSelectElement).value)}
              >
                ${environment.models.map(model => html`<option value=${model.id}>${model.id}</option>`)}
              </select>
            <//>
            <${FieldShell} label="api-name">
              <input
                class=${FIELD_CLASS}
                value=${selectedModel?.apiName ?? ''}
                disabled=${isDisabled || !selectedModel}
                aria-label="model api-name"
                onInput=${(event: Event) => updateModel('api-name', (event.currentTarget as HTMLInputElement).value)}
              />
            <//>
            <${FieldShell} label="max-context">
              <input
                class=${FIELD_CLASS}
                type="number"
                min="1"
                step="1024"
                value=${numberValue(selectedModel?.maxContext ?? null)}
                disabled=${isDisabled || !selectedModel}
                aria-label="model max-context"
                onInput=${(event: Event) => {
                  const parsed = parsePositiveInt((event.currentTarget as HTMLInputElement).value)
                  if (parsed !== null) updateModel('max-context', parsed)
                }}
              />
            <//>
            <${ToggleField}
              label="tools-support"
              checked=${selectedModel?.toolsSupport ?? false}
              disabled=${isDisabled || !selectedModel}
              onChange=${(checked: boolean) => updateModel('tools-support', checked)}
            />
            <${ToggleField}
              label="thinking-support"
              checked=${selectedModel?.thinkingSupport ?? false}
              disabled=${isDisabled || !selectedModel}
              onChange=${(checked: boolean) => updateModel('thinking-support', checked)}
            />
            <${ToggleField}
              label="streaming"
              checked=${selectedModel?.streaming ?? false}
              disabled=${isDisabled || !selectedModel}
              onChange=${(checked: boolean) => updateModel('streaming', checked)}
            />
          </div>

          <div class="grid content-start gap-3">
            <${SectionTitle}>Binding<//>
            <${ToggleField}
              label="is-default"
              checked=${selectedRuntime?.isDefault ?? false}
              disabled=${isDisabled || !selectedRuntime}
              onChange=${(checked: boolean) => updateBinding('is-default', checked)}
            />
            <${FieldShell} label="max-concurrent">
              <input
                class=${FIELD_CLASS}
                type="number"
                min="1"
                step="1"
                value=${numberValue(selectedRuntime?.maxConcurrent ?? null)}
                disabled=${isDisabled || !selectedRuntime}
                aria-label="binding max-concurrent"
                onInput=${(event: Event) => {
                  const parsed = parsePositiveInt((event.currentTarget as HTMLInputElement).value)
                  if (parsed !== null) updateBinding('max-concurrent', parsed)
                }}
              />
            <//>
            <${FieldShell} label="keep-alive">
              <input
                class=${FIELD_CLASS}
                value=${selectedRuntime?.keepAlive ?? ''}
                disabled=${isDisabled || !selectedRuntime}
                placeholder="예: 10m"
                aria-label="binding keep-alive"
                onInput=${(event: Event) => {
                  const value = (event.currentTarget as HTMLInputElement).value
                  updateBinding('keep-alive', value.trim() === '' ? null : value)
                }}
              />
            <//>
            <${FieldShell} label="num-ctx">
              <input
                class=${FIELD_CLASS}
                type="number"
                min="1"
                step="1024"
                value=${numberValue(selectedRuntime?.numCtx ?? null)}
                disabled=${isDisabled || !selectedRuntime}
                aria-label="binding num-ctx"
                onInput=${(event: Event) => {
                  const value = (event.currentTarget as HTMLInputElement).value
                  updateBinding('num-ctx', value.trim() === '' ? null : parsePositiveInt(value))
                }}
              />
            <//>
          </div>
        </div>
      `}
    </div>
  `
}
