import { describe, expect, it } from 'vitest'
import { filterRoomActivity, keeperChatTargetName } from './agent-profile'

describe('keeperChatTargetName', () => {
  it('prefers the canonical keeper name over the runtime agent name', () => {
    expect(
      keeperChatTargetName('keeper-tool-test-agent', { name: 'tool-test' }),
    ).toBe('tool-test')
  })

  it('falls back to the provided name when no keeper mapping exists', () => {
    expect(keeperChatTargetName('plain-agent', null)).toBe('plain-agent')
  })
})

describe('filterRoomActivity', () => {
  const lines: readonly string[] = [
    '[task] dreamer claimed PK-12345 (auth flow)',
    '[broadcast] keeper-alpha: GPU 온도 정상',
    '[task] codex completed PK-12345',
    'dreamer heartbeat @ 19:30',
    '[broadcast] keeper-beta: restarting ollama',
  ]

  it('returns the input reference for an empty query', () => {
    expect(filterRoomActivity(lines, '')).toBe(lines)
  })

  it('returns the input reference for a whitespace-only query', () => {
    expect(filterRoomActivity(lines, '   ')).toBe(lines)
  })

  it('trims whitespace from the query before matching', () => {
    expect(filterRoomActivity(lines, '  dreamer  ')).toHaveLength(2)
  })

  it('matches substrings case-insensitively', () => {
    const result = filterRoomActivity(lines, 'DREAMER')
    expect(result).toHaveLength(2)
    expect(result.every(l => l.toLowerCase().includes('dreamer'))).toBe(true)
  })

  it('matches by task id substring', () => {
    const result = filterRoomActivity(lines, 'PK-12345')
    expect(result).toHaveLength(2)
  })

  it('matches by broadcast keyword', () => {
    const result = filterRoomActivity(lines, 'broadcast')
    expect(result).toHaveLength(2)
    expect(result.map(l => l.slice(0, 11))).toEqual(['[broadcast]', '[broadcast]'])
  })

  it('returns an empty array when nothing matches', () => {
    expect(filterRoomActivity(lines, 'zzz-nonexistent')).toHaveLength(0)
  })

  it('does not mutate the input array', () => {
    const copy = lines.slice()
    filterRoomActivity(lines, 'dreamer')
    expect(lines).toEqual(copy)
  })

  it('handles an empty input array', () => {
    expect(filterRoomActivity([], 'anything')).toEqual([])
    expect(filterRoomActivity([], '')).toEqual([])
  })

  it('tolerates non-ASCII query (Korean substring)', () => {
    const korean: readonly string[] = [
      '[broadcast] keeper-alpha: 정상 가동 중',
      '[broadcast] keeper-beta: 재시작 필요',
    ]
    expect(filterRoomActivity(korean, '재시작')).toHaveLength(1)
    expect(filterRoomActivity(korean, '정상')).toHaveLength(1)
  })
})
