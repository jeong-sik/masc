import { describe, expect, it } from 'vitest'
import type { DashboardPromptItem } from '../api'
import { buildKeeperPromptAssemblyReport } from './keeper-prompt-assembly-panel'

function prompt(overrides: Partial<DashboardPromptItem>): DashboardPromptItem {
  return {
    key: 'keeper.world',
    category: 'keeper',
    description: 'Keeper prompt',
    current: '',
    default: null,
    effective: '',
    file_value: null,
    override_value: null,
    file_path: null,
    file_exists: true,
    source: 'file',
    has_override: false,
    char_count: 0,
    required_file: true,
    template_variables: [],
    ...overrides,
  }
}

describe('buildKeeperPromptAssemblyReport', () => {
  it('maps keeper prompt sources into assembly rows', () => {
    const report = buildKeeperPromptAssemblyReport([
      prompt({
        key: 'keeper.world',
        effective: 'world override',
        override_value: 'world override',
        source: 'override',
        has_override: true,
        file_path: '/tmp/.masc/config/prompts/keeper.world.md',
      }),
      prompt({
        key: 'keeper.capabilities',
        effective: 'tool policy',
        file_path: '/tmp/.masc/config/prompts/keeper.capabilities.md',
      }),
      prompt({
        key: 'keeper.unified.system',
        effective: 'unified prompt',
        file_path: '/tmp/.masc/config/prompts/keeper.unified.system.md',
      }),
    ])

    expect(report.stats.totalRows).toBeGreaterThan(10)
    expect(report.stats.overrideRows).toBeGreaterThanOrEqual(2)
    expect(report.activePromptRoots).toEqual(['/tmp/.masc/config/prompts'])
    expect(report.rows.find(row => row.promptKey === 'keeper.world')?.source).toBe('override')
    expect(report.rows.find(row => row.promptKey === 'keeper.recovery_block')?.missing).toBe(true)
  })

  it('detects stale tool aliases and argument shapes in effective prompt text', () => {
    const report = buildKeeperPromptAssemblyReport([
      prompt({
        key: 'keeper.tool_hints',
        effective: 'Call keeper_board_get then keeper_task_done { notes: "evidence" }',
      }),
      prompt({
        key: 'keeper.capabilities',
        effective: 'Use keeper_pr_create and repos/masc/lib/foo.ml for PR work',
      }),
    ])

    expect(report.warnings.map(warning => warning.id)).toEqual(
      expect.arrayContaining([
        'retired-board-get',
        'task-done-notes',
        'keeper-pr-create',
        'hardcoded-masc-path',
      ]),
    )
    expect(report.stats.criticalCount).toBe(2)
  })
})
