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
  // Git / Worktree — version control presentation only
  { match: n => n.includes('git') || n.includes('worktree'),
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

/** Pretty-print an outer JSON value without interpreting any string fields. */
export function prettyJson(s: string): string | null {
  let parsed: unknown
  try {
    parsed = JSON.parse(s)
  } catch {
    return null
  }
  try {
    return JSON.stringify(parsed, null, 2)
  } catch {
    return s
  }
}

/** Strip `keeper_` and `masc_` prefixes from a tool name for display. */
export function normalizeToolName(name: string): string {
  return name.replace(/^(keeper_|masc_)/, '')
}

// ── Tool subject ────────────────────────────────────────
// A row that carries only the tool name cannot be told apart from the row above
// it: a keeper that runs `Execute` six times renders six identical lines. The
// subject is the argument a reader uses to tell them apart — the command for a
// shell call, the path for a file call, the pattern for a search.
//
// Keys are ordered, not matched by tool name, because the same key means the
// same thing across tools and a name table would need an entry per tool. An
// argument shape with none of these keys returns null and the caller falls back
// to formatArgs, so no call renders with less than it does today.

const SUBJECT_MAX_CHARS = 72

const SUBJECT_KEYS = [
  'argv',        // Execute: ['git', 'fetch', 'origin']
  'script',      // Execute: the command line a shell ran
  'command',
  'cmd',
  'file_path',   // Read / Edit / Write
  'pattern',     // Grep — what it looked for, before where it looked
  'path',        // Grep scope, and the subject for tools that carry no pattern
  'query',       // board search, web search
  'url',
  'target',      // delegate
  'task_id',
  'goal_id',
  'agent_name', // MASC agent/keeper tools: whose record was read
  'keeper_name',
  'post_id',
  'operation_id',
  'sha256',      // artifact read
  'title',
  'action',      // transition
  'status',      // task list filters
  'content',
] as const

/** Objects whose own subject is one level down. Mirrors nested_subject_keys in
 *  lib/keeper/keeper_chat_tool_trail.ml. */
const NESTED_SUBJECT_KEYS = ['identity', 'reference', 'arguments', 'args'] as const

/** Inside one of those, `name` is the subject. Deliberately not in
 *  SUBJECT_KEYS: many tools declare a top-level `name` parameter and promoting
 *  it there would rename their rows too. */
const NESTED_FIRST_KEYS = ['name'] as const

/** Render one argument value as the row's subject text. */
function subjectValue(v: unknown): string | null {
  if (typeof v === 'string') return v.trim() || null
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  if (Array.isArray(v)) {
    // argv: show it the way it was run, not as JSON.
    const parts = v.map(p => (typeof p === 'string' ? p : JSON.stringify(p) ?? '')).filter(Boolean)
    return parts.length > 0 ? parts.join(' ') : null
  }
  if (v && typeof v === 'object') {
    try {
      const s = JSON.stringify(v)
      return s && s !== '{}' ? s : null
    } catch {
      return null
    }
  }
  return null
}

/** Keep the tail of an over-long path: the file name identifies it, the root does not. */
function truncateSubject(s: string): string {
  const flat = s.replace(/\s+/g, ' ').trim()
  if (flat.length <= SUBJECT_MAX_CHARS) return flat
  if (flat.includes('/')) return `…${flat.slice(flat.length - (SUBJECT_MAX_CHARS - 1))}`
  return `${flat.slice(0, SUBJECT_MAX_CHARS - 1)}…`
}

/**
 * The one argument that identifies what a tool call acted on, or null when the
 * argument shape carries none of the known keys.
 */
export function toolSubject(args: Record<string, unknown> | string | undefined | null): string | null {
  if (args === undefined || args === null) return null
  if (typeof args === 'string') {
    const trimmed = args.trim()
    if (!trimmed) return null
    if (!trimmed.startsWith('{')) return truncateSubject(trimmed)
    let parsed: unknown
    try {
      parsed = JSON.parse(trimmed)
    } catch {
      return truncateSubject(trimmed)
    }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return truncateSubject(trimmed)
    return toolSubject(parsed as Record<string, unknown>)
  }
  for (const key of SUBJECT_KEYS) {
    if (!(key in args)) continue
    const rendered = subjectValue(args[key])
    if (rendered) return truncateSubject(rendered)
  }
  // One level down, for objects whose subject is nested. keeper_skill takes an
  // `identity` of {source_id, package_id, name}, and the whole-object fallback
  // below spends the 72-char budget on the envelope -- the `name` value starts
  // past it, so two skills from one source read alike.
  for (const key of NESTED_SUBJECT_KEYS) {
    const inner = args[key]
    if (!inner || typeof inner !== 'object' || Array.isArray(inner)) continue
    const fields = inner as Record<string, unknown>
    for (const innerKey of [...NESTED_FIRST_KEYS, ...SUBJECT_KEYS]) {
      if (!(innerKey in fields)) continue
      const rendered = subjectValue(fields[innerKey])
      if (rendered) return truncateSubject(rendered)
    }
  }
  // The same whole-object fallback the OCaml side has. Without it a row with
  // no known key scrolled back saying only that some tool ran, and the two
  // implementations answered opposite things for the same input -- pinned in
  // opposite directions by their own tests.
  const named = Object.entries(args).filter(([, value]) => subjectValue(value))
  if (named.length === 0) return null
  return truncateSubject(JSON.stringify(Object.fromEntries(named)))
}
