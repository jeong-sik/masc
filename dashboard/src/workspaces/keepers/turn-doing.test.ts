import { describe, expect, it } from 'vitest'
import { turnDoing } from './turn-doing'
import type { KeeperActiveTurnPreview, KeeperTurnPreparation, TurnOpenActivity } from './types'

const response = (channel: 'none' | 'thinking' | 'text', since = 100): TurnOpenActivity => ({
  kind: 'response', channel, started_at_unix: since - 1, since_unix: since,
})
const tool = (name: string, stage: 'requested' | 'executing', since = 100): TurnOpenActivity => ({
  kind: 'tool', tool_use_id: null, name, stage, started_at_unix: since - 1, since_unix: since, cohort: null, reach: null,
})
const preview = (
  activity: string,
  open: readonly TurnOpenActivity[] | null,
  preparation: KeeperTurnPreparation | null = null,
): KeeperActiveTurnPreview => ({
  status_text: 'runtime · ' + activity, activity, open_activities: open, preparation, work_context: null,
  text_tail: '', last_tool: null, updated_at_unix: 200, revision: 1,
})
const step = (
  state: KeeperTurnPreparation['state'],
  phase = 'workspace_memory',
  started_at_unix: number | null = 40,
): KeeperTurnPreparation => ({ phase, state, started_at_unix })

describe('what a turn is doing, in one line', () => {
  const several = [response('thinking'), tool('Read', 'requested'), tool('Execute', 'executing', 150), tool('Grep', 'requested')]

  it('names the preparation step that runs, and since when', () => {
    expect(turnDoing(preview('preparing', [], step('active')))).toEqual({
      phrase: '준비 중 · 작업공간 메모리', sinceUnix: 40, tone: 'info',
    })
    // A frame that does not say when the step began names the step without a time.
    expect(turnDoing(preview('preparing', [], step('active', 'wiki', null)))).toEqual({
      phrase: '준비 중 · 위키', sinceUnix: null, tone: 'info',
    })
  })

  it('says that a step is done, with no time: nothing has been seen after it yet', () => {
    expect(turnDoing(preview('preparing', [], step('prepared', 'context')))).toEqual({
      phrase: '컨텍스트 준비 완료', sinceUnix: null, tone: 'info',
    })
  })

  it.each([
    ['rejected', '도구 준비 거절'],
    ['raised', '도구 준비 중 예외'],
    ['cancelled', '도구 준비 취소'],
  ] as const)('says how a step that ended %s stopped, as a turn that stopped short', (state, phrase) => {
    expect(turnDoing(preview('preparing', [], step(state, 'tools')))).toEqual({ phrase, sinceUnix: null, tone: 'bad' })
  })

  it('says a step the dashboard has no word for as the server wrote it', () => {
    expect(turnDoing(preview('preparing', [], step('active', 'phase_from_a_newer_server'))).phrase)
      .toBe('준비 중 · phase_from_a_newer_server')
  })

  it('says a preparation before the open work the same preview still lists', () => {
    expect(turnDoing(preview('tool', several, step('active', 'prompt'))).phrase).toBe('준비 중 · 프롬프트')
  })

  it('is the open work, and since when, once no preparation is in effect', () => {
    expect(turnDoing(preview('tool', several))).toEqual({ phrase: 'Execute 외 2건 · 실행 중', sinceUnix: 150, tone: 'info' })
    expect(turnDoing(preview('streaming', [response('text', 120)]))).toEqual({ phrase: '답변 쓰는 중', sinceUnix: 120, tone: 'brass' })
  })

  it("is the activity's word when nothing is open or the list cannot be read", () => {
    expect(turnDoing(preview('waiting', []))).toEqual({ phrase: '응답 대기 중', sinceUnix: null, tone: 'warn' })
    expect(turnDoing(preview('tool', null))).toEqual({ phrase: '도구 실행 중', sinceUnix: null, tone: 'info' })
  })

  it('does not speak from the list of an attempt that failed, or of a turn that still prepares', () => {
    expect(turnDoing(preview('failed', [tool('Execute', 'executing')]))).toEqual({ phrase: '시도 실패', sinceUnix: null, tone: 'bad' })
    expect(turnDoing(preview('preparing', [tool('Execute', 'executing')]))).toEqual({ phrase: '준비 중', sinceUnix: null, tone: 'info' })
  })
})
