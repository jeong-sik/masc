import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { SkillEditorPreview } from '../api/dashboard-skills'
const api = vi.hoisted(() => ({ createSkill: vi.fn(), previewNewSkillSource: vi.fn(),
  fetchWritableSkillSources: vi.fn(), fetchSkillAuthoringTools: vi.fn() }))
vi.mock('../api/dashboard-skills', () => api)
import { SkillCreateForm } from './skill-create-form'

const identity = { source_id: 'workspace', package_id: 'inspect-lane', name: 'inspect-lane' }
const preview: SkillEditorPreview = {
  profile: { reference: { identity, content_revision: 'a'.repeat(64) }, kind: 'composition',
    execution: 'async', activation_tool: 'skill__inspect_lane',
    io: { kind: 'composition', input_schema: { type: 'object' }, exports: [] },
    capabilities: { as_skill: true, as_tool: true, batch: true, parallel: false, async: true, tool_scope: 'registered_tools_only' },
    context: { body_bytes: 10, discovery_bytes: 10, tool_schema_bytes: 10 },
    plan: { node_count: 2, batch_count: 2, parallel_batch_count: 0, max_parallelism: 1, statically_read_only: true },
    declaration: null, flow: { nodes: [], batches: [] } }, diagnostics: [],
}
const receipts = vi.fn(), errors = vi.fn(), refresh = vi.fn()
function mount(isCurrent = () => true) {
  return render(html`<${SkillCreateForm} isCurrent=${isCurrent} onReceipt=${receipts}
    onRequestError=${errors} onPublished=${refresh} />`)
}
async function describeDraft() {
  await screen.findByRole('option', { name: 'workspace' })
  fireEvent.input(screen.getByLabelText('Skill name'), { target: { value: 'inspect-lane' } })
  fireEvent.input(screen.getByLabelText('Skill description'), { target: { value: 'Inspect the current lane.' } })
  fireEvent.input(screen.getByLabelText('Skill instructions'), { target: { value: 'Keep the observation and verify the result.' } })
}
function pending<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(done => { resolve = done })
  return { resolve, promise }
}
beforeEach(() => {
  for (const mock of Object.values(api)) mock.mockReset()
  receipts.mockReset(); errors.mockReset(); refresh.mockReset()
  api.fetchWritableSkillSources.mockResolvedValue([{ source_id: 'workspace' }])
  api.fetchSkillAuthoringTools.mockResolvedValue([{ name: 'keeper_lane_status', description: 'Observe the lane.',
    input_schema: { type: 'object' }, output: { kind: 'json', schema: { type: 'object', properties: { profile: { type: 'string' } } } }, execution: 'concurrent' }])
  api.previewNewSkillSource.mockResolvedValue(preview)
  api.createSkill.mockResolvedValue({ status: 'created_and_published' })
})
afterEach(cleanup)

