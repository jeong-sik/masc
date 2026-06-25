// Structured read/write of the [fusion] settings inside runtime.toml, for the
// dashboard Settings editor (RFC-0273 §3.2 deferred Settings editor). Reuses the
// line-surgical get/setRuntimeTomlKey helpers — it does NOT reimplement a TOML
// parser/writer (RFC-0273 §3.2 explicitly forbids a parallel writer; comments
// and untouched keys survive). The backend `Runtime.save_config_text` remains
// the validation SSOT (e.g. min_answered range), so this layer only transforms
// text; an invalid value is rejected on save, never silently coerced here.
//
// per_hour_budget is intentionally NOT exposed: RFC-0277 §3 removed the fusion
// activation budget ([fusion.gate].per_hour_budget) from the backend, so editing
// it would be a zombie surface (the key is no longer consumed).
//
// Limitation: get/setRuntimeTomlKey are line-oriented over `key = value` lines
// inside a `[section]` (dotted section names like `fusion.presets.trio` are
// matched as literal headers). Inline tables and multi-line string values are
// out of scope — the fusion keys here are all scalar single-line values.
import { getRuntimeTomlKey, setRuntimeTomlKey } from './runtime-toml-config'

// TOML section/key names, kept in one place rather than inlined at each call
// site (mirrors lib/fusion_core/fusion_config.ml — the OCaml parser is the SSOT
// for the wire names).
const SECTION_FUSION = 'fusion'
const KEY_ENABLED = 'enabled'
const KEY_DEFAULT_PRESET = 'default_preset'
const KEY_MAX_CONCURRENT_PANELS = 'max_concurrent_panels'
const KEY_MIN_ANSWERED = 'min_answered'
const presetSection = (preset: string): string => `${SECTION_FUSION}.presets.${preset}`

export interface FusionSettings {
  readonly enabled: boolean
  readonly defaultPreset: string
  readonly maxConcurrentPanels: number
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

export function readFusionSettings(sourceText: string): FusionSettings {
  const enabled = getRuntimeTomlKey(sourceText, SECTION_FUSION, KEY_ENABLED)
  const preset = unquote(getRuntimeTomlKey(sourceText, SECTION_FUSION, KEY_DEFAULT_PRESET))
  const minAnswered = preset
    ? getRuntimeTomlKey(sourceText, presetSection(preset), KEY_MIN_ANSWERED)
    : undefined
  return {
    enabled: enabled === undefined ? FUSION_SETTINGS_DEFAULTS.enabled : enabled === 'true',
    defaultPreset: preset,
    maxConcurrentPanels: asInt(
      getRuntimeTomlKey(sourceText, SECTION_FUSION, KEY_MAX_CONCURRENT_PANELS),
      FUSION_SETTINGS_DEFAULTS.maxConcurrentPanels,
    ),
    minAnswered: asInt(minAnswered, FUSION_SETTINGS_DEFAULTS.minAnswered),
  }
}

// Apply the settings back into the source text key-by-key. min_answered is only
// written when a default preset is set (it lives on that preset's table). The
// returned text is what gets POSTed to /api/v1/runtime/config/raw.
export function applyFusionSettings(sourceText: string, s: FusionSettings): string {
  let text = sourceText
  text = setRuntimeTomlKey(text, SECTION_FUSION, KEY_ENABLED, s.enabled)
  text = setRuntimeTomlKey(text, SECTION_FUSION, KEY_DEFAULT_PRESET, s.defaultPreset)
  text = setRuntimeTomlKey(text, SECTION_FUSION, KEY_MAX_CONCURRENT_PANELS, s.maxConcurrentPanels)
  if (s.defaultPreset !== '') {
    text = setRuntimeTomlKey(text, presetSection(s.defaultPreset), KEY_MIN_ANSWERED, s.minAnswered)
  }
  return text
}
