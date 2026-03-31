import { describe, expect, it } from 'vitest'
import { buildSessionFlowMermaid, sessionFlowFallback } from './mission-session-flow'
import type { DashboardMissionSessionDetailResponse } from '../types'

function sampleDetail(
  overrides: Partial<DashboardMissionSessionDetailResponse> = {},
): DashboardMissionSessionDetailResponse {
  return {
    session_id: 'ts-coding-001',
    session: {
      session_id: 'ts-coding-001',
      goal: 'Implement session flow visibility',
      room: 'default',
      status: 'running',
      health: 'healthy',
      member_names: ['planner', 'implementer'],
      related_attention_count: 0,
      member_previews: [],
      operation_badges: [],
      keeper_refs: [],
    },
    timeline: [],
    participants: [
      {
        agent_name: 'planner',
        current_work: 'Inspecting current session detail surface',
        recent_tool_names: [],
      },
    ],
    operations: [
      {
        operation_id: 'op-inspect',
        status: 'completed',
        stage: 'inspect',
        updated_at: '2026-03-31T08:00:00Z',
      },
      {
        operation_id: 'op-implement',
        status: 'running',
        stage: 'implement',
        updated_at: '2026-03-31T09:00:00Z',
      },
      {
        operation_id: 'op-verify',
        status: 'pending',
        stage: 'verify',
        updated_at: '2026-03-31T09:05:00Z',
      },
    ],
    keepers: [
      {
        name: 'sangsu',
        status: 'active',
        current_work: 'Watching continuity',
      },
    ],
    ...overrides,
  }
}

describe('mission session flow', () => {
  it('builds a mermaid graph from coding_task operations and highlights the active stage', () => {
    const source = buildSessionFlowMermaid(sampleDetail())

    expect(source).toContain('flowchart LR')
    expect(source).toContain('session --> decompose')
    expect(source).toContain('inspect --> implement')
    expect(source).toContain('review --> complete')
    expect(source).toContain('implement["구현')
    expect(source).toContain('active 1')
    expect(source).toContain('class implement activeStage;')
    expect(source).toContain('continuity["연속성')
  })

  it('includes blocker information in the graph and fallback summary', () => {
    const detail = sampleDetail({
      session: {
        ...sampleDetail().session!,
        blocker_summary: 'Waiting on verify evidence before review handoff',
      },
    })

    const source = buildSessionFlowMermaid(detail)
    const fallback = sessionFlowFallback(detail)

    expect(source).toContain('blocker["막힘')
    expect(fallback).toContain('막힘: Waiting on verify evidence before review handoff')
  })

  it('returns no graph when there are no linked operations', () => {
    const source = buildSessionFlowMermaid(sampleDetail({ operations: [] }))

    expect(source).toBeNull()
  })
})
