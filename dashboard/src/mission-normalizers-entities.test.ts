import { describe, expect, it } from 'vitest'

import { normalizeKeeperBrief } from './mission-normalizers-entities'

describe('normalizeKeeperBrief', () => {
  it('keeps observed audit fields and drops compatibility allowlists', () => {
    const brief = normalizeKeeperBrief({
      name: 'sangsu',
      status: 'active',
      allowed_tool_names: ['compat_only_allowlist'],
      latest_tool_names: ['observed_tool'],
      latest_tool_call_count: 3,
      tool_audit_source: 'heartbeat_result',
      tool_audit_at: '2026-04-02T09:30:00Z',
    })

    expect(brief).toEqual({
      name: 'sangsu',
      agent_name: null,
      status: 'active',
      generation: undefined,
      context_ratio: null,
      last_turn_ago_s: null,
      current_work: null,
      last_autonomous_action_at: null,
      latest_tool_names: ['observed_tool'],
      latest_tool_call_count: 3,
      tool_audit_source: 'heartbeat_result',
      tool_audit_at: '2026-04-02T09:30:00Z',
    })
    expect(brief as unknown as Record<string, unknown>).not.toHaveProperty('allowed_tool_names')
  })
})
