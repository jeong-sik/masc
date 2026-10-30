import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, within } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from '../api/core'
import { decodeSkillEvidenceResponse, type SkillsResponse, type SkillSurfaceProfile } from '../api/dashboard-skills'
import { SkillsPanel } from './skills-panel'

const api = vi.hoisted(() => ({ fetchSkills: vi.fn(), fetchSkillEvidence: vi.fn(), fetchAsyncRequestObservation: vi.fn() }))
vi.mock('../api/dashboard-skills', async original => ({ ...await original<typeof import('../api/dashboard-skills')>(), ...api }))
vi.mock('../store', async () => {
  const { signal } = await import('@preact/signals')
  return { executionWorkspaceAuthority: signal({ epoch: 'fixture', workspaceRoot: '/workspace', connectionGeneration: 1 }) }
})
const reference = { identity: { source_id: 'workspace', package_id: 'proof', name: 'proof' }, content_revision: 'a'.repeat(64) }
const profile: SkillSurfaceProfile = { activation_tool: 'keeper_skill', execution: 'model_orchestrated', io: { kind: 'model_orchestrated' },
  capabilities: { as_skill: true, as_tool: false, batch: false, parallel: false, async: false, tool_scope: 'model_orchestrated' },
  context: { body_bytes: 100, discovery_bytes: 10, tool_schema_bytes: null },
  plan: { node_count: 0, batch_count: 0, parallel_batch_count: 0, max_parallelism: 0, statically_read_only: null }, declaration: null, flow: null }
const snapshot: Extract<SkillsResponse, { state: 'ready' }>['snapshot'] = { snapshot_revision: 'snapshot', catalog_revision: 'catalog', config: { kind: 'unreadable' }, sources: [],
  skills: [{ ...reference, description: 'Proof Skill', body_bytes: 100 }], effective_skills: [reference.identity], shadows: [], rejections: [] }
const coverage = { composition_scope: 'exact_reference_latest_completed', composition_records_read: 0, composition_unavailable: [], coverage_complete: false,
  activation_scope: 'complete_retained_trace_snapshot', activation_sessions_inspected: 0, activation_ledgers_loaded: 0, activation_gaps: [], activation_owner_gap_count: 0 }
const emptyStats = { scope: 'exact_reference_retained_runs', duration_scope: 'stored_executor_result', records: 0,
  completed: { samples: 0, mean_ms: null }, failed: { samples: 0, mean_ms: null }, deferred: 0 }
const evidence = { schema: 'masc.skill-evidence/v7', status: 'not_observed_in_retained_coverage', reference,
  activation: null, composition: null, composition_statistics: emptyStats, coverage }
const composition = { schema: 'masc.skill-composition-evidence/v1', reference,
  composition_run_id: '01a045f2-cd8b-7000-a3f7-1d718a712204', parent_tool_use_id: '', parent_turn: 7, parent_planned_index: 0,
  request_id: null, keeper: 'rondo', composition_tool: 'keeper_compose_proof', composition_execution: 'inline',
  result: { disposition: 'completed', duration_ms: 0, data: { actions: [] }, tool_name: 'keeper_compose_proof' }, executor_settlements: [], recorded_at: 1 }
function catalog(mode: 'normal' | 'composition' | 'unavailable' = 'normal'): SkillsResponse {
  return { schema: 'masc.skill-snapshot/v1', state: 'ready', snapshot,
    surfaces: [mode === 'unavailable' ? { reference, kind: 'unavailable', error: 'profile unavailable' }
      : mode === 'normal' ? { reference, kind: 'instruction', profile }
        : { reference, kind: 'composition', profile: { ...profile, activation_tool: 'keeper_compose_proof', execution: 'inline',
          io: { kind: 'composition', input_schema: {}, exports: [] } } }] }
}
async function loadEvidence() {
  render(html`<${SkillsPanel} />`)
  fireEvent.click(await screen.findByRole('button', { name: 'Read instructions for proof' }))
  fireEvent.click(screen.getByRole('button', { name: 'Load' }))
  await screen.findByText(/retained sessions inspected/)
}
beforeEach(() => {
  vi.clearAllMocks(); setStoredToken('fixture')
  api.fetchSkills.mockResolvedValue(catalog())
  api.fetchAsyncRequestObservation.mockResolvedValue({ schema: 'masc.async-request-observation/v1', status: 'unavailable', error: {}, startup_recovery: null })
  api.fetchSkillEvidence.mockResolvedValue(decodeSkillEvidenceResponse(evidence))
})
afterEach(() => { cleanup(); clearStoredToken() })

