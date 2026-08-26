import { describe, expect, it } from 'vitest'
import { parseAsksSnapshot } from './keeper-ask-wire'

// The server encodes these rows in server_routes_http_keeper_stream.ml. The
// fixture below is that encoder's output field for field, so a rename on
// either side fails here instead of drawing an empty panel in front of an
// operator who is waiting to answer.

function at<T>(items: readonly T[], index: number): T {
  const item = items[index]
  if (item === undefined) throw new Error(`expected an item at index ${index}`)
  return item
}

function question(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    question_id: 'q1',
    header: 'Ship it',
    prompt: 'The migration is reversible for an hour. Run it now?',
    mode: 'single',
    free_text: { allowed: false },
    choices: [
      { choice_id: 'now', label: 'Run now', description: 'while the window is open' },
      { choice_id: 'wait', label: 'Wait', description: null },
    ],
    ...overrides,
  }
}

function row(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    keeper: 'asker',
    ask_id: 'ask-1',
    asked_at: 1_700_000_000,
    context: 'I cannot tell which of these you meant.',
    questions: [question()],
    resolution: { state: 'open' },
    ...overrides,
  }
}

function snapshot(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { scope: 'fleet', keeper: null, open_count: 1, asks: [row()], ...overrides }
}

describe('parseAsksSnapshot', () => {
  it('reads a fleet-wide snapshot', () => {
    const parsed = parseAsksSnapshot(snapshot())
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(parsed.value.scope).toBe('fleet')
    expect(parsed.value.keeper).toBeNull()
    expect(parsed.value.openCount).toBe(1)
    expect(parsed.value.rows).toHaveLength(1)
    const first = at(parsed.value.rows, 0)
    expect(first.keeper).toBe('asker')
    expect(first.askId).toBe('ask-1')
    expect(first.context).toBe('I cannot tell which of these you meant.')
    const choices = at(first.questions, 0).choices
    expect(choices.map((c) => c.choiceId)).toEqual(['now', 'wait'])
    expect(at(choices, 1).description).toBeNull()
  })

  it('keeps the server open_count rather than counting rows', () => {
    const parsed = parseAsksSnapshot(snapshot({ open_count: 7 }))
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(parsed.value.openCount).toBe(7)
    expect(parsed.value.rows).toHaveLength(1)
  })

  it('reads a keeper-scoped snapshot', () => {
    const parsed = parseAsksSnapshot(snapshot({ scope: 'keeper', keeper: 'asker' }))
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(parsed.value.keeper).toBe('asker')
  })

  it('reads a free-text question with a hint', () => {
    const parsed = parseAsksSnapshot(
      snapshot({
        asks: [
          row({
            questions: [question({ free_text: { allowed: true, hint: 'one line' }, choices: [] })],
          }),
        ],
      }),
    )
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(at(at(parsed.value.rows, 0).questions, 0).freeText).toEqual({
      allowed: true,
      hint: 'one line',
    })
  })

  it('reads an answered resolution', () => {
    const parsed = parseAsksSnapshot(
      snapshot({
        asks: [
          row({
            resolution: {
              state: 'answered',
              answered_at: 1_700_000_100,
              answered_question_ids: ['q1'],
            },
          }),
        ],
      }),
    )
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(at(parsed.value.rows, 0).resolution).toEqual({
      state: 'answered',
      answeredAt: 1_700_000_100,
      answeredQuestionIds: ['q1'],
    })
  })

  it('reads a withdrawn resolution', () => {
    const parsed = parseAsksSnapshot(
      snapshot({
        asks: [row({ resolution: { state: 'withdrawn', reason: 'moot', withdrawn_at: 1.5 } })],
      }),
    )
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(at(parsed.value.rows, 0).resolution).toEqual({
      state: 'withdrawn',
      reason: 'moot',
      withdrawnAt: 1.5,
    })
  })

  it('refuses a mode it does not know instead of guessing single', () => {
    const parsed = parseAsksSnapshot(
      snapshot({ asks: [row({ questions: [question({ mode: 'ranked' })] })] }),
    )
    expect(parsed.ok).toBe(false)
    if (parsed.ok) return
    expect(parsed.error).toContain('ranked')
  })

  it('refuses a resolution state it does not know', () => {
    const parsed = parseAsksSnapshot(
      snapshot({ asks: [row({ resolution: { state: 'expired' } })] }),
    )
    expect(parsed.ok).toBe(false)
    if (parsed.ok) return
    expect(parsed.error).toContain('expired')
  })

  it('refuses a question with no way to answer', () => {
    const parsed = parseAsksSnapshot(
      snapshot({
        asks: [row({ questions: [question({ choices: [], free_text: { allowed: false } })] })],
      }),
    )
    expect(parsed.ok).toBe(false)
    if (parsed.ok) return
    expect(parsed.error).toContain('no way to answer')
  })

  it('refuses an ask with no questions', () => {
    const parsed = parseAsksSnapshot(snapshot({ asks: [row({ questions: [] })] }))
    expect(parsed.ok).toBe(false)
    if (parsed.ok) return
    expect(parsed.error).toContain('no questions')
  })

  it('refuses an unknown scope', () => {
    const parsed = parseAsksSnapshot(snapshot({ scope: 'cluster' }))
    expect(parsed.ok).toBe(false)
    if (parsed.ok) return
    expect(parsed.error).toContain('cluster')
  })

  it('refuses a non-object payload', () => {
    expect(parseAsksSnapshot(null).ok).toBe(false)
    expect(parseAsksSnapshot([]).ok).toBe(false)
    expect(parseAsksSnapshot('asks').ok).toBe(false)
  })
})
