// Structured read/write of the [fusion] settings inside runtime.toml, for the
// dashboard Settings editor (RFC-0273 §3.2 deferred Settings editor). Reuses the
// line-surgical get/setRuntimeTomlKey helpers — it does NOT reimplement a TOML
// parser/writer (RFC-0273 §3.2 explicitly forbids a parallel writer; comments
// and untouched keys survive). The backend `Runtime.save_config_text` remains
// the validation SSOT (e.g. min_answered range), so this layer only transforms
// text; malformed existing values are surfaced as parse errors instead of being
// rendered as plausible defaults.
//
// per_hour_budget is intentionally NOT exposed: RFC-0277 §3 removed the fusion
// activation budget ([fusion.gate].per_hour_budget) from the backend, so editing
// it would be a zombie surface (the key is no longer consumed).
//
// Limitation: get/setRuntimeTomlKey are line-oriented over `key = value` lines
// inside a `[section]` (dotted section names like `fusion.presets.trio` are
// matched as literal headers). Inline tables and multi-line string values are
// out of scope — the fusion keys here are all scalar single-line values.
import { deleteRuntimeTomlKey, getRuntimeTomlKey, setRuntimeTomlKey } from './runtime-toml-config'

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

export interface FusionSettingsParseIssue {
  readonly key: string
  readonly token: string | undefined
  readonly message: string
}

export type FusionSettingsReadResult =
  | { readonly ok: true; readonly settings: FusionSettings }
  | { readonly ok: false; readonly issues: readonly FusionSettingsParseIssue[] }

// Conservative defaults used only when a key is absent from the source — they
// mirror the parser defaults (fusion disabled, quorum 1) rather than inventing
// permissive values.
export const FUSION_SETTINGS_DEFAULTS: FusionSettings = {
  enabled: false,
  defaultPreset: '',
  maxConcurrentPanels: 1,
  minAnswered: 1,
}

function issue(key: string, token: string | undefined, message: string): FusionSettingsParseIssue {
  return { key, token, message }
}

function isParseIssue(value: unknown): value is FusionSettingsParseIssue {
  return typeof value === 'object' && value !== null && 'key' in value && 'message' in value
}

function parseBoolean(token: string | undefined, fallback: boolean, key: string): boolean | FusionSettingsParseIssue {
  if (token === undefined) return fallback
  if (token === 'true') return true
  if (token === 'false') return false
  return issue(key, token, 'expected true or false')
}

function parsePositiveInt(token: string | undefined, fallback: number, key: string): number | FusionSettingsParseIssue {
  if (token === undefined) return fallback
  if (!/^-?\d+$/.test(token)) return issue(key, token, 'expected an integer')
  const value = Number.parseInt(token, 10)
  if (!Number.isSafeInteger(value) || value < 1) return issue(key, token, 'expected an integer >= 1')
  return value
}

function parseString(token: string | undefined, fallback: string, key: string): string | FusionSettingsParseIssue {
  if (token === undefined) return fallback
  const trimmed = token.trim()
  if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
    try {
      const parsed = JSON.parse(trimmed) as unknown
      return typeof parsed === 'string' ? parsed : issue(key, token, 'expected a string')
    } catch {
      return issue(key, token, 'invalid quoted string')
    }
  }
  if (trimmed.startsWith("'") && trimmed.endsWith("'")) return trimmed.slice(1, -1)
  return issue(key, token, 'expected a quoted string')
}

function sectionExists(sourceText: string, sectionName: string): boolean {
  const escaped = sectionName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(`^\\s*\\[${escaped}\\]\\s*(?:#.*)?$`, 'm').test(sourceText)
}

