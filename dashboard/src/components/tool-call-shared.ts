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