describe('Skill creation', () => {
  it('requires an explicit source choice when more than one authority is writable', async () => {
    api.fetchWritableSkillSources.mockResolvedValue([{ source_id: 'workspace' }, { source_id: 'personal' }])
    mount()
    await describeDraft()
    expect((screen.getByLabelText('Skill source') as HTMLSelectElement).value).toBe('')
    expect((screen.getByRole('button', { name: 'Create + publish' }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.change(screen.getByLabelText('Skill source'), { target: { value: 'personal' } })
    fireEvent.submit(screen.getByTestId('skill-create'))
    await waitFor(() => expect(api.createSkill).toHaveBeenCalledWith(expect.objectContaining({ source_id: 'personal' })))
    expect(receipts).toHaveBeenCalledWith({ ...identity, source_id: 'personal' }, { status: 'created_and_published' })
  })

  it('previews and creates authored steps, dependencies, typed input and named outputs with the same bytes', async () => {
    mount()
    await describeDraft()
    fireEvent.change(screen.getByLabelText('Skill kind'), { target: { value: 'composition' } })
    fireEvent.input(screen.getByLabelText('Skill instructions'), { target: { value: 'An unfinished example:\n```json\n{}' } })
    await waitFor(() => expect(api.fetchSkillAuthoringTools).toHaveBeenCalledOnce())
    fireEvent.change(screen.getByLabelText('Composition execution'), { target: { value: 'async' } })
    fireEvent.change(screen.getByLabelText('Branch failure policy'), { target: { value: 'continue_independent' } })
    fireEvent.click(screen.getByRole('button', { name: 'Add step' }))
    fireEvent.click(screen.getByRole('button', { name: 'Add step' }))
    fireEvent.input(screen.getByLabelText('Step 1 tool'), { target: { value: 'keeper_lane_status' } })
    fireEvent.input(screen.getByLabelText('Step 2 tool'), { target: { value: 'keeper_lane_status' } })
    fireEvent.change(screen.getByLabelText('Step 2 input mode'), { target: { value: 'template' } })
    fireEvent.input(screen.getByLabelText('Step 2 input'), { target: { value: '{"kind":"literal","value":{}}' } })
    fireEvent.click(screen.getByLabelText('step-1'))
    fireEvent.click(screen.getByRole('button', { name: 'Add output' }))
    fireEvent.input(screen.getByLabelText('Output 1 name'), { target: { value: 'profile' } })
    fireEvent.change(screen.getByLabelText('Output 1 step'), { target: { value: '2' } })
    fireEvent.input(screen.getByLabelText('Output 1 pointer'), { target: { value: '/profile' } })
    fireEvent.click(screen.getByRole('button', { name: 'Validate draft' }))
    await screen.findByLabelText('New Skill preview')
    const requested = api.previewNewSkillSource.mock.calls[0]![0]
    expect(requested.kind).toBe('composition')
    expect(requested.source_text.indexOf('```toml composition')).toBeLessThan(requested.source_text.indexOf('An unfinished example:'))
    const encoded = requested.source_text.split('\n').find((line: string) => line.startsWith('plan_json = '))!.slice('plan_json = '.length)
    expect(JSON.parse(JSON.parse(encoded))).toEqual({ nodes: [
      { id: 'step-1', tool: 'keeper_lane_status', after: [], args: {} },
      { id: 'step-2', tool: 'keeper_lane_status', after: ['step-1'], input: { kind: 'literal', value: {} } },
    ], branch_failure_policy: 'continue_independent', exports: [{ name: 'profile', node: 'step-2', pointer: '/profile' }] })
    expect(requested.source_text).toContain('execution = "async"')
    expect(api.createSkill).not.toHaveBeenCalled()
    const fields = screen.getByTestId('skill-create').querySelectorAll<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>('input,select,textarea')
    expect([...fields].filter(field => !field.checkValidity()).map(field => ({ label: field.getAttribute('aria-label'), value: field.value }))).toEqual([])
    fireEvent.click(screen.getByRole('button', { name: 'Create + publish' }))
    await waitFor(() => expect(api.createSkill).toHaveBeenCalledWith(requested))
    expect(receipts).toHaveBeenCalledWith(identity, { status: 'created_and_published' })
    expect(refresh).toHaveBeenCalledOnce()
  })

  it('withdraws stale preview while preserving an edited draft when an older preview arrives', async () => {
    const sent = pending<SkillEditorPreview>()
    api.previewNewSkillSource.mockReturnValueOnce(sent.promise)
    mount()
    await describeDraft()
    fireEvent.click(screen.getByRole('button', { name: 'Validate draft' }))
    await waitFor(() => expect(api.previewNewSkillSource).toHaveBeenCalledOnce())
    fireEvent.input(screen.getByLabelText('Skill description'), { target: { value: 'New purpose' } })
    await act(async () => sent.resolve(preview))
    expect(screen.queryByLabelText('New Skill preview')).toBeNull()
    fireEvent.submit(screen.getByTestId('skill-create'))
    await waitFor(() => expect(api.createSkill).toHaveBeenCalledWith(expect.objectContaining({ source_text: expect.stringContaining('New purpose') })))
    expect((screen.getByLabelText('Skill description') as HTMLInputElement).value).toBe('New purpose')
  })

  it('keeps a compiler refusal and performs no mutation during validation', async () => {
    api.previewNewSkillSource.mockRejectedValueOnce(new Error('unknown tool: unavailable_tool'))
    mount()
    await describeDraft()
    fireEvent.click(screen.getByRole('button', { name: 'Validate draft' }))
    await screen.findByText('unknown tool: unavailable_tool')
    expect(api.createSkill).not.toHaveBeenCalled()
    expect(receipts).not.toHaveBeenCalled()
    expect(errors).not.toHaveBeenCalled()
  })

  it('does not publish or claim a sent mutation for invalid JSON input', async () => {
    mount()
    await describeDraft()
    fireEvent.change(screen.getByLabelText('Skill kind'), { target: { value: 'composition' } })
    fireEvent.click(screen.getByRole('button', { name: 'Add step' }))
    fireEvent.input(screen.getByLabelText('Step 1 input'), { target: { value: '{' } })
    fireEvent.submit(screen.getByTestId('skill-create'))
    await waitFor(() => expect(screen.getByTestId('skill-create-status').textContent).toBe('Step step-1: input must be valid JSON.'))
    expect(api.createSkill).not.toHaveBeenCalled()
    expect(errors).not.toHaveBeenCalled()
  })
})
