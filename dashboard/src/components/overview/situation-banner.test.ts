import { afterEach, describe, expect, it } from 'vitest'
import { missionError, missionLoading } from '../../mission-signals'
import { namespaceTruthError } from '../../namespace-truth-signals'
import { synthesizeSituation } from './situation-banner'

describe('synthesizeSituation', () => {
  afterEach(() => {
    missionError.value = null
    missionLoading.value = false
    namespaceTruthError.value = null
  })

  it('treats mission load failures as bad severity', () => {
    missionError.value = 'mission projection offline'

    const result = synthesizeSituation(null)

    expect(result.tone).toBe('bad')
    expect(result.text).toContain('mission projection offline')
  })

  it('treats namespace truth refresh failures as bad severity even with a stale snapshot', () => {
    namespaceTruthError.value = 'namespace truth offline'

    const result = synthesizeSituation({
      sessions: [{ session_id: 'sess-1', goal: 'goal-1' }],
      attention_queue: [],
      incidents: [],
      agent_briefs: [],
      keeper_briefs: [],
    } as never)

    expect(result.tone).toBe('bad')
    expect(result.text).toContain('데이터 일부 갱신 실패.')
    expect(result.reasons.some(reason => reason.text.includes('namespace truth offline'))).toBe(true)
  })
})
