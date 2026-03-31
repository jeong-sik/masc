import { describe, expect, it } from 'vitest'
import type { DashboardCollaborationEvidenceResponse } from '../api'
import {
  collaborationEvidenceSupportRows,
  visibleCollaborationCountMetrics,
} from './collaboration-evidence'

function collaborationEvidenceFixture(): DashboardCollaborationEvidenceResponse {
  return {
    generated_at: '2026-03-27T00:00:00Z',
    evidence_status: 'partial',
    headline: '상호작용 흔적은 있지만 증거가 분산돼 있습니다.',
    detail: '세션 이벤트나 room activity는 보이지만 proof 또는 관계 근거가 충분히 묶이지 않았습니다.',
    session: null,
    room_id: 'default',
    counts: {
      team_turn_count: 0,
      session_broadcast_count: 0,
      portal_count: 0,
      message_broadcast_count: 0,
      mention_count: 0,
      board_interaction_count: 0,
      interaction_event_count: 0,
      explicit_linked_activity_count: 0,
      unlinked_activity_count: 0,
      unique_actor_count: 0,
    },
    linkage: {
      policy: 'explicit_first',
      selected_operation_id: null,
      explicit_linked_activity_count: 0,
      unlinked_activity_count: 0,
      gaps: [],
    },
    proof: {
      available: false,
      verdict: null,
    },
    relation_backend: {
      source: 'graphql_proxy',
      status: 'configured',
    },
    refs: [],
    artifacts: [],
    recent_events: [],
    recent_unlinked_activity: [],
  }
}

describe('visibleCollaborationCountMetrics', () => {
  it('keeps only non-zero metric cards', () => {
    const metrics = visibleCollaborationCountMetrics({
      team_turn_count: 0,
      session_broadcast_count: 0,
      portal_count: 0,
      message_broadcast_count: 4,
      mention_count: 0,
      board_interaction_count: 0,
      interaction_event_count: 0,
      explicit_linked_activity_count: 0,
      unlinked_activity_count: 0,
      unique_actor_count: 3,
    })

    expect(metrics).toEqual([
      { key: 'unique_actor_count', label: 'actors', value: 3 },
    ])
  })
})

describe('collaborationEvidenceSupportRows', () => {
  it('drops the support block when only default backend wiring exists', () => {
    expect(collaborationEvidenceSupportRows(collaborationEvidenceFixture())).toEqual([])
  })

  it('keeps only the meaningful support rows', () => {
    const fixture = collaborationEvidenceFixture()
    fixture.proof = { available: true, verdict: 'proven' }
    fixture.counts.message_broadcast_count = 4
    fixture.linkage.selected_operation_id = 'op-1'
    fixture.linkage.unlinked_activity_count = 2
    fixture.linkage.gaps = ['room activity exists without explicit session/operation linkage']

    expect(collaborationEvidenceSupportRows(fixture)).toEqual([
      'proof verdict · proven · available',
      'linked operation · op-1',
      'unlinked room activity · 2',
      'message broadcast count · 4',
      'linkage gap · room activity exists without explicit session/operation linkage',
    ])
  })
})
