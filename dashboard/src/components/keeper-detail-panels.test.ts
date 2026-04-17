import { describe, it, expect } from 'vitest'
import type { PromptSegmentTelemetry } from '../types'
import {
  ctxColor,
  ctxSegmentLabel,
  ctxSegmentColor,
  autonomyHint,
  formatDuration,
  formatFingerprint,
  formatSegmentLabel,
  miniSparkline,
  filterCtxCompositionEntries,
} from './keeper-detail-panels'

// ── ctxColor ──────────────────────────────────────────────────

describe('ctxColor', () => {
  it('returns OK color for low pressure', () => {
    expect(ctxColor(10)).toBe('#22c55e')
    expect(ctxColor(50)).toBe('#22c55e')
    expect(ctxColor(0)).toBe('#22c55e')
  })

  it('returns warn color for 70-85 range', () => {
    expect(ctxColor(71)).toBe('#f59e0b')
    expect(ctxColor(85)).toBe('#f59e0b')
  })

  it('returns critical color above 85', () => {
    expect(ctxColor(86)).toBe('#ef4444')
    expect(ctxColor(100)).toBe('#ef4444')
  })

  it('boundary at exactly 70', () => {
    expect(ctxColor(70)).toBe('#22c55e')
  })
})

// ── ctxSegmentLabel ───────────────────────────────────────────

describe('ctxSegmentLabel', () => {
  it('returns known label for system_prompt', () => {
    expect(ctxSegmentLabel('system_prompt')).toBe('System prompt')
  })

  it('returns known label for dynamic_context', () => {
    expect(ctxSegmentLabel('dynamic_context')).toBe('Turn context')
  })

  it('returns known label for history_tool_use', () => {
    expect(ctxSegmentLabel('history_tool_use')).toBe('History · tool use')
  })

  it('replaces underscores for unknown keys', () => {
    expect(ctxSegmentLabel('some_new_segment')).toBe('some new segment')
  })

  it('replaces hyphens for unknown keys', () => {
    expect(ctxSegmentLabel('some-new-segment')).toBe('some new segment')
  })
})

// ── ctxSegmentColor ───────────────────────────────────────────

describe('ctxSegmentColor', () => {
  it('returns known color for system_prompt', () => {
    expect(ctxSegmentColor('system_prompt')).toBe('#f59e0b')
  })

  it('returns known color for memory_context', () => {
    expect(ctxSegmentColor('memory_context')).toBe('#fb7185')
  })

  it('returns default color for unknown keys', () => {
    expect(ctxSegmentColor('unknown_key')).toBe('#94a3b8')
  })
})

// ── autonomyHint ──────────────────────────────────────────────

describe('autonomyHint', () => {
  it('returns active hint when count is 0 and proactive enabled', () => {
    expect(autonomyHint(0, true)).toBe('활성 · 미발동')
  })

  it('returns disabled hint when count is 0 and proactive disabled', () => {
    expect(autonomyHint(0, false)).toBe('자율 비활성')
  })

  it('returns disabled hint when count is 0 and proactive undefined', () => {
    expect(autonomyHint(0, undefined)).toBe('자율 비활성')
  })

  it('returns undefined when count is positive', () => {
    expect(autonomyHint(5, true)).toBeUndefined()
    expect(autonomyHint(1, false)).toBeUndefined()
  })

  it('returns disabled hint when count is undefined', () => {
    expect(autonomyHint(undefined, undefined)).toBe('자율 비활성')
  })
})

// ── formatDuration ────────────────────────────────────────────

describe('formatDuration', () => {
  it('formats seconds under 60', () => {
    expect(formatDuration(0)).toBe('0초')
    expect(formatDuration(30)).toBe('30초')
    expect(formatDuration(59)).toBe('59초')
  })

  it('formats minutes under 3600', () => {
    expect(formatDuration(60)).toBe('1분')
    expect(formatDuration(120)).toBe('2분')
    expect(formatDuration(3599)).toBe('59분')
  })

  it('formats hours with remaining minutes', () => {
    expect(formatDuration(3600)).toBe('1시간 0분')
    expect(formatDuration(3660)).toBe('1시간 1분')
    expect(formatDuration(7384)).toBe('2시간 3분')
  })
})

// ── formatFingerprint ─────────────────────────────────────────

describe('formatFingerprint', () => {
  it('returns dash for null', () => {
    expect(formatFingerprint(null)).toBe('-')
  })

  it('returns dash for undefined', () => {
    expect(formatFingerprint(undefined)).toBe('-')
  })

  it('returns dash for empty string', () => {
    expect(formatFingerprint('')).toBe('-')
  })

  it('returns short value as-is', () => {
    expect(formatFingerprint('abc123')).toBe('abc123')
  })

  it('truncates long value to 16 chars with ellipsis', () => {
    const long = 'a'.repeat(20)
    expect(formatFingerprint(long)).toBe('a'.repeat(16) + '…')
  })

  it('keeps exactly 16 char value as-is', () => {
    const exact = 'b'.repeat(16)
    expect(formatFingerprint(exact)).toBe(exact)
  })
})

// ── formatSegmentLabel ────────────────────────────────────────

