// Autonomous keeper turns in the chat transcript.
//
// These rows have no chat-store row; the backend projects final text and work
// trace from the exact recorded autonomous run. Each exact turn is its own
// collapsed group, so adjacent wakes remain distinguishable in the transcript.
import { describe, expect, it } from 'vitest'
import type { KeeperConversationEntry } from '../../types'
import { buildChatRenderUnits } from './primitives'
import { chatHistoryEntriesFromRest, isDefaultVisibleConversationEntry } from '../../keeper-state'

const entry = (
  id: string,
  overrides: Partial<KeeperConversationEntry> = {},
): KeeperConversationEntry =>
  ({
    id,
    role: 'assistant',
    source: 'direct_assistant',
    label: 'keeper',
    text: '',
    delivery: 'history',
    ...overrides,
  }) as KeeperConversationEntry

const autonomous = (id: string, timestamp?: string): KeeperConversationEntry =>
  entry(id, { source: 'autonomous_turn', timestamp })

const user = (id: string): KeeperConversationEntry =>
  entry(id, { role: 'user', source: 'direct_user' })

const tool = (id: string): KeeperConversationEntry =>
  entry(id, { role: 'tool', source: 'tool_result' })

describe('buildChatRenderUnits — autonomous turns', () => {
  it('keeps each consecutive autonomous turn in its own collapsed unit', () => {
    const units = buildChatRenderUnits(
      [user('u1'), autonomous('a1'), autonomous('a2'), autonomous('a3'), user('u2')],
      true,
    )
    expect(units.map((unit) => unit.kind)).toEqual([
      'entry',
      'autonomousGroup',
      'autonomousGroup',
      'autonomousGroup',
      'entry',
    ])
    expect(
      units
        .filter((unit) => unit.kind === 'autonomousGroup')
        .map((group) => group.entry.id),
    ).toEqual(['a1', 'a2', 'a3'])
  })

  it('keeps separate runs separate so conversation between them stays in place', () => {
    const units = buildChatRenderUnits(
      [autonomous('a1'), user('u1'), autonomous('a2')],
      true,
    )
    expect(units.map((unit) => unit.kind)).toEqual(['autonomousGroup', 'entry', 'autonomousGroup'])
  })

  it('folds autonomous turns even when tool grouping is off', () => {
    // Collapsing each exact turn guards against its detail volume; it is not a
    // preference about how tool calls render.
    const units = buildChatRenderUnits([autonomous('a1'), autonomous('a2')], false)
    expect(units.map((unit) => unit.kind)).toEqual(['autonomousGroup', 'autonomousGroup'])
  })

  it('closes an open tool run before starting an autonomous group', () => {
    // Those tool rows belong to the direct turn that preceded the wake, so
    // they must not be swallowed into the autonomous group.
    const units = buildChatRenderUnits([tool('t1'), autonomous('a1')], true)
    expect(units.map((unit) => unit.kind)).toEqual(['toolGroup', 'autonomousGroup'])
  })

  it('leaves a transcript without autonomous turns unchanged', () => {
    const units = buildChatRenderUnits([user('u1'), entry('m1')], true)
    expect(units.map((unit) => unit.kind)).toEqual(['entry', 'entry'])
  })
})

describe('chatHistoryEntriesFromRest — autonomous turn rows', () => {
  const autonomousRow = {
    role: 'assistant',
    content: 'no work this cycle',
    ts: 1785770777,
    blocks: [{
      t: 'trace',
      trace: [
        { kind: 'think', text: '', content_withheld: true },
        {
          kind: 'tool',
          name: 'keeper_tasks_list',
          status: 'ok',
        },
      ],
    }],
    autonomous_turn: {
      turn_id: 'trace-test#41',
    },
  }

  it('projects the exact outcome and work trace', () => {
    const [entryOut] = chatHistoryEntriesFromRest('lane-smith', [autonomousRow])
    expect(entryOut?.source).toBe('autonomous_turn')
    expect(entryOut?.text).toBe('no work this cycle')
    expect(entryOut?.blocks).toBeUndefined()
    expect(entryOut?.traceSteps).toEqual([
      { kind: 'think', text: '', contentWithheld: true },
      {
        kind: 'tool',
        name: 'keeper_tasks_list',
        status: 'ok',
      },
    ])
    expect(entryOut?.turnRef).toBe('trace-test#41')
  })

  it('drops a think step whose text is empty without the withheld flag', () => {
    // Negative control for the branch order in normalizeTraceStep. `asString`
    // reports '' as absent, so an empty think step is only legitimate when the
    // flag says the content was withheld. Without the flag it is malformed, and
    // one malformed step nulls the entire trace array.
    const [entryOut] = chatHistoryEntriesFromRest('lane-smith', [
      {
        ...autonomousRow,
        blocks: [{ t: 'trace', trace: [{ kind: 'think', text: '' }] }],
      },
    ])
    expect(entryOut?.traceSteps).toBeUndefined()
  })

  it('is visible without the internal-message toggle', () => {
    const [entryOut] = chatHistoryEntriesFromRest('lane-smith', [autonomousRow])
    expect(entryOut && isDefaultVisibleConversationEntry(entryOut)).toBe(true)
  })

  it('does not advance the direct-conversation source chain', () => {
    // A world-state user row makes the NEXT assistant row internal. An
    // autonomous row between them must not consume that pairing.
    const entries = chatHistoryEntriesFromRest('lane-smith', [
      autonomousRow,
      { role: 'user', content: 'PR 상태 정리해줘', ts: 1785770800 },
      { role: 'assistant', content: '3건 확인했습니다', ts: 1785770801 },
    ])
    expect(entries.map((e) => e.source)).toEqual([
      'autonomous_turn',
      'direct_user',
      'direct_assistant',
    ])
  })

  it('drops a row whose autonomous_turn payload carries no turn id', () => {
    // Unknown shape is not rendered as an empty bubble.
    const entries = chatHistoryEntriesFromRest('lane-smith', [
      { role: 'assistant', content: 'x', ts: 1785770777, autonomous_turn: {} },
    ])
    expect(entries).toEqual([])
  })

  it('keeps absent public text distinct from an explicit empty response', () => {
    const [absent, empty] = chatHistoryEntriesFromRest('lane-smith', [
      { ...autonomousRow, id: 'absent', content: null },
      { ...autonomousRow, id: 'empty', content: '' },
    ])
    expect(absent?.text).toBe('텍스트 응답 없음')
    expect(absent?.rawText).toBeNull()
    expect(absent?.delivery).toBe('no_reply')
    expect(empty?.text).toBe('')
    expect(empty?.rawText).toBe('')
    expect(empty?.delivery).toBe('history')
  })
})
