import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from '../api/core'
import { decodeSkillEvidenceResponse, type SkillSurfaceProfile, type SkillsResponse } from '../api/dashboard-skills'
import { SkillsPanel } from './skills-panel'
import { acceptedExecutionWorkspace } from '../execution-workspace-authority'

const api = vi.hoisted(() => ({ fetchSkills: vi.fn(), fetchSkillEvidence: vi.fn(),
  fetchAsyncRequestObservation: vi.fn(), readSkillSource: vi.fn() }))
vi.mock('../api/dashboard-skills', async original => ({ ...await original<typeof import('../api/dashboard-skills')>(), ...api }))
vi.mock('../store', async () => {
  const { signal } = await import('@preact/signals')
  return { executionWorkspaceAuthority: (await import('../execution-workspace-authority')).acceptedExecutionWorkspace, keepers: signal([]), executionLoaded: signal(false) }
})
const reference = { identity: { source_id: 'workspace', package_id: 'proof', name: 'proof' }, content_revision: 'a'.repeat(64) }
const profile: SkillSurfaceProfile = {
  activation_tool: 'keeper_compose_proof', execution: 'inline', io: { kind: 'composition', input_schema: {}, exports: [] },
  capabilities: { as_skill: true, as_tool: true, batch: false, parallel: false, async: false, tool_scope: 'registered_tools_only' },
  context: { body_bytes: 100, discovery_bytes: 10, tool_schema_bytes: null },
  plan: { node_count: 1, batch_count: 1, parallel_batch_count: 0, max_parallelism: 1, statically_read_only: true }, declaration: null, flow: null,
}
const catalog: SkillsResponse = { schema: 'masc.skill-snapshot/v1', state: 'ready',
  snapshot: { snapshot_revision: 'snapshot', catalog_revision: 'catalog', config: { kind: 'unreadable' }, sources: [],
    skills: [{ ...reference, description: 'Proof Skill', body_bytes: 100 }], effective_skills: [reference.identity], shadows: [], rejections: [] },
  surfaces: [{ reference, kind: 'composition', profile }],
}
const older = { schema: 'masc.skill-composition-evidence/v1', reference,
  composition_run_id: '019ffc2b-0a41-7ba2-bf58-598e0e7f711a', parent_tool_use_id: 'parent-original', parent_turn: 7, parent_planned_index: 0,
  request_id: null, keeper: 'rondo', composition_tool: 'keeper_compose_proof', composition_execution: 'inline',
  result: { disposition: 'completed', duration_ms: 10, data: 'older-output', tool_name: 'keeper_compose_proof' }, executor_settlements: [], recorded_at: 1,
}
const newer = { ...older, composition_run_id: '019ffc2b-0a41-7ba2-bf58-598e0e7f711b', keeper: 'echo', recorded_at: 2,
  result: { disposition: 'failed', duration_ms: 7, data: null, tool_name: 'keeper_compose_proof',
    message: 'newer publication failure', failure_class: 'runtime_failure', effect_disposition: 'effect_outcome_unknown' },
}
const summary = (run: typeof older | typeof newer) => ({ composition_run_id: run.composition_run_id, keeper: run.keeper,
  composition_execution: run.composition_execution, request_id: run.request_id, disposition: run.result.disposition,
  duration_ms: run.result.duration_ms, recorded_at: run.recorded_at })