describe('formatSegmentLabel', () => {
  it('replaces underscores with spaces', () => {
    expect(formatSegmentLabel('some_key_name')).toBe('some key name')
  })

  it('replaces hyphens with spaces', () => {
    expect(formatSegmentLabel('some-key-name')).toBe('some key name')
  })

  it('replaces mixed separators', () => {
    expect(formatSegmentLabel('some_key-name')).toBe('some key name')
  })

  it('returns plain text unchanged', () => {
    expect(formatSegmentLabel('plaintext')).toBe('plaintext')
  })
})

// ── miniSparkline ─────────────────────────────────────────────

describe('miniSparkline', () => {
  it('returns empty string for less than 2 data points', () => {
    expect(miniSparkline([])).toBe('')
    expect(miniSparkline([5])).toBe('')
  })

  it('returns space-separated x,y pairs', () => {
    const result = miniSparkline([0, 10])
    const points = result.split(' ')
    expect(points).toHaveLength(2)
    // First point should be at bottom (y close to H-pad)
    // Last point should be at top (y close to pad)
  })

  it('uses maxOverride when provided', () => {
    const a = miniSparkline([5, 10], 100)
    const b = miniSparkline([5, 10], 10)
    // Different maxOverride produces different y values
    expect(a).not.toBe(b)
  })

  it('produces 5 points for 5 data points', () => {
    const result = miniSparkline([1, 2, 3, 4, 5])
    expect(result.split(' ')).toHaveLength(5)
  })

  it('handles all zeros gracefully', () => {
    const result = miniSparkline([0, 0, 0])
    // Math.max(...data, 1) = 1, so y = H - pad - (0/1)*(H-2*pad) = H-pad
    expect(result).toBeTruthy()
    expect(result.split(' ')).toHaveLength(3)
  })
})

// ── filterCtxCompositionEntries ───────────────────────────────

function seg(tokens: number): PromptSegmentTelemetry {
  return { bytes: tokens * 4, estimated_tokens: tokens, fingerprint: null }
}

const ctxSample: ReadonlyArray<readonly [string, PromptSegmentTelemetry]> = [
  ['system_prompt', seg(500)],
  ['memory_context', seg(1200)],
  ['history_tool_use', seg(800)],
  ['history_tool_result', seg(3400)],
  ['history_assistant_text', seg(200)],
  ['user_message', seg(150)],
  ['unattributed', seg(90)],
  ['some_new_segment', seg(40)],
]

describe('filterCtxCompositionEntries', () => {
  it('returns the input reference when query is empty', () => {
    expect(filterCtxCompositionEntries(ctxSample, '')).toBe(ctxSample)
  })

  it('returns the input reference when query is whitespace', () => {
    expect(filterCtxCompositionEntries(ctxSample, '   ')).toBe(ctxSample)
  })

  it('matches case-insensitive substring on raw key', () => {
    const out = filterCtxCompositionEntries(ctxSample, 'HISTORY')
    expect(out.map(([k]) => k)).toEqual([
      'history_tool_use',
      'history_tool_result',
      'history_assistant_text',
    ])
  })

  it('trims the query before matching', () => {
    const out = filterCtxCompositionEntries(ctxSample, '  memory  ')
    expect(out.map(([k]) => k)).toEqual(['memory_context'])
  })

  it('matches human label when raw key misses', () => {
    // Raw key is `system_prompt`, label is `System prompt`.
    // Searching for exactly `system prompt` (with the space) only hits the label.
    const out = filterCtxCompositionEntries(ctxSample, 'system prompt')
    expect(out.map(([k]) => k)).toEqual(['system_prompt'])
  })

  it('matches label for unknown keys via underscore-to-space fallback', () => {
    // `some_new_segment` label is `some new segment` after fallback.
    const out = filterCtxCompositionEntries(ctxSample, 'new segment')
    expect(out.map(([k]) => k)).toEqual(['some_new_segment'])
  })

  it('returns an empty array when nothing matches', () => {
    expect(filterCtxCompositionEntries(ctxSample, 'nonexistent_bucket')).toEqual([])
  })

  it('does not mutate the input array', () => {
    const snapshot = ctxSample.slice()
    filterCtxCompositionEntries(ctxSample, 'history')
    expect(ctxSample).toEqual(snapshot)
    expect(ctxSample).toHaveLength(snapshot.length)
  })

  it('preserves original order of matched entries', () => {
    const out = filterCtxCompositionEntries(ctxSample, 'history')
    expect(out[0]?.[0]).toBe('history_tool_use')
    expect(out[out.length - 1]?.[0]).toBe('history_assistant_text')
  })

  it('matches entries with non-matching tokens when the key contains the needle', () => {
    // `unattributed` segment value is low but key still matches `attrib`.
    const out = filterCtxCompositionEntries(ctxSample, 'attrib')
    expect(out.map(([k]) => k)).toEqual(['unattributed'])
  })

  it('handles an empty input list', () => {
    const empty: ReadonlyArray<readonly [string, PromptSegmentTelemetry]> = []
    expect(filterCtxCompositionEntries(empty, 'history')).toEqual([])
    expect(filterCtxCompositionEntries(empty, '')).toBe(empty)
  })
})
