import { describe, expect, it } from 'vitest'
import { restoreSummary } from './preset-restore-report'
import { decodePresetRestored, type RestoreReport } from './presets-wire'
import { committedRuntime, restored } from './presets-wire.test-fixture'

// The fixture's report skips one keeper and one assignment; these start from
// a report with nothing skipped and change one thing at a time.
function report(runtime: unknown): RestoreReport {
  const base = restored('default', runtime)
  return decodePresetRestored({
    ...base,
    report: {
      ...base.report,
      instructions: { ...base.report.instructions, skipped: [] },
      skipped_assignments: [],
    },
  }).report
}

const { durability_detail: _unconfirmedDetail, ...commitFields } = committedRuntime.commit
const settledCommit = {
  ...committedRuntime,
  commit: { ...commitFields, durability: 'durable', warnings: [] },
  exact_output_registry: { status: 'applied' },
}

describe('restoreSummary', () => {
  it('says the restore is done when nothing was skipped and runtime.toml did not change', () => {
    expect(restoreSummary(report({ effect: 'runtime_commit', status: 'unchanged' })).tone).toBe('success')
  })

  it('says the restore is done when the runtime commit is confirmed and the exact-output lanes were applied', () => {
    expect(restoreSummary(report(settledCommit)).tone).toBe('success')
  })

  it('asks the operator to check when the runtime commit is unconfirmed', () => {
    const summary = restoreSummary(report(committedRuntime))
    expect(summary.tone).toBe('warning')
    expect(summary.text).toBe('복원 결과를 확인해 주세요')
  })

  it('asks the operator to check when the exact-output lanes were not applied', () => {
    const summary = restoreSummary(report({ ...settledCommit, exact_output_registry: { status: 'unpublished' } }))
    expect(summary.text).toBe('복원 결과를 확인해 주세요')
  })
})
