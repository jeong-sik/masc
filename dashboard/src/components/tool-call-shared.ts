// Shared tool call rendering utilities — used by keeper-trajectory-timeline
// and tool-call-timeline components.

import { truncate } from '../lib/truncate'

// ── Constants ────────────────────────────────────────────

export const DURATION_FAST_MS = 500
export const DURATION_SLOW_MS = 2000

const ARGS_PREVIEW_MAX_CHARS = 80
const ARGS_VALUE_MAX_CHARS = 30
const ARGS_MAX_KEYS = 3

// ── Tool categories ─────────────────────────────────────

export const TOOL_CATEGORIES: Array<{ match: (n: string) => boolean; icon: string; color: string }> = [
  { match: n => n.includes('bash'),                          icon: '>', color: 'text-[var(--ok)]' },
  { match: n => n.includes('edit') || n.includes('fs'),      icon: 'E', color: 'text-[var(--warn)]' },
  { match: n => n.includes('board') || n.includes('social'), icon: 'B', color: 'text-[var(--purple)]' },
  { match: n => n.includes('github'),                        icon: 'G', color: 'text-[var(--accent)]' },
  { match: n => n.includes('search') || n.includes('read'),  icon: 'R', color: 'text-[#60a5fa]' },
]
export const DEFAULT_TOOL_STYLE = { icon: 'T', color: 'text-[#94a3b8]' }

// ── Functions ───────────────────────────────────────────

export function toolCategory(name: string): { icon: string; color: string } {
  return TOOL_CATEGORIES.find(c => c.match(name)) ?? DEFAULT_TOOL_STYLE
}

export function durationColor(ms: number): string {
  if (ms < DURATION_FAST_MS) return 'text-[var(--ok)]'
  if (ms < DURATION_SLOW_MS) return 'text-[var(--warn)]'
  return 'text-[var(--bad)]'
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

export function formatResult(result: string | null, error: string | null, maxLen = 80): string {
  if (error) return `err: ${truncate(error, maxLen)}`
  if (!result) return '-'
  return truncate(result, maxLen)
}

export function prettyArgs(args: Record<string, unknown> | string): string {
  if (typeof args === 'string') return args
  try { return JSON.stringify(args, null, 2) } catch { return String(args) }
}
