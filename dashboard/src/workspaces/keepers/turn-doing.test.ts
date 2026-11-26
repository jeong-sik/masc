import { describe, expect, it } from 'vitest'
import { turnDoing } from './turn-doing'
import type { KeeperActiveTurnPreview, TurnOpenActivity } from './types'

const response = (channel: 'none' | 'thinking' | 'text', since = 100): TurnOpenActivity => ({
  kind: 'response', channel, started_at_unix: since - 1, since_unix: since,
})
const tool = (name: string, stage: 'requested' | 'executing', since = 100): TurnOpenActivity => ({
  kind: 'tool', tool_use_id: null, name, stage, started_at_unix: since - 1, since_unix: since, cohort: null, reach: null,
})
const preview = (activity: string, open: readonly TurnOpenActivity[] | null): KeeperActiveTurnPreview => ({
  status_text: 'runtime · ' + activity, activity, open_activities: open, preparation: null, work_context: null,
  text_tail: '', last_tool: null,
  updated_at_unix: 200, revision: 1,
})

describe('what a turn is doing, in one line', () => {
  it('is the open work, and since when', () => {
    const several = [response('thinking'), tool('Read', 'requested'), tool('Execute', 'executing', 150), tool('Grep', 'requested')]
    expect(turnDoing(preview('tool', several))).toEqual({ phrase: 'Execute 외 2건 · 실행 중', sinceUnix: 150 })
    expect(turnDoing(preview('streaming', [response('text', 120)]))).toEqual({ phrase: '답변 쓰는 중', sinceUnix: 120 })
  })

  it("is the activity's word when nothing is open or the list cannot be read", () => {
    expect(turnDoing(preview('waiting', []))).toEqual({ phrase: '응답 대기 중', sinceUnix: null })
    expect(turnDoing(preview('tool', null))).toEqual({ phrase: '도구 실행 중', sinceUnix: null })
  })

  it('does not speak from the list of an attempt that failed, or of a turn that still prepares', () => {
    expect(turnDoing(preview('failed', [tool('Execute', 'executing')]))).toEqual({ phrase: '시도 실패', sinceUnix: null })
    expect(turnDoing(preview('preparing', [tool('Execute', 'executing')]))).toEqual({ phrase: '준비 중', sinceUnix: null })
  })
})
