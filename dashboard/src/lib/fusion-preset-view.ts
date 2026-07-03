// Read-only view of a [fusion.presets.<preset>] table for the Settings fusion
// section (keeper-v2 settings.jsx: trio preset lanes + timeout/max_tool_calls).
//
// This is a display-only reader — it never writes back, so it deliberately does
// NOT live in fusion-settings.ts (whose line-surgical write path forbids
// multi-line values). The preset `panel` value is a possibly multi-line TOML
// array, which the scalar getRuntimeTomlKey helper cannot read; scalar keys
// (judge / timeouts / max_tool_calls_per_panel) reuse getRuntimeTomlKey so the
// section-scoping stays consistent with the rest of the runtime.toml tooling.
//
// The source text is the live runtime.toml already fetched by
// FusionSettingsPanel (fetchRuntimeTomlConfig().source_text); no new endpoint or
// projection is introduced. Absent/malformed values become null/empty rather
// than fabricated defaults, so the UI can show "표시할 구성 없음" honestly.
import { getRuntimeTomlKey } from './runtime-toml-config'

export interface FusionPresetView {
  readonly preset: string
  readonly panel: readonly string[]
  readonly judge: string | null
  readonly panelTimeoutS: number | null
  readonly judgeTimeoutS: number | null
  readonly maxToolCallsPerPanel: number | null
}

const KEY_JUDGE = 'judge'
const KEY_PANEL_TIMEOUT_S = 'panel_timeout_s'
const KEY_JUDGE_TIMEOUT_S = 'judge_timeout_s'
const KEY_MAX_TOOL_CALLS = 'max_tool_calls_per_panel'

function presetSection(preset: string): string {
  return `fusion.presets.${preset}`
}

function escapeForRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

// Body lines of a `[section]`: everything between its header and the next
// section header (or EOF). Used only to locate the multi-line `panel` array.
function sectionBodyLines(sourceText: string, sectionName: string): string[] | null {
  const lines = sourceText.split('\n')
  const headerRe = new RegExp(`^\\s*\\[${escapeForRegExp(sectionName)}\\]\\s*(?:#.*)?$`)
  const anyHeaderRe = /^\s*\[[^\]]+\]\s*(?:#.*)?$/
  let start = -1
  for (let index = 0; index < lines.length; index += 1) {
    if (headerRe.test(lines[index] ?? '')) {
      start = index
      break
    }
  }
  if (start === -1) return null
  const body: string[] = []
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index] ?? ''
    if (anyHeaderRe.test(line)) break
    body.push(line)
  }
  return body
}

// Strip a surrounding TOML basic/literal quote. Preset panel/judge ids are plain
// identifiers (no escapes), so a quote strip is sufficient; unquoted tokens are
// returned as-is after trimming.
function dequote(token: string): string {
  const trimmed = token.trim()
  if (trimmed.length >= 2) {
    const first = trimmed[0]
    const last = trimmed[trimmed.length - 1]
    if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
      return trimmed.slice(1, -1)
    }
  }
  return trimmed
}

// Parse a `key = [ "a", "b" ]` string array that may span multiple lines.
function parseStringArray(bodyLines: string[], key: string): string[] {
  const openRe = new RegExp(`^\\s*${escapeForRegExp(key)}\\s*=\\s*\\[`)
  let openIndex = -1
  for (let index = 0; index < bodyLines.length; index += 1) {
    if (openRe.test(bodyLines[index] ?? '')) {
      openIndex = index
      break
    }
  }
  if (openIndex === -1) return []

  let collected = ''
  for (let index = openIndex; index < bodyLines.length; index += 1) {
    const line = bodyLines[index] ?? ''
    collected += `${line}\n`
    if (line.includes(']')) break
  }
  const openBracket = collected.indexOf('[')
  const closeBracket = collected.lastIndexOf(']')
  if (openBracket === -1 || closeBracket === -1 || closeBracket < openBracket) return []
  const inner = collected.slice(openBracket + 1, closeBracket)
  const tokens = inner.match(/"(?:[^"\\]|\\.)*"|'[^']*'/g) ?? []
  return tokens.map(dequote).filter(value => value !== '')
}

function parseScalarString(sourceText: string, section: string, key: string): string | null {
  const raw = getRuntimeTomlKey(sourceText, section, key)
  if (raw === undefined) return null
  const value = dequote(raw)
  return value === '' ? null : value
}

function parseScalarNumber(sourceText: string, section: string, key: string): number | null {
  const raw = getRuntimeTomlKey(sourceText, section, key)
  if (raw === undefined) return null
  const value = Number(raw.trim())
  return Number.isFinite(value) ? value : null
}

/**
 * Read the read-only view of `[fusion.presets.<preset>]` from runtime.toml text.
 * Returns null when the preset name is empty or the section is absent.
 */
export function readFusionPresetView(sourceText: string, preset: string): FusionPresetView | null {
  const trimmed = preset.trim()
  if (trimmed === '') return null
  const section = presetSection(trimmed)
  const body = sectionBodyLines(sourceText, section)
  if (body === null) return null
  return {
    preset: trimmed,
    panel: parseStringArray(body, 'panel'),
    judge: parseScalarString(sourceText, section, KEY_JUDGE),
    panelTimeoutS: parseScalarNumber(sourceText, section, KEY_PANEL_TIMEOUT_S),
    judgeTimeoutS: parseScalarNumber(sourceText, section, KEY_JUDGE_TIMEOUT_S),
    maxToolCallsPerPanel: parseScalarNumber(sourceText, section, KEY_MAX_TOOL_CALLS),
  }
}
