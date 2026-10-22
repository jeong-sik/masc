import { html } from 'htm/preact'
import type { Signal } from '@preact/signals'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AsyncRequestObservation, SkillEvidenceResponse, SkillReference, SkillsResponse } from '../api/dashboard-skills'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'

const api = vi.hoisted(() => ({ fetchSkills: vi.fn(), fetchAsyncRequestObservation: vi.fn(), fetchSkillEvidence: vi.fn(),
  fetchWritableSkillSources: vi.fn(), createSkill: vi.fn(), readSkillSource: vi.fn(), previewSkillSource: vi.fn(), saveSkillSource: vi.fn() }))
const workspace = vi.hoisted(() => ({ current: null as unknown as Signal<ExecutionWorkspaceAuthority | null> }))
vi.mock('../store', async () => {
  const { signal } = await import('@preact/signals')
  workspace.current = signal<ExecutionWorkspaceAuthority | null>(null)
  return { executionWorkspaceAuthority: workspace.current }
})
vi.mock('../api/dashboard-skills', async original => ({ ...await original<typeof import('../api/dashboard-skills')>(), ...api }))
import { SkillsPanel } from './skills-panel'
import { clearStoredToken, setStoredToken } from '../api/core'

function pending<T>() {
  let resolve!: (value: T) => void
  let reject!: (error: Error) => void
  const promise = new Promise<T>((ok, fail) => { resolve = ok; reject = fail })
  return { promise, resolve, reject }
}
const authority = (root = '/workspace-a'): ExecutionWorkspaceAuthority => ({ epoch: 'fixture', workspaceRoot: root, connectionGeneration: 1 })
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
const evidence = (name: string, sessions: number): SkillEvidenceResponse => ({ schema: 'masc.skill-evidence/v7',
  status: 'not_observed_in_retained_coverage', reference: reference(name), activation: null, composition: null, composition_statistics: null,
  coverage: { composition_scope: 'exact_reference_latest_completed', composition_records_read: 0, composition_unavailable: [], coverage_complete: false,
    activation_scope: 'complete_retained_trace_snapshot', activation_sessions_inspected: sessions, activation_ledgers_loaded: 0, activation_gaps: [], activation_owner_gap_count: 0 } })
const open = async (name: string) => fireEvent.click(await screen.findByRole('button', { name: `Read instructions for ${name}` }))
const load = () => fireEvent.click(screen.getByRole('button', { name: 'Load' }))

beforeEach(() => {
  expect(executionWorkspaceAuthority).toBe(workspace.current)
  for (const mock of Object.values(api)) mock.mockReset()
  workspace.current.value = authority()
  setStoredToken('credential-a')
  api.fetchSkills.mockResolvedValue(catalog())
  api.fetchAsyncRequestObservation.mockResolvedValue(observation('current-request'))
  api.readSkillSource.mockImplementation(async (ref: SkillReference) => ({ status: 'ready', reference: ref, snapshot_revision: 'snapshot', source_text: 'source', access: 'read_write' }))
})
afterEach(() => { cleanup(); clearStoredToken() })

async function startCreate() {
  api.fetchWritableSkillSources.mockResolvedValue([{ source_id: 'workspace' }])
  fireEvent.click(await screen.findByRole('button', { name: '+ New Skill' }))
  await screen.findByRole('option', { name: 'workspace' })
  fireEvent.input(screen.getByPlaceholderText('skill-name'), { target: { value: 'created' } })
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

  it('rejects a valid evidence envelope for another selected reference', async () => {
    api.fetchSkillEvidence.mockResolvedValue(evidence('beta', 99))
    render(html`<${SkillsPanel} />`)
    await open('alpha'); load()
    await screen.findByRole('alert')
    expect(screen.queryByText(/99 retained sessions inspected/)).toBeNull()
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
    expect(screen.getByTestId('skill-mutation-receipts').textContent).toContain('saved_and_published')
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
    expect(screen.getByTestId('skill-mutation-receipts').textContent).toContain('effect not confirmed')
    expect(screen.getByTestId('skill-mutation-receipts').textContent).toContain('transport stopped after send')
    expect(api.fetchSkills).toHaveBeenCalledTimes(1)
    expect(api.saveSkillSource).toHaveBeenCalledTimes(1)
  })

})
