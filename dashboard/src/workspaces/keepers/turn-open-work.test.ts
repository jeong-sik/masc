import { describe, expect, it } from 'vitest'
import {
  decodeOpenActivities,
  openActivityLeavesMasc,
  openActivityPhrase,
  openActivityReachLabel,
  openWorkLead,
  openWorkLeadPhrase,
  openWorkPieces,
} from './turn-open-work'
import { parseKeeperLiveObserverEvent } from './keepers-api'

const thinking = { kind: 'response', channel: 'thinking', started_at_unix: 10, since_unix: 12 }
const tool = (id: string, name: string, cohort: unknown, reach: unknown = null) => ({
  kind: 'tool', tool_use_id: id, name, stage: 'executing',
  started_at_unix: 20, since_unix: 21, cohort, reach,
})

describe('turn open work', () => {
  it('reads the list the server sends', () => {
    const decoded = decodeOpenActivities([
      thinking,
      tool('a', 'WebFetch', { batch_index: 0, batch_size: 2, concurrent: true }, 'network'),
      { kind: 'tool', tool_use_id: null, name: 'Read', stage: 'requested', started_at_unix: 1, since_unix: 1 },
    ])
    expect(decoded).toEqual([
      { kind: 'response', channel: 'thinking', started_at_unix: 10, since_unix: 12 },
      {
        kind: 'tool', tool_use_id: 'a', name: 'WebFetch', stage: 'executing', started_at_unix: 20, since_unix: 21,
        cohort: { batch_index: 0, batch_size: 2, concurrent: true }, reach: 'network',
      },
      {
        kind: 'tool', tool_use_id: null, name: 'Read', stage: 'requested', started_at_unix: 1, since_unix: 1,
        cohort: null, reach: null,
      },
    ])
  })

  it('reads the list whole or not at all', () => {
    expect(decodeOpenActivities(undefined)).toBeNull()
    expect(decodeOpenActivities([thinking, tool('a', 'X', null, 'moon')])).toBeNull()
    expect(decodeOpenActivities([{ ...thinking, channel: 'dream' }])).toBeNull()
    expect(decodeOpenActivities([tool('a', 'X', { batch_index: 0, batch_size: 2 })])).toBeNull()
    expect(decodeOpenActivities([])).toEqual([])
  })

  it('gathers the open calls of one concurrent batch under one header', () => {
    const decoded = decodeOpenActivities([
      thinking,
      tool('a', 'WebFetch', { batch_index: 1, batch_size: 3, concurrent: true }, 'network'),
      tool('s', 'Write', { batch_index: 2, batch_size: 1, concurrent: false }, 'sandbox'),
      tool('b', 'Execute', { batch_index: 1, batch_size: 3, concurrent: true }, 'sandbox'),
      tool('c', 'Lone', { batch_index: 3, batch_size: 1, concurrent: true }),
    ])
    expect(decoded).not.toBeNull()
    const pieces = openWorkPieces(decoded ?? [])
    expect(pieces.map((piece) => piece.kind === 'batch'
      ? `batch(${piece.members.length}/${piece.batchSize}):${piece.members.map((m) => m.name).join('+')}`
      : piece.activity.kind === 'tool' ? piece.activity.name : piece.activity.channel))
      .toEqual(['thinking', 'batch(2/3):WebFetch+Execute', 'Write', 'Lone'])
  })

  it('says what each piece is doing and where a call reaches', () => {
    const decoded = decodeOpenActivities([
      thinking,
      tool('a', 'WebFetch', null, 'network'),
      tool('b', 'fusion', null, 'model_provider'),
      tool('c', 'Execute', null, 'sandbox'),
      tool('d', 'masc_tasks', null, 'masc_state'),
    ]) ?? []
    expect(decoded.map(openActivityPhrase))
      .toEqual(['추론 중', 'WebFetch · 실행 중', 'fusion · 실행 중', 'Execute · 실행 중', 'masc_tasks · 실행 중'])
    expect(decoded.map(openActivityReachLabel))
      .toEqual([null, '외부 · 네트워크', '외부 · 모델', '샌드박스', null])
    expect(decoded.map(openActivityLeavesMasc)).toEqual([false, true, true, false, false])
  })

  it('carries the open work through a live preview event', () => {
    const event = parseKeeperLiveObserverEvent('keeper_turn_preview_changed', {
      name: 'wkbl-growth',
      observation: {
        owner_key: 'o',
        preview: {
          status_text: 'Receiving reasoning', activity: 'streaming', text_tail: '',
          updated_at_unix: 30, revision: 4, open_activities: [thinking],
        },
      },
    }, 'wkbl-growth')
    expect(event?.kind).toBe('turn_preview')
    if (event?.kind === 'turn_preview') {
      expect(event.preview.open_activities).toEqual([thinking])
    }
  })
})

describe('the one line the open-work rows expand', () => {
  const called = (name: string) => ({ ...tool(name, name, null), stage: 'requested' })
  const lead = (...raw: readonly unknown[]) => openWorkLead(decodeOpenActivities(raw) ?? [])
  const line = (...raw: readonly unknown[]) => {
    const found = lead(...raw)
    return found === null ? null : openWorkLeadPhrase(found)
  }

  it('has nothing to name when nothing is open', () => {
    expect(lead()).toBeNull()
  })

  it('is the open response when no tool is open', () => {
    expect(line(thinking)).toBe('추론 중')
    expect(line({ ...thinking, channel: 'text' })).toBe('답변 쓰는 중')
    expect(line({ ...thinking, channel: 'none' })).toBe('모델 응답 기다리는 중')
  })

  it('names a tool call before the response that asked for it, in the words of its row', () => {
    const activities = decodeOpenActivities([thinking, tool('a', 'Execute', null)]) ?? []
    const found = openWorkLead(activities)
    expect(found).toEqual({ lead: activities[1], otherCalls: 0 })
    expect(found && openWorkLeadPhrase(found)).toBe(activities[1] && openActivityPhrase(activities[1]))
  })

  it('names the call that runs, not the call listed first, and counts the other calls', () => {
    const found = lead(thinking, called('Read'), { ...tool('b', 'Execute', null), since_unix: 44 }, called('Grep'))
    expect(found?.lead).toMatchObject({ name: 'Execute', since_unix: 44 })
    expect(found?.otherCalls).toBe(2)
    expect(found && openWorkLeadPhrase(found)).toBe('Execute 외 2건 · 실행 중')
  })

  it('names the first call when none has started', () => {
    expect(line(called('Read'), called('Grep'))).toBe('Read 외 1건 · 호출 준비')
    expect(line(called('Read'))).toBe('Read · 호출 준비')
  })

  it('counts two open calls that look the same as two', () => {
    expect(line(tool('a', 'Read', null), tool('a', 'Read', null))).toBe('Read 외 1건 · 실행 중')
  })
})
