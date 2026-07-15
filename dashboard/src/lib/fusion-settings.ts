// Structured read/write of the [fusion] settings inside runtime.toml, for the
// dashboard Settings editor (RFC-0273 §3.2 deferred Settings editor). Reuses the
// line-surgical get/setRuntimeTomlKey helpers — it does NOT reimplement a full
// TOML parser/writer (RFC-0273 §3.2 explicitly forbids a parallel writer;
// comments and untouched keys survive). It only parses the scalar tokens it
// owns after getRuntimeTomlKey has isolated them. The backend
// `Runtime.save_config_text` remains the validation SSOT, so this layer only
// transforms text; malformed existing values are
// surfaced as parse errors instead of being rendered as plausible defaults.
//
// Limitation: get/setRuntimeTomlKey are line-oriented over `key = value` lines
// inside a `[section]` (dotted section names like `fusion.presets.trio` are
// matched as literal headers). Inline tables and multi-line string values are
// out of scope — the fusion keys here are all scalar single-line values.
import { deleteRuntimeTomlKey, getRuntimeTomlKey, setRuntimeTomlKey, setRuntimeTomlStringArrayKey } from './runtime-toml-config'

// TOML section/key names, kept in one place rather than inlined at each call
// site (mirrors lib/fusion_core/fusion_config.ml — the OCaml parser is the SSOT
// for the wire names).
const SECTION_FUSION = 'fusion'
const KEY_ENABLED = 'enabled'
const KEY_DEFAULT_PRESET = 'default_preset'
const KEY_PANEL = 'panel'
const KEY_JUDGE = 'judge'
const presetSection = (preset: string): string => `${SECTION_FUSION}.presets.${preset}`

export interface FusionSettings {
  readonly enabled: boolean
  readonly defaultPreset: string
}

export interface FusionPresetComposition {
  readonly preset: string
  readonly panel: readonly string[]
  readonly judge: string
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
// mirror the parser defaults rather than inventing permissive values.
export const FUSION_SETTINGS_DEFAULTS: FusionSettings = {
  enabled: false,
  defaultPreset: '',
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

function parseTomlUnicodeEscape(hex: string): string | null {
  if (!/^[0-9A-Fa-f]+$/.test(hex)) return null
  const codePoint = Number.parseInt(hex, 16)
  if (!Number.isInteger(codePoint) || codePoint > 0x10ffff) return null
  if (codePoint >= 0xd800 && codePoint <= 0xdfff) return null
  return String.fromCodePoint(codePoint)
}

function parseTomlBasicString(token: string, key: string): string | FusionSettingsParseIssue {
  const inner = token.slice(1, -1)
  let parsed = ''
  for (let index = 0; index < inner.length; index += 1) {
    const char = inner[index] ?? ''
    if (char === '"') return issue(key, token, 'invalid quoted string')
    if (char < ' ' && char !== '\t') return issue(key, token, 'invalid quoted string')
    if (char !== '\\') {
      parsed += char
      continue
    }

    index += 1
    const escaped = inner[index]
    if (escaped === undefined) return issue(key, token, 'invalid quoted string')
    switch (escaped) {
      case 'b':
        parsed += '\b'
        break
      case 't':
        parsed += '\t'
        break
      case 'n':
        parsed += '\n'
        break
      case 'f':
        parsed += '\f'
        break
      case 'r':
        parsed += '\r'
        break
      case '"':
        parsed += '"'
        break
      case '\\':
        parsed += '\\'
        break
      case 'u': {
        const hex = inner.slice(index + 1, index + 5)
        const decoded = hex.length === 4 ? parseTomlUnicodeEscape(hex) : null
        if (decoded === null) return issue(key, token, 'invalid unicode escape')
        parsed += decoded
        index += 4
        break
      }
      case 'U': {
        const hex = inner.slice(index + 1, index + 9)
        const decoded = hex.length === 8 ? parseTomlUnicodeEscape(hex) : null
        if (decoded === null) return issue(key, token, 'invalid unicode escape')
        parsed += decoded
        index += 8
        break
      }
      default:
        return issue(key, token, 'unsupported TOML string escape')
    }
  }
  return parsed
}

function parseString(token: string | undefined, fallback: string, key: string): string | FusionSettingsParseIssue {
  if (token === undefined) return fallback
  const trimmed = token.trim()
  if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return parseTomlBasicString(trimmed, key)
  }
  if (trimmed.startsWith("'") && trimmed.endsWith("'")) return trimmed.slice(1, -1)
  return issue(key, token, 'expected a quoted string')
}

function hasArrayOfTables(sourceText: string, sectionName: string, child: string): boolean {
  const escaped = `${sectionName}.${child}`.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(`^\\s*\\[\\[${escaped}\\]\\]\\s*(?:#.*)?$`, 'm').test(sourceText)
}

function uniqueNonEmpty(values: readonly string[]): string[] {
  const seen = new Set<string>()
  const result: string[] = []
  for (const value of values) {
    const trimmed = value.trim()
    if (trimmed === '' || seen.has(trimmed)) continue
    seen.add(trimmed)
    result.push(trimmed)
  }
  return result
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
  if (isParseIssue(enabledParsed)) issues.push(enabledParsed)
  if (isParseIssue(defaultPresetParsed)) issues.push(defaultPresetParsed)
  if (issues.length > 0) return { ok: false, issues }

  const enabled = enabledParsed as boolean
  const defaultPreset = defaultPresetParsed as string
  return {
    ok: true,
    settings: {
      enabled,
      defaultPreset,
    },
  }
}

export function readFusionSettings(sourceText: string): FusionSettings {
  const result = readFusionSettingsResult(sourceText)
  if (result.ok) return result.settings
  throw new Error(`Invalid fusion settings: ${result.issues.map(i => `${i.key}: ${i.message}`).join('; ')}`)
}

export function validateFusionSettings(s: FusionSettings): string[] {
  const errors: string[] = []
  if (s.defaultPreset !== '' && s.defaultPreset.trim() === '') {
    errors.push(`${KEY_DEFAULT_PRESET} must not be whitespace`)
  }
  return errors
}

// Apply the settings back into the source text key-by-key. The returned text is
// what gets POSTed to /api/v1/runtime/config/raw.
export function applyFusionSettings(sourceText: string, s: FusionSettings): string {
  const errors = validateFusionSettings(s)
  if (errors.length > 0) throw new Error(`Invalid fusion settings: ${errors.join('; ')}`)
  let text = sourceText
  text = setRuntimeTomlKey(text, SECTION_FUSION, KEY_ENABLED, s.enabled)
  text = setRuntimeTomlKey(text, SECTION_FUSION, KEY_DEFAULT_PRESET, s.defaultPreset)
  return text
}

export function applyFusionPresetComposition(sourceText: string, composition: FusionPresetComposition): string {
  const preset = composition.preset.trim()
  if (preset === '') throw new Error('fusion preset composition requires a default_preset')
  const section = presetSection(preset)
  if (hasArrayOfTables(sourceText, section, 'panels')) {
    throw new Error('grouped fusion panel presets cannot be edited by the flat preset writer')
  }
  const panel = uniqueNonEmpty(composition.panel)
  let text = sourceText
  text = setRuntimeTomlStringArrayKey(text, section, KEY_PANEL, panel)
  const judge = composition.judge.trim()
  text = judge === ''
    ? deleteRuntimeTomlKey(text, section, KEY_JUDGE)
    : setRuntimeTomlKey(text, section, KEY_JUDGE, judge)
  return text
}