export function readFusionSettingsResult(sourceText: string): FusionSettingsReadResult {
  const issues: FusionSettingsParseIssue[] = []
  const enabledParsed = parseBoolean(
    getRuntimeTomlKey(sourceText, SECTION_FUSION, KEY_ENABLED),
    FUSION_SETTINGS_DEFAULTS.enabled,
    `${SECTION_FUSION}.${KEY_ENABLED}`,
  )
  const defaultPresetParsed = parseString(
    getRuntimeTomlKey(sourceText, SECTION_FUSION, KEY_DEFAULT_PRESET),
    FUSION_SETTINGS_DEFAULTS.defaultPreset,
    `${SECTION_FUSION}.${KEY_DEFAULT_PRESET}`,
  )
  const maxConcurrentPanelsParsed = parsePositiveInt(
    getRuntimeTomlKey(sourceText, SECTION_FUSION, KEY_MAX_CONCURRENT_PANELS),
    FUSION_SETTINGS_DEFAULTS.maxConcurrentPanels,
    `${SECTION_FUSION}.${KEY_MAX_CONCURRENT_PANELS}`,
  )
  if (isParseIssue(enabledParsed)) issues.push(enabledParsed)
  if (isParseIssue(defaultPresetParsed)) issues.push(defaultPresetParsed)
  if (isParseIssue(maxConcurrentPanelsParsed)) issues.push(maxConcurrentPanelsParsed)
  if (issues.length > 0) return { ok: false, issues }

  const enabled = enabledParsed as boolean
  const defaultPreset = defaultPresetParsed as string
  const maxConcurrentPanels = maxConcurrentPanelsParsed as number
  const preset = defaultPreset
  const presetExists = preset !== '' && sectionExists(sourceText, presetSection(preset))
  if (enabled && preset !== '' && !presetExists) {
    issues.push(issue(`${presetSection(preset)}.${KEY_MIN_ANSWERED}`, undefined, 'default_preset references a missing preset section'))
  }
  const minAnsweredToken = preset && presetExists
    ? getRuntimeTomlKey(sourceText, presetSection(preset), KEY_MIN_ANSWERED)
    : undefined
  const minAnsweredParsed = parsePositiveInt(
    minAnsweredToken,
    FUSION_SETTINGS_DEFAULTS.minAnswered,
    `${presetSection(preset || '<default>')}.${KEY_MIN_ANSWERED}`,
  )
  if (isParseIssue(minAnsweredParsed)) issues.push(minAnsweredParsed)
  if (issues.length > 0) return { ok: false, issues }
  const minAnswered = minAnsweredParsed as number

  return {
    ok: true,
    settings: {
      enabled,
      defaultPreset,
      maxConcurrentPanels,
      minAnswered,
    },
  }
}

export function readFusionSettings(sourceText: string): FusionSettings {
  const result = readFusionSettingsResult(sourceText)
  if (result.ok) return result.settings
  throw new Error(`Invalid fusion settings: ${result.issues.map(i => `${i.key}: ${i.message}`).join('; ')}`)
}

export function readFusionPresetMinAnswered(sourceText: string, preset: string): number | FusionSettingsParseIssue {
  const trimmed = preset.trim()
  if (trimmed === '') return FUSION_SETTINGS_DEFAULTS.minAnswered
  const section = presetSection(trimmed)
  if (!sectionExists(sourceText, section)) return FUSION_SETTINGS_DEFAULTS.minAnswered
  return parsePositiveInt(
    getRuntimeTomlKey(sourceText, section, KEY_MIN_ANSWERED),
    FUSION_SETTINGS_DEFAULTS.minAnswered,
    `${section}.${KEY_MIN_ANSWERED}`,
  )
}

export function validateFusionSettings(s: FusionSettings): string[] {
  const errors: string[] = []
  if (!Number.isSafeInteger(s.maxConcurrentPanels) || s.maxConcurrentPanels < 1) {
    errors.push(`${KEY_MAX_CONCURRENT_PANELS} must be an integer >= 1`)
  }
  if (s.defaultPreset !== '' && s.defaultPreset.trim() === '') {
    errors.push(`${KEY_DEFAULT_PRESET} must not be whitespace`)
  }
  if (!Number.isSafeInteger(s.minAnswered) || s.minAnswered < 1) {
    errors.push(`${KEY_MIN_ANSWERED} must be an integer >= 1`)
  }
  return errors
}

function previousDefaultPreset(sourceText: string): string {
  const parsed = parseString(
    getRuntimeTomlKey(sourceText, SECTION_FUSION, KEY_DEFAULT_PRESET),
    FUSION_SETTINGS_DEFAULTS.defaultPreset,
    `${SECTION_FUSION}.${KEY_DEFAULT_PRESET}`,
  )
  return typeof parsed === 'string' ? parsed : FUSION_SETTINGS_DEFAULTS.defaultPreset
}

// Apply the settings back into the source text key-by-key. min_answered is only
// written when a default preset is set (it lives on that preset's table). The
// returned text is what gets POSTed to /api/v1/runtime/config/raw.
export function applyFusionSettings(sourceText: string, s: FusionSettings): string {
  const errors = validateFusionSettings(s)
  if (errors.length > 0) throw new Error(`Invalid fusion settings: ${errors.join('; ')}`)
  const previousPreset = previousDefaultPreset(sourceText)
  let text = sourceText
  text = setRuntimeTomlKey(text, SECTION_FUSION, KEY_ENABLED, s.enabled)
  text = setRuntimeTomlKey(text, SECTION_FUSION, KEY_DEFAULT_PRESET, s.defaultPreset)
  text = setRuntimeTomlKey(text, SECTION_FUSION, KEY_MAX_CONCURRENT_PANELS, s.maxConcurrentPanels)
  if (previousPreset !== '' && previousPreset !== s.defaultPreset) {
    text = deleteRuntimeTomlKey(text, presetSection(previousPreset), KEY_MIN_ANSWERED)
  }
  if (s.defaultPreset !== '') {
    text = setRuntimeTomlKey(text, presetSection(s.defaultPreset), KEY_MIN_ANSWERED, s.minAnswered)
  }
  return text
}
