import type { StopCause, StopCauseSource } from '../types'

function text(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

function humanize(code: string): string {
  return code
    .replace(/[:._-]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value != null && typeof value === 'object' && !Array.isArray(value)
}

function coerceRawStopCause(raw: unknown): StopCause | null {
  if (!isRecord(raw)) return null
  const code = text(raw.code)
  if (!code) return null
  const source = text(raw.source) as StopCauseSource | null
  return {
    code,
    source: source ?? 'terminal_reason_code',
    label: text(raw.label) ?? humanize(code),
    summary: text(raw.summary),
    severity: text(raw.severity),
    next_action: text(raw.next_action),
  }
}

export interface StopCauseInput {
  stop_cause?: unknown
  runtime_blocker_class?: string | null
  runtime_blocker_summary?: string | null
  terminal_reason_code?: string | null
  terminal_reason_summary?: string | null
  terminal_reason_severity?: string | null
  terminal_reason_next_action?: string | null
  stop_reason?: string | null
  error_kind?: string | null
  attention_reason?: string | null
  next_action?: string | null
}

function buildStopCause(
  source: StopCauseSource,
  code: string | null,
  summary: string | null,
  severity: string | null,
  nextAction: string | null,
): StopCause | null {
  if (!code) return null
  return {
    code,
    source,
    label: humanize(code),
    summary,
    severity,
    next_action: nextAction,
  }
}

export function normalizeStopCause(input: StopCauseInput): StopCause | null {
  const explicit = coerceRawStopCause(input.stop_cause)
  if (explicit) return explicit

  return (
    buildStopCause(
      'runtime_blocker_class',
      text(input.runtime_blocker_class),
      text(input.runtime_blocker_summary),
      'warn',
      text(input.next_action),
    )
    ?? buildStopCause(
      'terminal_reason_code',
      text(input.terminal_reason_code),
      text(input.terminal_reason_summary),
      text(input.terminal_reason_severity),
      text(input.terminal_reason_next_action) ?? text(input.next_action),
    )
    ?? buildStopCause(
      'stop_reason',
      text(input.stop_reason),
      null,
      null,
      text(input.next_action),
    )
    ?? buildStopCause(
      'error_kind',
      text(input.error_kind),
      null,
      'bad',
      text(input.next_action),
    )
    ?? buildStopCause(
      'attention_reason',
      text(input.attention_reason),
      null,
      'warn',
      text(input.next_action),
    )
  )
}

