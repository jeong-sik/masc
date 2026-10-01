import { describe, expect, it } from 'vitest'
import projection from './api/fixtures/operator-judgment-recommendation.json'
import { normalizeMission } from './mission-normalizers'
import { normalizeOperatorDigest } from './operator-normalizers'
import { normalizeRecommendedAction } from './store-normalizers'
import { extractActionPayload } from './workflow-context'

// Frozen output of the actual OCaml guidance projection, using the existing
// operator judgment writer fixture. The native judgment test also drives that
// writer and Digest; this checks the public action reaches both browser readers.
describe('recorded judgment recommendation', () => {
  it('remains usable in Digest, Mission and the Briefing observation', () => {
    const digest = normalizeOperatorDigest(projection.digest)
    const mission = normalizeMission(projection.mission)
    expect(digest.recommended_actions).toHaveLength(1)
    expect(mission.recommended_actions).toEqual(digest.recommended_actions)
    expect(mission.summary.top_action).toEqual(digest.recommended_actions[0])
    const action = digest.recommended_actions[0]!
    expect(action.action_type).toBe('namespace_pause')
    expect(action.target_type).toBe('workspace')
    expect(action.reason).toBe('operator judge requires manual gate')
    expect(action.confirm_required).toBe(true)
    expect(extractActionPayload(action)).toEqual({ reason: 'manual review' })
    expect(projection.briefing.recommended_action_count).toBe(1)
    expect(projection.digest.judgment.recommended_action.action_kind).toBe('pause_workspace')
  })

  it('cannot consume an empty recommendation as an action', () => {
    expect(normalizeRecommendedAction({})).toBeNull()
    expect(normalizeMission({ recommended_actions: [{}] }).recommended_actions).toEqual([])
    expect(normalizeOperatorDigest({ recommended_actions: [{}] }).recommended_actions).toEqual([])
  })
})
