// Shared tool call rendering utilities — used by tool-call-timeline and
// session-trace components.

import { truncate } from '../lib/truncate'

// ── Constants ────────────────────────────────────────────

const DURATION_FAST_MS = 500
const DURATION_SLOW_MS = 2000

const ARGS_PREVIEW_MAX_CHARS = 80
const ARGS_VALUE_MAX_CHARS = 30
const ARGS_MAX_KEYS = 3

// ── Tool categories ─────────────────────────────────────
// Order matters: first match wins. More specific patterns before general ones.

type ToolCategoryEntry = {
  match: (n: string) => boolean
  icon: string
  color: string
  label: string
}

const TOOL_TONE = {
  brass: 'text-[var(--color-brass-fg)]',
  info: 'text-[var(--color-info-fg)]',
  ok: 'text-[var(--color-status-ok)]',
  warn: 'text-[var(--color-warn-fg)]',
  accent: 'text-[var(--color-accent-fg)]',
} as const

const TOOL_CATEGORIES: ToolCategoryEntry[] = [
  // Shell / Bash — execution tools
  { match: n => n.includes('bash') || n.includes('shell'),
    icon: '>', color: 'text-[var(--color-status-ok)]', label: 'shell' },
  // Git / GitHub / Worktree — version control
  { match: n => n.includes('github') || n.includes('git') || n.includes('worktree'),
    icon: 'G', color: TOOL_TONE.brass, label: 'git' },
  // File write / edit — mutations
  { match: n => n.includes('edit') || n.includes('write') || n.includes('delete'),
    icon: 'E', color: 'text-[var(--color-status-warn)]', label: 'edit' },
  // File read / filesystem
  { match: n => n.includes('fs_read') || n.includes('code_read'),
    icon: 'F', color: TOOL_TONE.info, label: 'file' },
  // Board / Social — community interaction
  { match: n => n.includes('board') || n.includes('social'),
    icon: 'B', color: TOOL_TONE.accent, label: 'board' },
  // Search / Read / Library / Symbols
  { match: n => n.includes('search') || n.includes('symbols') || n.includes('library'),
    icon: 'S', color: TOOL_TONE.info, label: 'search' },
  // Voice — audio/speech
  { match: n => n.includes('voice'),
    icon: 'V', color: TOOL_TONE.brass, label: 'voice' },
  // Web — network access
  { match: n => n.includes('web') || n.includes('fetch'),
    icon: 'W', color: TOOL_TONE.info, label: 'web' },
  // Workspace — tasks, transitions, heartbeat
  { match: n => n.includes('task') || n.includes('transition') || n.includes('claim') || n.includes('heartbeat') || n.includes('broadcast'),
    icon: 'C', color: 'text-[var(--color-status-warn)]', label: 'workspace' },
  // Memory — recall, context, memory search
  { match: n => n.includes('memory') || n.includes('recall') || n.includes('context'),
    icon: 'M', color: TOOL_TONE.ok, label: 'memory' },
  // Status / Dashboard — observability
  { match: n => n.includes('status') || n.includes('dashboard') || n.includes('agents') || n.includes('agent_card'),
    icon: 'D', color: TOOL_TONE.info, label: 'status' },
  // Playwright / Browser — browser automation
  { match: n => n.includes('playwright') || n.includes('browser') || n.includes('navigate'),
    icon: 'P', color: TOOL_TONE.warn, label: 'browser' },
  // Read (generic, after more specific patterns)
  { match: n => n.includes('read'),
    icon: 'R', color: TOOL_TONE.info, label: 'read' },
]
const DEFAULT_TOOL_STYLE: Omit<ToolCategoryEntry, 'match'> = { icon: 'T', color: 'text-[var(--color-fg-muted)]', label: 'tool' }

// ── Functions ───────────────────────────────────────────

type ToolCategoryResult = { icon: string; color: string; label: string }

export function toolCategory(name: string): ToolCategoryResult {
  const found = TOOL_CATEGORIES.find(c => c.match(name))
  return found ?? DEFAULT_TOOL_STYLE
}

/** Summarize a list of trajectory entries: total duration, success count, error count. */
export function summarizeEntries(entries: Array<{ duration_ms?: number; error?: string | null }>): {
  totalMs: number
  successCount: number
  errorCount: number
} {
  let totalMs = 0
  let errorCount = 0
  for (const e of entries) {
    totalMs += e.duration_ms ?? 0
    if (e.error) errorCount++
  }
  return { totalMs, successCount: entries.length - errorCount, errorCount }
}

export function durationColor(ms: number): string {
  if (ms < DURATION_FAST_MS) return 'text-[var(--color-status-ok)]'
  if (ms < DURATION_SLOW_MS) return 'text-[var(--color-status-warn)]'
  return 'text-[var(--color-status-err)]'
}