const duration = (samples: number, value: number | null) => ({ samples, mean_ms: value, min_ms: value, p50_ms: value, p95_ms: value, max_ms: value })
function response(runId?: string, missing = false) {
  return decodeSkillEvidenceResponse({ schema: 'masc.skill-evidence/v9', status: 'observed', reference, activation: null,
    composition_selection: runId === undefined ? { mode: 'latest_retained' } : { mode: 'exact_run', composition_run_id: runId },
    composition: missing ? null : runId === older.composition_run_id ? older : newer,
    composition_runs: missing ? [summary(newer)] : [summary(newer), summary(older)],
    composition_statistics: { scope: 'exact_reference_retained_runs', duration_scope: 'stored_executor_result', percentile_method: 'nearest_rank',
      recorded_window: { first_recorded_at: missing ? 2 : 1, last_recorded_at: 2 }, records: missing ? 1 : 2,
      completed: missing ? duration(0, null) : duration(1, 10), failed: duration(1, 7), deferred: 0 },
    coverage: { composition_scope: 'exact_reference_retained_runs', composition_runs_observed: missing ? 1 : 2,
      composition_unavailable: [], coverage_complete: false, activation_scope: 'complete_retained_trace_snapshot',
      activation_sessions_inspected: 0, activation_ledgers_loaded: 0, activation_gaps: [], activation_owner_gap_count: 0 },
  })
}
function pending<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(accept => { resolve = accept })
  return { promise, resolve }
}
async function load() {
  render(html`<${SkillsPanel} />`)
  fireEvent.click(await screen.findByRole('button', { name: 'Read instructions for proof' }))
  fireEvent.click(screen.getByRole('button', { name: 'Load' }))
  await screen.findByRole('button', { name: older.composition_run_id })
}
beforeEach(() => {
  acceptedExecutionWorkspace.value = Object.freeze({ epoch: 'fixture', workspaceRoot: '/workspace',
    connectionGeneration: 1, observerInstanceId: 'fixture-instance' })
  for (const mock of Object.values(api)) mock.mockReset()
  setStoredToken('fixture')
  api.fetchSkills.mockResolvedValue(catalog)
  api.fetchSkillEvidence.mockImplementation(async (_reference, runId?: string) => response(runId))
  api.fetchAsyncRequestObservation.mockResolvedValue({ schema: 'masc.async-request-observation/v1', status: 'unavailable', error: {}, startup_recovery: null })
  api.readSkillSource.mockResolvedValue({ status: 'ready', reference, snapshot_revision: 'snapshot', source_text: 'source', access: 'read_only' })
})
afterEach(() => { cleanup(); clearStoredToken() })

it('filters retained metadata and selects older input/output without filtering statistics', async () => {
  await load()
  fireEvent.change(screen.getByLabelText('Run outcome'), { target: { value: 'completed' } })
  fireEvent.change(screen.getByLabelText('Run Keeper'), { target: { value: 'rondo' } })
  fireEvent.input(screen.getByLabelText('Run ID'), { target: { value: '711a' } })
  await screen.findByText('1 of 2 retained runs')
  expect(screen.queryByRole('button', { name: newer.composition_run_id })).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: older.composition_run_id }))
  await screen.findByText('older-output')
  expect(api.fetchSkillEvidence).toHaveBeenLastCalledWith(reference, older.composition_run_id)
  expect(screen.getByText('2 retained runs')).toBeTruthy()
  expect(screen.queryByRole('note', { name: 'Composition failure' })).toBeNull()
  expect(screen.getByText(/parent tool use parent-original/)).toBeTruthy()
})

it('keeps the most recent requested selection when older detail arrives late', async () => {
  await load()
  const old = pending<ReturnType<typeof response>>()
  const latest = pending<ReturnType<typeof response>>()
  api.fetchSkillEvidence.mockImplementationOnce(() => old.promise).mockImplementationOnce(() => latest.promise)
  fireEvent.click(screen.getByRole('button', { name: older.composition_run_id }))
  fireEvent.click(screen.getByRole('button', { name: 'Latest retained' }))
  await act(async () => { latest.resolve(response()); await latest.promise })
  await waitFor(() => expect(screen.getByRole('note', { name: 'Composition failure' }).textContent).toContain('newer publication failure'))
  await act(async () => { old.resolve(response(older.composition_run_id)); await old.promise })
  expect(screen.queryByText('older-output')).toBeNull()
  expect(screen.getByRole('note', { name: 'Composition failure' }).textContent).toContain('newer publication failure')
  expect(screen.queryByRole('alert')).toBeNull()
})

it('shows a selected run disappearing from retained coverage without substituting latest', async () => {
  await load()
  api.fetchSkillEvidence.mockResolvedValueOnce(response(older.composition_run_id, true))
  fireEvent.click(screen.getByRole('button', { name: older.composition_run_id }))
  await screen.findByText(/Requested run .*was not observed/)
  expect(screen.queryByText('older-output')).toBeNull()
  expect(screen.queryByRole('note', { name: 'Composition failure' })).toBeNull()
  expect(screen.getByText('1 retained runs')).toBeTruthy()
})
