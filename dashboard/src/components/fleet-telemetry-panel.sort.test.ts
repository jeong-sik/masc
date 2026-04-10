import { describe, expect, it } from 'vitest'
import { buildFleetRows } from './fleet-telemetry-panel'
import type { ToolQualityResponse } from '../api/dashboard'
import type { Keeper } from '../types'

function toolQualityByKeeper(
  entries: Array<{ name: string; calls: number; success_pct: number }>,
): ToolQualityResponse {
  return {
    total: entries.reduce((sum, entry) => sum + entry.calls, 0),
    success: 0,
    failure: 0,
    success_rate: 0,
    by_tool: [],
    by_keeper: entries,
    failure_categories: [],
    hourly_trend: [],
  }
}

describe('buildFleetRows sort order', () => {
  it('surfaces attention keepers ahead of otherwise healthier live rows', () => {
    const keepers = [
      {
        name: 'recent-tools',
        status: 'active',
        keepalive_running: true,
        context_ratio: 0.1,
        total_turns: 5,
        last_activity_ago_s: 30,
      },
      {
        name: 'older-more-tools',
        status: 'active',
        keepalive_running: true,
        context_ratio: 0.9,
        total_turns: 20,
        last_activity_ago_s: 600,
      },
    ] satisfies Keeper[]

    const rows = buildFleetRows(
      keepers,
      toolQualityByKeeper([
        { name: 'recent-tools', calls: 12, success_pct: 100 },
        { name: 'older-more-tools', calls: 120, success_pct: 100 },
      ]),
    )

    expect(rows.map(row => row.name)).toEqual(['older-more-tools', 'recent-tools'])
  })

  it('keeps attention pressure ahead of tool volume when activity is unavailable', () => {
    const keepers = [
      {
        name: 'high-context-fewer-tools',
        status: 'active',
        keepalive_running: true,
        context_ratio: 0.92,
        total_turns: 12,
      },
      {
        name: 'more-tools-lower-context',
        status: 'active',
        keepalive_running: true,
        context_ratio: 0.21,
        total_turns: 18,
      },
      {
        name: 'inactive-heavy-tools',
        status: 'inactive',
        keepalive_running: false,
        context_ratio: 0.4,
        total_turns: 99,
      },
    ] satisfies Keeper[]

    const rows = buildFleetRows(
      keepers,
      toolQualityByKeeper([
        { name: 'high-context-fewer-tools', calls: 40, success_pct: 100 },
        { name: 'more-tools-lower-context', calls: 180, success_pct: 100 },
        { name: 'inactive-heavy-tools', calls: 500, success_pct: 100 },
      ]),
    )

    expect(rows.map(row => row.name)).toEqual([
      'high-context-fewer-tools',
      'more-tools-lower-context',
      'inactive-heavy-tools',
    ])
  })
})