export function formatArgs(args: Record<string, unknown> | string): string {
  if (typeof args === 'string') return truncate(args, ARGS_PREVIEW_MAX_CHARS)
  const keys = Object.keys(args)
  if (keys.length === 0) return '{}'
  const preview = keys.slice(0, ARGS_MAX_KEYS).map(k => {
    const v = args[k]
    const vs = typeof v === 'string'
      ? truncate(v, ARGS_VALUE_MAX_CHARS)
      : truncate(JSON.stringify(v) ?? '', ARGS_VALUE_MAX_CHARS)
    return `${k}: ${vs}`
  }).join(', ')
  return keys.length > ARGS_MAX_KEYS ? `{${preview}, ...}` : `{${preview}}`
}

export function prettyArgs(args: Record<string, unknown> | string): string {
  if (typeof args === 'string') return args
  try { return JSON.stringify(args, null, 2) } catch { return String(args) }
}

// ── Embedded-JSON coercion ───────────────────────────────
// Some tool results carry JSON double-encoded: a human "<label>\n{json}" string.
// Re-serializing such a string with JSON.stringify(..., null, 2) escapes the
// inner newlines back to literal "\n", so the inspector shows backslash-n noise
// instead of structure. These helpers approximate OCaml
// [Tool_result.structured_payload_of_message] so that already-persisted (legacy)
// tool rows render structurally. New tool results are emitted structured at the
// source (board_tool_adapter), so this is a display-side defence for historical
// data, not the primary fix.

function parseJsonContainer(raw: string): unknown | null {
  try {
    const parsed: unknown = JSON.parse(raw)
    return parsed !== null && typeof parsed === 'object' ? parsed : null
  } catch {
    return null
  }
}

/** Mirror of OCaml [Tool_result.structured_payload_of_message.ensure_object]:
 *  bare arrays are wrapped as {items: arr} so the structured payload is always
 *  an object. */
function ensureObject(value: unknown): Record<string, unknown> | null {
  if (value === null || typeof value !== 'object') return null
  if (Array.isArray(value)) return { items: value }
  return value as Record<string, unknown>
}

/** Extract a structured object from a pure-JSON or "<prose>\n{json}" string.
 *  Returns null when no embedded JSON object/array is present. Approximate
 *  mirror of OCaml [Tool_result.structured_payload_of_message]; bare arrays are
 *  wrapped as {items: arr} to match [ensure_object]. */
export function extractEmbeddedJson(message: string): unknown | null {
  const whole = ensureObject(parseJsonContainer(message.trim()))
  if (whole !== null) return whole
  let from = 0
  for (;;) {
    const nl = message.indexOf('\n', from)
    if (nl === -1) return null
    const suffix = message.slice(nl + 1).trim()
    if (suffix === '') {
      from = nl + 1
      continue
    }
    if (suffix[0] === '{' || suffix[0] === '[') {
      const parsed = ensureObject(parseJsonContainer(suffix))
      if (parsed !== null) return parsed
    }
    from = nl + 1
  }
}

/** Extract the JSON from a "<prose>\n{json}" suffix only. Leaves pure-JSON
 *  strings untouched so that legitimate JSON-text values are not restructured. */
function extractEmbeddedJsonSuffix(message: string): unknown | null {
  let from = 0
  for (;;) {
    const nl = message.indexOf('\n', from)
    if (nl === -1) return null
    const suffix = message.slice(nl + 1).trim()
    if (suffix === '') {
      from = nl + 1
      continue
    }
    if (suffix[0] === '{' || suffix[0] === '[') {
      const parsed = ensureObject(parseJsonContainer(suffix))
      if (parsed !== null) return parsed
    }
    from = nl + 1
  }
}

/** Recursively replace string values that embed the legacy "<prose>\n{json}"
 *  double-encoding with the parsed value. Terminates: each extraction turns a
 *  string into a container, and containers are walked once. */
function coerceEmbeddedJson(value: unknown): unknown {
  if (typeof value === 'string') {
    const extracted = extractEmbeddedJsonSuffix(value)
    return extracted === null ? value : coerceEmbeddedJson(extracted)
  }
  if (Array.isArray(value)) return value.map(coerceEmbeddedJson)
  if (value !== null && typeof value === 'object') {
    const out: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      out[k] = coerceEmbeddedJson(v)
    }
    return out
  }
  return value
}

/** Pretty-print a JSON string, recursively un-nesting double-encoded JSON found
 *  in string values. Returns null when the input is not JSON (caller falls back
 *  to the raw text). */
export function prettyJsonDeep(s: string): string | null {
  let parsed: unknown
  try {
    parsed = JSON.parse(s)
  } catch {
    return null
  }
  try {
    return JSON.stringify(coerceEmbeddedJson(parsed), null, 2)
  } catch {
    return s
  }
}

/** Strip `keeper_` and `masc_` prefixes from a tool name for display. */
export function normalizeToolName(name: string): string {
  return name.replace(/^(keeper_|masc_)/, '')
}
