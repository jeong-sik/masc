import { html } from 'htm/preact'
import type { Signal } from '@preact/signals'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AsyncRequestObservation, SkillEvidenceResponse, SkillReference, SkillsResponse } from '../api/dashboard-skills'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'

const api = vi.hoisted(() => ({ fetchSkills: vi.fn(), fetchAsyncRequestObservation: vi.fn(), fetchSkillEvidence: vi.fn(),
  fetchWritableSkillSources: vi.fn(), createSkill: vi.fn(), readSkillSource: vi.fn(), previewSkillSource: vi.fn(), saveSkillSource: vi.fn() }))
const exactRequests = vi.hoisted(() => ({ fetchAsyncRequestStatus: vi.fn() }))
const workspace = vi.hoisted(() => ({ current: null as unknown as Signal<ExecutionWorkspaceAuthority | null> }))
vi.mock('../store', async () => {
  const { signal } = await import('@preact/signals')
  workspace.current = (await import('../execution-workspace-authority')).acceptedExecutionWorkspace
  return { executionWorkspaceAuthority: workspace.current, keepers: signal([]), executionLoaded: signal(false) }
})
vi.mock('../api/dashboard-skills', async original => ({ ...await original<typeof import('../api/dashboard-skills')>(), ...api }))
vi.mock('../api/composition-observation', async original => ({ ...await original<typeof import('../api/composition-observation')>(), ...exactRequests }))
import { SkillsPanel } from './skills-panel'
import { clearStoredToken, setStoredToken } from '../api/core'

function pending<T>() {
  let resolve!: (value: T) => void
  let reject!: (error: Error) => void
  const promise = new Promise<T>((ok, fail) => { resolve = ok; reject = fail })
  return { promise, resolve, reject }
}
const authority = (root = '/workspace-a'): ExecutionWorkspaceAuthority => ({ epoch: 'fixture', workspaceRoot: root, connectionGeneration: 1, observerInstanceId: 'fixture-instance' })
const reference = (name: string): SkillReference => ({ identity: { source_id: 'workspace', package_id: name, name }, content_revision: `revision-${name}` })
function catalog(names = ['alpha', 'beta']): SkillsResponse {
  return { schema: 'masc.skill-snapshot/v1', state: 'ready', snapshot: {
    snapshot_revision: 'snapshot', catalog_revision: 'catalog', config: { kind: 'unreadable' }, sources: [],
    skills: names.map(name => ({ ...reference(name), description: `about ${name}`, body_bytes: 10 })),
    effective_skills: names.map(name => reference(name).identity), shadows: [], rejections: [],
  }, surfaces: names.map(name => ({ reference: reference(name), kind: 'unavailable', error: 'fixture has no profile' })) }
}
const observation = (id: string): AsyncRequestObservation => ({ schema: 'masc.async-request-observation/v1', status: 'ready',
  summary: { active: 1, runtime_owned: 1, ownership_unknown: 0, record_errors: 0 }, record_errors: [], startup_recovery: null,
  requests: [{ request_id: id, keeper_name: 'owner', submitted_by: 'operator', request_context: null, status: 'running', submitted_at: 1, worker_ownership: 'runtime_owned' }] })
const evidence = (name: string, sessions: number): SkillEvidenceResponse => ({ schema: 'masc.skill-evidence/v9',
  status: 'not_observed_in_retained_coverage', reference: reference(name), activation: null, composition: null,
  composition_selection: { mode: 'latest_retained' }, composition_runs: [],
  composition_statistics: { scope: 'exact_reference_retained_runs', duration_scope: 'stored_executor_result', percentile_method: 'nearest_rank',
    records: 0, recorded_window: { first_recorded_at: null, last_recorded_at: null },
    completed: { samples: 0, mean_ms: null, min_ms: null, p50_ms: null, p95_ms: null, max_ms: null },
    failed: { samples: 0, mean_ms: null, min_ms: null, p50_ms: null, p95_ms: null, max_ms: null }, deferred: 0 },
  coverage: { composition_scope: 'exact_reference_retained_runs', composition_runs_observed: 0, composition_unavailable: [], coverage_complete: false,
    activation_scope: 'complete_retained_trace_snapshot', activation_sessions_inspected: sessions, activation_ledgers_loaded: 0, activation_gaps: [], activation_owner_gap_count: 0 } })
const open = async (name: string) => fireEvent.click(await screen.findByRole('button', { name: `Read instructions for ${name}` }))
const load = () => fireEvent.click(screen.getByRole('button', { name: 'Load' }))

