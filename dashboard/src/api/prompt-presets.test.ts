import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({ get: vi.fn(), postControlPlane: vi.fn() }))
vi.mock('./core', async importOriginal => ({ ...await importOriginal<typeof import('./core')>(), ...mocks }))

import { ApiRequestError } from './core'
import {
  parsePromptPresetDetail, parsePromptPresetReport, promptPresetReportNeedsAttention,
  restorePromptPreset, savePromptPreset,
} from './prompt-presets'

const defaults = { status: 'unknown', changes: [] }
const part = { effect: 'immediate', applied: [], skipped: [] }
const report = {
  restored: 'morning', autosave: '_autosave', prompt_overrides: part, instructions: part,
  runtime: { effect: 'runtime_commit', status: 'unchanged' }, default_prompts: defaults,
}

describe('saved prompt preset protocol', () => {
  beforeEach(() => { vi.resetAllMocks() })

  it('reads missing-settings observations and rejects an unknown setting', () => {
    const payload = {
      ok: true, directory: '/fixture/presets/morning', saved_settings: { status: 'differs' }, default_prompts: defaults,
      preset: { name: 'morning', description: '', created_at: '2026-10-07T02:15:46Z', prompt_overrides: [], instructions: [], assignments: [], lanes: [] },
    }
    expect(parsePromptPresetDetail(payload).preset.preserved_lane_settings).toBeUndefined()
    const withSettings = { ...payload, preset: { ...payload.preset,
      preserved_lane_settings: [{ lane: 'verifier_exact', setting: 'thinking' }] } }
    expect(parsePromptPresetDetail(withSettings).preset.preserved_lane_settings).toEqual([{ lane: 'verifier_exact', setting: 'thinking' }])
    expect(() => parsePromptPresetDetail({ ...payload, preset: { ...payload.preset,
      preserved_lane_settings: [{ lane: 'verifier_exact', setting: 'unknown' }] } })).toThrow()
  })

  it('keeps partial effects and commit warnings separate from successful HTTP delivery', () => {
    expect(promptPresetReportNeedsAttention(parsePromptPresetReport(report))).toBe(false)
    expect(promptPresetReportNeedsAttention(parsePromptPresetReport({ ...report,
      instructions: { ...part, skipped: [{ key: 'retired-keeper', reason: 'not configured' }] } }))).toBe(true)
    const skipped = [{ keeper: 'analyst', reason: 'saved Runtime is no longer configured' }]
    const partial = parsePromptPresetReport({ ...report, skipped_assignments: skipped })
    expect(partial.skipped_assignments).toEqual(skipped)
    expect(promptPresetReportNeedsAttention(partial)).toBe(true)
    expect(() => parsePromptPresetReport({ ...report, skipped_assignments: [{ keeper: 'analyst' }] })).toThrow()
    const committed = { effect: 'runtime_commit', status: 'committed', commit: {
      source_revision: 'a'.repeat(64), order: '1', durability: 'durable', durability_detail: null, warnings: [],
    }, exact_output_registry: { status: 'applied', requires_restart: false, targets: 'runtime_bindings' } }
    expect(promptPresetReportNeedsAttention(parsePromptPresetReport({ ...report, runtime: committed }))).toBe(false)
    expect(promptPresetReportNeedsAttention(parsePromptPresetReport({ ...report, runtime: {
      ...committed, commit: { ...committed.commit, durability: 'unconfirmed', durability_detail: 'fsync failed' },
    } }))).toBe(true)
    expect(() => parsePromptPresetReport({ ...report, runtime: { ...committed,
      exact_output_registry: { ...committed.exact_output_registry, requires_restart: true } } })).toThrow()
  })

  it('sends one restore and preserves an unreadable or mismatched receipt as unconfirmed', async () => {
    mocks.postControlPlane.mockResolvedValue({ ok: true, report })
    expect((await restorePromptPreset('morning')).kind).toBe('confirmed')
    expect(mocks.postControlPlane).toHaveBeenCalledExactlyOnceWith('/api/v1/presets/restore', { name: 'morning' })
    mocks.postControlPlane.mockResolvedValue({ ok: true, report: { ...report, restored: 'other' } })
    expect((await restorePromptPreset('morning')).kind).toBe('unconfirmed')
    mocks.postControlPlane.mockResolvedValue({ ok: true })
    expect((await restorePromptPreset('morning')).kind).toBe('unconfirmed')
  })

  it('distinguishes an explicit refusal from transport and server failures without replaying', async () => {
    mocks.postControlPlane.mockRejectedValue(new ApiRequestError({ method: 'POST', path: '/api/v1/presets', status: 403 }))
    expect((await savePromptPreset('new', 'snapshot')).kind).toBe('refused')
    expect(mocks.postControlPlane).toHaveBeenCalledOnce()
    mocks.postControlPlane.mockReset().mockRejectedValue(new TypeError('connection closed'))
    expect((await savePromptPreset('new', 'snapshot')).kind).toBe('unconfirmed')
    expect(mocks.postControlPlane).toHaveBeenCalledOnce()
    mocks.postControlPlane.mockReset().mockRejectedValue(new ApiRequestError({ method: 'POST', path: '/api/v1/presets', status: 500 }))
    expect((await savePromptPreset('new', 'snapshot')).kind).toBe('unconfirmed')
    expect(mocks.postControlPlane).toHaveBeenCalledOnce()
  })

  it('uses create-only storage and checks ownership immediately before dispatch', async () => {
    const refuse = () => { throw new Error('retired request owner') }
    expect((await savePromptPreset('new', 'snapshot', { beforeDispatch: refuse })).kind).toBe('refused')
    expect(mocks.postControlPlane).not.toHaveBeenCalled()
    mocks.postControlPlane.mockResolvedValue({ ok: false, error: 'already exists' })
    expect((await savePromptPreset('new', 'snapshot')).kind).toBe('refused')
    expect(mocks.postControlPlane).toHaveBeenCalledExactlyOnceWith('/api/v1/presets/create', { name: 'new', description: 'snapshot' })
  })

  it('does not erase an unexpected commit or accept a contradictory durable receipt', async () => {
    const commit = { source_revision: 'a'.repeat(64), order: '1', durability: 'durable', durability_detail: null, warnings: [] }
    const applied = { status: 'applied', requires_restart: false, targets: 'runtime_bindings' }
    const runtime = { effect: 'runtime_commit', status: 'committed', commit, exact_output_registry: applied }
    for (const invalid of [
      { ...report.runtime, commit },
      { ...runtime, commit: { ...commit, durability_detail: 'unknown outcome' } },
      { ...runtime, commit: { ...commit, source_revision: '' } },
      { ...runtime, commit: { ...commit, order: '9223372036854775808' } },
    ]) {
      mocks.postControlPlane.mockResolvedValue({ ok: true, report: { ...report, runtime: invalid } })
      expect((await restorePromptPreset('morning')).kind).toBe('unconfirmed')
    }
  })
})