it('labels Normal executor timing N/A instead of drawing empty executor bars', async () => {
  await loadEvidence()
  const panel = within(screen.getByRole('region', { name: 'Skill performance' }))
  expect(panel.getByText(/N\/A/)).toBeTruthy()
  expect(panel.queryByText(/shared 0/)).toBeNull()
  expect(screen.getByText(/not proof that it never ran/)).toBeTruthy()
})
it('does not infer N/A when the exact selected profile is unavailable', async () => {
  api.fetchSkills.mockResolvedValue(catalog('unavailable'))
  await loadEvidence()
  expect(screen.queryByText(/N\/A/)).toBeNull()
  expect(screen.getByText(/profile unavailable/)).toBeTruthy()
})
it('preserves Composition empty means as unobserved', async () => {
  api.fetchSkills.mockResolvedValue(catalog('composition'))
  await loadEvidence()
  expect(screen.queryByText(/N\/A/)).toBeNull()
  expect(screen.getAllByText(/unobserved.*n=0/)).toHaveLength(2)
})
it('preserves a real zero-duration Composition result and retained evidence', async () => {
  api.fetchSkills.mockResolvedValue(catalog('composition'))
  api.fetchSkillEvidence.mockResolvedValue(decodeSkillEvidenceResponse({ ...evidence, status: 'observed', composition,
    coverage: { ...coverage, composition_records_read: 1 },
    composition_statistics: { ...emptyStats, records: 1, completed: { samples: 1, mean_ms: 0 } } }))
  await loadEvidence()
  expect(screen.getByText('0.0ms · n=1')).toBeTruthy()
  expect(screen.getByText(composition.composition_run_id, { exact: false })).toBeTruthy()
  expect(screen.queryByText(/N\/A/)).toBeNull()
})
it('keeps retained executor results even if the selected declaration is model-orchestrated', async () => {
  api.fetchSkillEvidence.mockResolvedValue(decodeSkillEvidenceResponse({ ...evidence, status: 'observed', composition,
    coverage: { ...coverage, composition_records_read: 1 },
    composition_statistics: { ...emptyStats, records: 1, completed: { samples: 1, mean_ms: 0 } } }))
  await loadEvidence()
  expect(screen.getByText(/N\/A/)).toBeTruthy()
  expect(screen.getByText('0.0ms · n=1')).toBeTruthy()
  expect(screen.getByText(composition.composition_run_id, { exact: false })).toBeTruthy()
})
it('keeps unavailable retained coverage distinct from applicability', async () => {
  api.fetchSkillEvidence.mockResolvedValue(decodeSkillEvidenceResponse({ ...evidence, composition_statistics: null,
    coverage: { ...coverage, coverage_complete: false, composition_scope: 'unavailable', composition_unavailable: ['retained store unreadable'] } }))
  await loadEvidence()
  expect(screen.getByText(/N\/A/)).toBeTruthy()
  expect(screen.getByText(/retained store unreadable/)).toBeTruthy()
})

it('preserves Normal activation evidence alongside the N/A executor explanation', async () => {
  const activation = { identity: reference.identity, content_revision: reference.content_revision,
    snapshot_revision: 'b'.repeat(64), turn_ref: 'trace-proof#1', runtime_id: 'codex.default', activated_at: '2026-08-28T03:00:00Z',
    skill_tool_use_id: 'skill-call-1', agent_core_turn: 1,
    invocation: { kind: 'instruction', origin: { kind: 'session_instruction' }, served_content: { kind: 'skill_body', bytes: 4, sha256: 'c'.repeat(64) } },
    delivery: null, actions: [] }
  api.fetchSkillEvidence.mockResolvedValue(decodeSkillEvidenceResponse({ ...evidence, status: 'observed',
    activation: { selection: 'most_recent_observed', evidence: { trace_id: 'trace-proof',
      owner: { status: 'known', claims: [{ keeper: 'rondo', source: 'current_meta' }], gaps: [] },
      activation, async_result_deliveries: [], async_actions: [] } },
    coverage: { ...coverage, activation_sessions_inspected: 1, activation_ledgers_loaded: 1 } }))
  await loadEvidence()
  expect(screen.getByText(/N\/A/)).toBeTruthy()
  expect(screen.getByText(/Original activation/)).toBeTruthy()
  expect(screen.getByText(/skill-call-1/)).toBeTruthy()
})
it('preserves evidence read errors without inventing performance statistics', async () => {
  api.fetchSkillEvidence.mockRejectedValue(new Error('retained evidence read failed'))
  render(html`<${SkillsPanel} />`)
  fireEvent.click(await screen.findByRole('button', { name: 'Read instructions for proof' }))
  fireEvent.click(screen.getByRole('button', { name: 'Load' }))
  expect((await screen.findByRole('alert')).textContent).toContain('retained evidence read failed')
  expect(screen.queryByText(/retained runs/)).toBeNull()
})