beforeEach(() => {
  expect(executionWorkspaceAuthority).toBe(workspace.current)
  for (const mock of Object.values(api)) mock.mockReset()
  exactRequests.fetchAsyncRequestStatus.mockReset().mockResolvedValue({ status: 'absent' })
  workspace.current.value = authority()
  setStoredToken('credential-a')
  api.fetchSkills.mockResolvedValue(catalog())
  api.fetchAsyncRequestObservation.mockResolvedValue(observation('current-request'))
  api.readSkillSource.mockImplementation(async (ref: SkillReference) => ({ status: 'ready', reference: ref, snapshot_revision: 'snapshot', source_text: 'source', access: 'read_write' }))
})
afterEach(() => { cleanup(); clearStoredToken() })

async function startCreate(name = 'created') {
  api.fetchWritableSkillSources.mockResolvedValue([{ source_id: 'workspace' }])
  fireEvent.click(await screen.findByRole('button', { name: '+ New Skill' }))
  await screen.findByRole('option', { name: 'workspace' })
  fireEvent.input(screen.getByPlaceholderText('skill-name'), { target: { value: name } })
  fireEvent.input(screen.getByPlaceholderText('When should an agent use this?'), { target: { value: 'description' } })
  fireEvent.submit(screen.getByTestId('skill-create'))
  await waitFor(() => expect(api.createSkill).toHaveBeenCalledTimes(1))
}
const preview = () => ({ profile: { reference: reference('alpha'), kind: 'instruction', activation_tool: 'keeper_skill',
  execution: 'model_orchestrated', io: { kind: 'model_orchestrated' }, capabilities: { as_skill: true, as_tool: false,
    batch: false, parallel: false, async: false, tool_scope: 'model_orchestrated' },
  context: { body_bytes: 10, discovery_bytes: 10, tool_schema_bytes: null },
  plan: { node_count: 0, batch_count: 0, parallel_batch_count: 0, max_parallelism: 0, statically_read_only: null },
  declaration: null, flow: null }, diagnostics: [] })
async function startSave() {
  api.previewSkillSource.mockResolvedValue(preview())
  await open('alpha')
  fireEvent.click(screen.getByTestId('skill-edit-open'))
  await screen.findByTestId('skill-source-draft')
  fireEvent.click(screen.getByRole('button', { name: 'Preview' }))
  await screen.findByTestId('skill-source-preview')
  fireEvent.click(screen.getByTestId('skill-source-save'))
  await waitFor(() => expect(api.saveSkillSource).toHaveBeenCalledTimes(1))
}

