// Structured read/write of the [fusion] settings inside runtime.toml, for the
// dashboard Settings editor (RFC-0273 §3.2 deferred Settings editor). Reuses the
// line-surgical get/setRuntimeTomlKey helpers — it does NOT reimplement a TOML
// parser/writer (RFC-0273 §3.2 explicitly forbids a parallel writer; comments
// and untouched keys survive). The backend `Runtime.save_config_text` remains
// the validation SSOT (e.g. min_answered range), so this layer only transforms
// text; an invalid value is rejected on save, never silently coerced here.
import { getRuntimeTomlKey, setRuntimeTomlKey } from './runtime-toml-config'

export interface FusionSettings {
  readonly enabled: boolean
  readonly defaultPreset: string
  readonly maxConcurrentPanels: number
  readonly perHourBudget: number
  // min_answered for the default preset (RFC-0252 answered-panel quorum).
  readonly minAnswered: number
}

// Conservative defaults used only when a key is absent from the source — they
// mirror the parser defaults (fusion disabled, quorum 1) rather than inventing
// permissive values.
export const FUSION_SETTINGS_DEFAULTS: FusionSettings = {
  enabled: false,
  defaultPreset: '',
  maxConcurrentPanels: 1,
  perHourBudget: 0,
  minAnswered: 1,
}

function asInt(token: string | undefined, fallback: number): number {
  if (token === undefined) return fallback
  const n = Number(token)
  return Number.isFinite(n) ? Math.trunc(n) : fallback
}

function unquote(token: string | undefined): string {
  if (token === undefined) return ''
  return token.replace(/^"(.*)"$/, '$1')
}

const presetSection = (preset: string): string => `fusion.presets.${preset}`

export function readFusionSettings(sourceText: string): FusionSettings {
  const enabled = getRuntimeTomlKey(sourceText, 'fusion', 'enabled')
  const preset = unquote(getRuntimeTomlKey(sourceText, 'fusion', 'default_preset'))
  const minAnswered = preset
    ? getRuntimeTomlKey(sourceText, presetSection(preset), 'min_answered')
    : undefined
  return {
    enabled: enabled === undefined ? FUSION_SETTINGS_DEFAULTS.enabled : enabled === 'true',
    defaultPreset: preset,
    maxConcurrentPanels: asInt(
      getRuntimeTomlKey(sourceText, 'fusion', 'max_concurrent_panels'),
      FUSION_SETTINGS_DEFAULTS.maxConcurrentPanels,
    ),
    perHourBudget: asInt(
      getRuntimeTomlKey(sourceText, 'fusion.gate', 'per_hour_budget'),
      FUSION_SETTINGS_DEFAULTS.perHourBudget,
    ),
    minAnswered: asInt(minAnswered, FUSION_SETTINGS_DEFAULTS.minAnswered),
  }
}

// Apply the settings back into the source text key-by-key. min_answered is only
// written when a default preset is set (it lives on that preset's table). The
// returned text is what gets POSTed to /api/v1/runtime/config/raw.
export function applyFusionSettings(sourceText: string, s: FusionSettings): string {
  let text = sourceText
  text = setRuntimeTomlKey(text, 'fusion', 'enabled', s.enabled)
  text = setRuntimeTomlKey(text, 'fusion', 'default_preset', s.defaultPreset)
  text = setRuntimeTomlKey(text, 'fusion', 'max_concurrent_panels', s.maxConcurrentPanels)
  text = setRuntimeTomlKey(text, 'fusion.gate', 'per_hour_budget', s.perHourBudget)
  if (s.defaultPreset !== '') {
    text = setRuntimeTomlKey(text, presetSection(s.defaultPreset), 'min_answered', s.minAnswered)
  }
  return text
}