describe('Skills observation owner', () => {
  it('retains the selected exact request after its active inventory row disappears', async () => {
    exactRequests.fetchAsyncRequestStatus.mockResolvedValue({ status: 'observed',
      request: { request_id: 'current-request', submitted_by: 'operator', keeper_name: 'owner', request_context: null, status: 'done' }, nested: { kind: 'absent' } })
    render(html`<${SkillsPanel} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Inspect exact request' }))
    await screen.findByText('Request state: done')
    api.fetchAsyncRequestObservation.mockResolvedValue({ schema: 'masc.async-request-observation/v1', status: 'ready',
      summary: { active: 0, runtime_owned: 0, ownership_unknown: 0, record_errors: 0 }, record_errors: [], startup_recovery: null, requests: [] })
    const { publishDashboardObservationChange } = await import('../lib/observation-refresh')
    await act(async () => { publishDashboardObservationChange({ topic: 'async_requests' }) })
    await screen.findByText('No durable active requests.')
    expect(screen.getByRole('region', { name: 'Exact async request' })).toBeTruthy()
    expect(screen.getByText('Request state: done')).toBeTruthy()
    expect(exactRequests.fetchAsyncRequestStatus).toHaveBeenCalledWith({ submitted_by: 'operator', keeper_name: 'owner', request_id: 'current-request' }, { signal: expect.any(AbortSignal) })
  })

  it('can look up an exact retained request that was never in the active inventory', async () => {
    render(html`<${SkillsPanel} />`)
    await screen.findByTestId('skills-table')
    fireEvent.input(screen.getByLabelText('Request submitter'), { target: { value: 'original-submitter' } })
    fireEvent.input(screen.getByLabelText('Request Keeper'), { target: { value: 'original-keeper' } })
    fireEvent.input(screen.getByLabelText('Request ID'), { target: { value: 'retained-only-id' } })
    fireEvent.submit(screen.getByRole('form', { name: 'Retained async request lookup' }))
    await screen.findByText('Request absent')
    expect(exactRequests.fetchAsyncRequestStatus).toHaveBeenCalledWith({ submitted_by: 'original-submitter', keeper_name: 'original-keeper', request_id: 'retained-only-id' }, { signal: expect.any(AbortSignal) })
  })

  it('waits without fetching when workspace observation authority is unknown', async () => {
    workspace.current.value = null
    render(html`<${SkillsPanel} />`)
    await act(async () => {})
    expect(api.fetchSkills).not.toHaveBeenCalled()
    expect(api.fetchAsyncRequestObservation).not.toHaveBeenCalled()
    expect(screen.queryByTestId('skills-table')).toBeNull()
  })

  it('withdraws ready catalog and async rows immediately when workspace is lost', async () => {
    render(html`<${SkillsPanel} />`)
    await screen.findByTestId('skills-table')
    await screen.findByText(/current-request/)
    await act(async () => { workspace.current.value = null })
    expect(screen.queryByTestId('skills-table')).toBeNull()
    expect(screen.queryByTestId('async-request-observation')).toBeNull()
  })

  it('does not revive catalog success or async error through auth A to B to A', async () => {
    const old = pending<SkillsResponse>(), middle = pending<SkillsResponse>(), fresh = pending<SkillsResponse>()
    const oldAsync = pending<AsyncRequestObservation>(), midAsync = pending<AsyncRequestObservation>()
    api.fetchSkills.mockReturnValueOnce(old.promise).mockReturnValueOnce(middle.promise).mockReturnValueOnce(fresh.promise)
    api.fetchAsyncRequestObservation.mockReturnValueOnce(oldAsync.promise).mockReturnValueOnce(midAsync.promise).mockResolvedValueOnce(observation('fresh-async'))
    render(html`<${SkillsPanel} />`)
    await waitFor(() => expect(api.fetchSkills).toHaveBeenCalledTimes(1))
    await act(async () => setStoredToken('credential-b'))
    await waitFor(() => expect(api.fetchSkills).toHaveBeenCalledTimes(2))
    await act(async () => setStoredToken('credential-a'))
    await waitFor(() => expect(api.fetchSkills).toHaveBeenCalledTimes(3))
    await act(async () => fresh.resolve(catalog(['fresh'])))
    await screen.findByRole('button', { name: 'Read instructions for fresh' })
    await act(async () => { old.resolve(catalog(['retired'])); middle.reject(new Error('retired catalog')); oldAsync.reject(new Error('retired async')); midAsync.resolve(observation('retired-async')) })
    expect(screen.queryByRole('button', { name: 'Read instructions for retired' })).toBeNull()
    expect(screen.queryByText(/retired async|retired-async|retired catalog/)).toBeNull()
  })

  it('uses workspace object identity even when a new authority has equal fields', async () => {
    render(html`<${SkillsPanel} />`)
    await screen.findByTestId('skills-table')
    const fresh = pending<SkillsResponse>()
    api.fetchSkills.mockReturnValueOnce(fresh.promise)
    await act(async () => { workspace.current.value = authority() })
    expect(screen.queryByTestId('skills-table')).toBeNull()
    await waitFor(() => expect(api.fetchSkills).toHaveBeenCalledTimes(2))
    await act(async () => fresh.resolve(catalog(['fresh'])))
    await screen.findByRole('button', { name: 'Read instructions for fresh' })
  })

  it('does not let an old row read finish the currently selected row loading', async () => {
    const first = pending<SkillEvidenceResponse>(), second = pending<SkillEvidenceResponse>()
    api.fetchSkillEvidence.mockReturnValueOnce(first.promise).mockReturnValueOnce(second.promise)
    render(html`<${SkillsPanel} />`)
    await open('alpha'); load()
    await open('beta'); load()
    await act(async () => first.resolve(evidence('alpha', 1)))
    expect((screen.getByRole('button', { name: 'Loading…' }) as HTMLButtonElement).disabled).toBe(true)
    await act(async () => second.resolve(evidence('beta', 2)))
    await screen.findByText(/2 retained sessions inspected/)
  })

  it('rejects evidence success and error from a prior A to B to A row visit', async () => {
    const old = pending<SkillEvidenceResponse>(), fresh = pending<SkillEvidenceResponse>()
    api.fetchSkillEvidence.mockReturnValueOnce(old.promise).mockReturnValueOnce(fresh.promise)
    render(html`<${SkillsPanel} />`)
    await open('alpha'); load()
    await open('beta'); await open('alpha'); load()
    await act(async () => fresh.resolve(evidence('alpha', 7)))
    await screen.findByText(/7 retained sessions inspected/)
    await act(async () => old.reject(new Error('retired row failure')))
    expect(screen.queryByRole('alert')).toBeNull()
    expect(screen.getByText(/7 retained sessions inspected/)).toBeTruthy()
  })

  it('reports an evidence contract failure from the API boundary', async () => {
    const detail = 'evidence response disagrees with requested reference or selection'
    api.fetchSkillEvidence.mockRejectedValue(new Error(detail))
    render(html`<${SkillsPanel} />`)
    await open('alpha'); load()
    expect((await screen.findByRole('alert')).textContent).toContain(detail)
    expect(api.fetchSkillEvidence).toHaveBeenCalledWith(reference('alpha'), undefined)
  })

  it('withdraws loaded evidence across credential changes', async () => {
    api.fetchSkillEvidence.mockResolvedValue(evidence('alpha', 12))
    render(html`<${SkillsPanel} />`)
    await open('alpha'); load()
    await screen.findByText(/12 retained sessions inspected/)
    await act(async () => setStoredToken('credential-b'))
    expect(screen.queryByText(/12 retained sessions inspected/)).toBeNull()
    await open('alpha')
    expect(screen.queryByText(/12 retained sessions inspected/)).toBeNull()
  })

  it('retains a sent create receipt across workspace change without refreshing the new workspace', async () => {
    const sent = pending<{ status: 'created_and_published' }>()
    api.createSkill.mockReturnValueOnce(sent.promise)
    render(html`<${SkillsPanel} />`)
    await startCreate()
    api.fetchSkills.mockResolvedValueOnce(catalog(['fresh']))
    await act(async () => { workspace.current.value = authority('/workspace-b') })
    await screen.findByRole('button', { name: 'Read instructions for fresh' })
    await act(async () => sent.resolve({ status: 'created_and_published' }))
    expect(screen.getByTestId('skill-mutation-receipts').textContent).toContain('created and published')
    expect(screen.getByTestId('skill-mutation-receipts').textContent).toContain('/workspace-a')
    expect(api.fetchSkills).toHaveBeenCalledTimes(2)
    expect(api.createSkill).toHaveBeenCalledTimes(1)
  })

  it('preserves the create receipt separately from a failed same-owner catalog refresh', async () => {
    api.createSkill.mockResolvedValueOnce({ status: 'created_and_published' })
    render(html`<${SkillsPanel} />`)
    await screen.findByTestId('skills-table')
    api.fetchSkills.mockRejectedValueOnce(new Error('refresh failed after create'))
    await startCreate()
    await screen.findByRole('alert')
    expect(screen.getByTestId('skill-mutation-receipts').textContent).toContain('created and published')
    expect(screen.getByRole('alert').textContent).toContain('refresh failed after create')
    expect(api.createSkill).toHaveBeenCalledTimes(1)
  })

  it('retains a save receipt after auth change without accepting its follow-up read', async () => {
    const sent = pending<{ status: 'saved_and_published'; preview: ReturnType<typeof preview>; snapshot_revision: string }>()
    api.saveSkillSource.mockReturnValueOnce(sent.promise)
    render(html`<${SkillsPanel} />`)
    await startSave()
    api.fetchSkills.mockResolvedValueOnce(catalog(['fresh']))
    await act(async () => setStoredToken('credential-b'))
    await screen.findByRole('button', { name: 'Read instructions for fresh' })
    await act(async () => sent.resolve({ status: 'saved_and_published', preview: preview(), snapshot_revision: 'next' }))
    expect(screen.getByTestId('skill-mutation-receipts').textContent).toContain('workspace/alpha/alpha @ revision-alpha: saved_and_published')
    expect(api.fetchSkills).toHaveBeenCalledTimes(2)
    expect(api.saveSkillSource).toHaveBeenCalledTimes(1)
  })

  it('keeps a retired save request error while workspace is unknown without claiming no effect', async () => {
    const sent = pending<never>()
    api.saveSkillSource.mockReturnValueOnce(sent.promise)
    render(html`<${SkillsPanel} />`)
    await startSave()
    await act(async () => { workspace.current.value = null })
    await act(async () => sent.reject(new Error('transport stopped after send')))
    expect(screen.getByTestId('skill-mutation-receipts').textContent).toContain('save request for workspace/alpha/alpha @ revision-alpha')
    expect(screen.getByTestId('skill-mutation-receipts').textContent).toContain('effect not confirmed')
    expect(screen.getByTestId('skill-mutation-receipts').textContent).toContain('transport stopped after send')
    expect(api.fetchSkills).toHaveBeenCalledTimes(1)
    expect(api.saveSkillSource).toHaveBeenCalledTimes(1)
  })

})

it('identifies reversed create successes and errors by their original submitted Skill', async () => {
  const first = pending<{ status: 'created_and_published' }>(), second = pending<never>()
  api.createSkill.mockReturnValueOnce(first.promise).mockReturnValueOnce(second.promise)
  render(html`<${SkillsPanel} />`)
  await startCreate('first')
  fireEvent.input(screen.getByPlaceholderText('skill-name'), { target: { value: 'second' } })
  fireEvent.submit(screen.getByTestId('skill-create'))
  await waitFor(() => expect(api.createSkill).toHaveBeenCalledTimes(2))
  await act(async () => second.reject(new Error('second transport failure')))
  await act(async () => first.resolve({ status: 'created_and_published' }))
  const receipts = screen.getByTestId('skill-mutation-receipts').textContent
  expect(receipts).toContain('create request for workspace/second/second returned an error; effect not confirmed: second transport failure')
  expect(receipts).toContain('Create response for workspace/first/first: created and published')
})
