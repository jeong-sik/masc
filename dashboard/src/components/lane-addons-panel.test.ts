import { html } from 'htm/preact'
import { cleanup, fireEvent, render, waitFor, within } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { parseLaneAddonSnapshot, parseLaneAddonSlice, parseLaneAddonActionReceipt } from '../api/lane-addons'

const api = vi.hoisted(() => ({
  fetchLaneAddons: vi.fn(), fetchLaneAddonSlice: vi.fn(), attachLaneAddon: vi.fn(),
  observeLaneAddon: vi.fn(), detachLaneAddon: vi.fn(), preserveLaneAddonEvidence: vi.fn(),
  requestLaneAddonAction: vi.fn(), fetchLaneAddonAction: vi.fn(),
}))
const transport = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn() }))
vi.mock('../api/core', () => transport)
vi.mock('../api/lane-addons', async original => ({
  ...await original<typeof import('../api/lane-addons')>(), ...api,
}))
import { LaneAddonsPanel } from './lane-addons-panel'

const row = {
  id: 'external-evidence-1', lane_id: 'unregistered-domain', kind: 'relation',
  title: 'Same target, different observed revision', observed_at: 1789064000,
  subject_id: 'target-production', actor: null,
  clock: { domain: 'frame', value: '1234' }, fields: { expected: 'A', observed: 'B' },
  evidence: [{ uri: 'artifact://source/1', sha256: null }], related_ids: ['receipt-3'],
}
const coverage = [{ source_id: 'opaque-input', incarnation: 'run-2', cursor: '7', complete: false, detail: 'Source gap' }]
const snapshot = {
  configuration: null,
  instances: [{ instance_id: 'instance-1', run_id: 'run-2', addon_id: 'unregistered-package',
    title: 'User supplied layer', revision: 'digest-1', phase: { kind: 'observing' },
    configuration: null, incarnation: 'incarnation-1', action_schema: null,
    observation_seq: 1, rows_count: 1 }], rows: [row], coverage,
}
const actionSnapshot = {
  ...snapshot,
  instances: [{ ...snapshot.instances[0], action_schema: { type: 'object', properties: {
    context: { type: 'object' }, request_id: { type: 'string' },
    action: { type: 'object', properties: { operation: { enum: ['publish', 'pause'] } }, required: ['operation'] },
  } } }],
}
const actionRequest = {
  instance_id: 'instance-1', expected_incarnation: 'incarnation-1', request_id: 'request-1', action: { operation: 'publish' },
}
const actionReceipt = {
  instance_id: 'instance-1', incarnation: 'incarnation-1', request_id: 'request-1', requester: 'dashboard-user',
  executor: null, input_sha256: 'receipt-input-digest', action: actionRequest.action,
  state: 'queued', result: null, detail: null,
}
afterEach(() => { cleanup(); vi.resetAllMocks() })

describe('optional Lane Add-on surface', () => {
  it('projects an unknown package and its common evidence without a domain-specific renderer', async () => {
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot(snapshot))
    const screen = render(html`<${LaneAddonsPanel} />`)
    await screen.findByText('User supplied layer')
    expect(screen.getByText('Same target, different observed revision')).toBeTruthy()
    expect(screen.getByText(/actor unknown/)).toBeTruthy()
    expect(screen.getByText(/Source gap/)).toBeTruthy()
    expect(screen.getByText(/World time: frame 1234/)).toBeTruthy()
    expect(screen.getByText('Configuration service has not started.')).toBeTruthy()
    expect(screen.getByText('Not managed by TOML')).toBeTruthy()
    expect(api.preserveLaneAddonEvidence).not.toHaveBeenCalled()
    expect(screen.queryByRole('region', { name: 'Package actions' })).toBeNull()
    expect(screen.queryByLabelText('Action JSON')).toBeNull()
  })
  it('shows installed and pending TOML declarations independently of observation health', async () => {
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot({ ...snapshot,
      configuration: { directory: '/workspace/.masc/config/lane-addons', complete: true, issues: [],
        declarations: [
          { id: 'website', source_path: '/workspace/.masc/config/lane-addons/site.toml',
            desired_revision: 'configuration-1', applied_revision: 'configuration-1', instance_id: 'instance-1' },
          { id: 'game', source_path: '/workspace/.masc/config/lane-addons/game.toml',
            desired_revision: 'configuration-2', applied_revision: null, instance_id: null },
        ] },
      instances: [{ ...snapshot.instances[0], phase: { kind: 'failed', message: 'Browser owner is busy' },
        configuration: { id: 'website', source_path: '/workspace/.masc/config/lane-addons/site.toml', revision: 'configuration-1' } }],
    }))
    const screen = render(html`<${LaneAddonsPanel} />`)
    const declarations = within(await screen.findByRole('table', { name: 'TOML declarations' }))
    expect(screen.getByText('/workspace/.masc/config/lane-addons')).toBeTruthy()
    expect(screen.getByText('Configuration read: complete')).toBeTruthy()
    expect(declarations.getByText('Desired revision applied')).toBeTruthy()
    expect(declarations.getByText('Not yet applied')).toBeTruthy()
    expect(declarations.getByText('No instance')).toBeTruthy()
    expect(screen.getByText('failed')).toBeTruthy()
    expect(screen.getByText('Browser owner is busy')).toBeTruthy()
    expect(within(screen.getByLabelText('Configuration for instance-1')).getByText('Installed configuration: configuration-1')).toBeTruthy()
    expect(api.attachLaneAddon).not.toHaveBeenCalled()
    expect(api.observeLaneAddon).not.toHaveBeenCalled()
  })
  it('keeps the previous instance visible while a changed declaration and parse errors remain unresolved', async () => {
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot({ ...snapshot,
      configuration: { directory: '/workspace/.masc/config/lane-addons', complete: true,
        issues: [
          { source_path: '/workspace/.masc/config/lane-addons/site.toml', id: 'website', message: 'Replacement binding could not be applied' },
          { source_path: '/workspace/.masc/config/lane-addons/broken.toml', id: null, message: 'Expected a closing quote' },
        ],
        declarations: [{ id: 'website', source_path: '/workspace/.masc/config/lane-addons/site.toml',
          desired_revision: 'configuration-2', applied_revision: 'configuration-1', instance_id: 'instance-1' }] },
      instances: [{ ...snapshot.instances[0],
        configuration: { id: 'website', source_path: '/workspace/.masc/config/lane-addons/site.toml', revision: 'configuration-1' } }],
    }))
    const screen = render(html`<${LaneAddonsPanel} />`)
    const declarations = within(await screen.findByRole('table', { name: 'TOML declarations' }))
    expect(screen.getByText('Configuration read: complete')).toBeTruthy()
    expect(declarations.getByText('configuration-2')).toBeTruthy()
    expect(declarations.getByText('configuration-1')).toBeTruthy()
    expect(declarations.getByText('Revision change pending')).toBeTruthy()
    expect(screen.getAllByRole('alert').map(alert => alert.textContent)).toEqual([
      expect.stringContaining('/workspace/.masc/config/lane-addons/site.toml · website — Replacement binding could not be applied'),
      expect.stringContaining('/workspace/.masc/config/lane-addons/broken.toml — Expected a closing quote'),
    ])
    expect(screen.getByText('observing')).toBeTruthy()
    expect((screen.getByRole('button', { name: 'Detach' }) as HTMLButtonElement).disabled).toBe(false)
    expect(api.detachLaneAddon).not.toHaveBeenCalled()

    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot({ ...snapshot,
      configuration: { directory: '/workspace/.masc/config/lane-addons', complete: true, declarations: [],
        issues: [{ source_path: '/workspace/.masc/config/lane-addons/site.toml', id: null, message: 'Invalid TOML string' }] },
      instances: [{ ...snapshot.instances[0],
        configuration: { id: 'website', source_path: '/workspace/.masc/config/lane-addons/site.toml', revision: 'configuration-1' } }],
    }))
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    await screen.findByText('No readable TOML declarations.')
    expect(screen.getByRole('alert').textContent).toContain('/workspace/.masc/config/lane-addons/site.toml — Invalid TOML string')
    expect(screen.getByText('observing')).toBeTruthy()
    expect(within(screen.getByLabelText('Configuration for instance-1')).getByText('Installed configuration: configuration-1')).toBeTruthy()
    expect(api.detachLaneAddon).not.toHaveBeenCalled()
  })
  it('allows detaching while observation is in progress without waiting for observe', async () => {
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot(snapshot))
    api.detachLaneAddon.mockResolvedValue({ phase: { kind: 'detaching' } })
    const screen = render(html`<${LaneAddonsPanel} />`)
    const detach = await screen.findByRole('button', { name: 'Detach' })
    expect((screen.getByRole('button', { name: 'Observe' }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(detach)
    await waitFor(() => expect(api.detachLaneAddon).toHaveBeenCalledWith('instance-1'))
  })
  it('distinguishes semantic lanes from the same package and keeps their full identities accessible', async () => {
    const instance = '14f6117d-6e50-4f10-850e-a3f15cca3312'
    const lanes = [`${instance}/custom/expectation`, `${instance}/custom/browser`]
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot({ ...snapshot, rows:
      lanes.map((lane_id, index) => ({ ...row, id: `row-${index}`, lane_id })) }))
    const screen = render(html`<${LaneAddonsPanel} />`)
    const svg = await screen.findByRole('img', { name: 'Parallel lanes with events and recorded relationships' })
    const labels = [...svg.querySelectorAll('g text')]
    expect(labels.map(label => label.lastChild?.textContent)).toEqual([
      'custom/browser · 5cca3312', 'custom/expectation · 5cca3312',
    ])
    expect(labels.map(label => label.getAttribute('aria-label')).sort()).toEqual([...lanes].sort())
    expect(labels.map(label => label.querySelector('title')?.textContent).sort()).toEqual([...lanes].sort())
  })
  it('distinguishes matching local lanes from UUIDv7 instances sharing a timestamp prefix', async () => {
    const instances = ['0198ca47-9000-7000-8000-aaaa11111111', '0198ca47-9000-7000-8000-aaaa22222222']
    const lanes = instances.map(instance => `${instance}/custom/observation`)
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot({ ...snapshot,
      instances: instances.map(instance_id => ({ ...snapshot.instances[0], instance_id })), rows:
      lanes.map((lane_id, index) => ({ ...row, id: `row-${index}`, lane_id })) }))
    const screen = render(html`<${LaneAddonsPanel} />`)
    const svg = await screen.findByRole('img', { name: 'Parallel lanes with events and recorded relationships' })
    const labels = [...svg.querySelectorAll('g text')]
    expect(labels.map(label => label.lastChild?.textContent)).toEqual([
      'custom/observation · 11111111', 'custom/observation · 22222222',
    ])
    expect(labels.map(label => label.getAttribute('aria-label'))).toEqual(lanes)
  })
  it('queries the selected time and lane, showing partial coverage and explicit evidence action', async () => {
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot(snapshot))
    api.fetchLaneAddonSlice.mockResolvedValue(parseLaneAddonSlice({ rows: [row], coverage, complete: false }))
    api.preserveLaneAddonEvidence.mockResolvedValue({ retained: true })
    const screen = render(html`<${LaneAddonsPanel} />`)
    await screen.findByText('User supplied layer')
    fireEvent.input(screen.getByLabelText('Run filter'), { target: { value: 'run-2' } })
    fireEvent.input(screen.getByLabelText('Lane filter'), { target: { value: 'unregistered-domain' } })
    fireEvent.input(screen.getByLabelText('Since (Unix seconds)'), { target: { value: '0' } })
    fireEvent.click(screen.getByRole('button', { name: 'Slice', exact: true }))
    await screen.findByText('Slice: partial')
    expect(api.fetchLaneAddonSlice).toHaveBeenCalledWith({ run_id: 'run-2', lane_id: 'unregistered-domain', since: 0, until: undefined }, expect.any(AbortSignal))
    fireEvent.click(screen.getByRole('radio'))
    fireEvent.click(screen.getByRole('checkbox'))
    fireEvent.click(screen.getByRole('button', { name: 'Preserve selected evidence' }))
    await waitFor(() => expect(api.preserveLaneAddonEvidence).toHaveBeenCalledWith('instance-1', ['external-evidence-1'], undefined))
  })
  it('keeps a failed optional read local and allows leaving while a read remains pending', async () => {
    api.fetchLaneAddons.mockRejectedValueOnce(new Error('observer unreachable'))
    const screen = render(html`<${LaneAddonsPanel} />`)
    await screen.findByRole('alert')
    expect(screen.getByRole('alert').textContent).toContain('observer unreachable')
    api.fetchLaneAddons.mockImplementation(() => new Promise(() => {}))
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    const signal = api.fetchLaneAddons.mock.calls.at(-1)?.[0] as AbortSignal
    screen.unmount()
    expect(signal.aborted).toBe(true)
  })
  it('attaches a user package with the supplied binding through the common contract', async () => {
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot({ configuration: null, instances: [], rows: [], coverage: [] }))
    api.attachLaneAddon.mockResolvedValue({ instance_id: 'new-instance' })
    const screen = render(html`<${LaneAddonsPanel} />`)
    await screen.findByText('No attached packages.')
    fireEvent.click(screen.getByText('Attach a package'))
    fireEvent.input(screen.getByLabelText('Manifest path'), { target: { value: '/packages/user-layer/manifest.json' } })
    fireEvent.input(screen.getByLabelText('Run ID'), { target: { value: 'run-custom' } })
    fireEvent.input(screen.getByLabelText('Binding JSON'), { target: { value: '{"subject_id":"existing-target"}' } })
    fireEvent.click(screen.getByRole('button', { name: 'Attach', exact: true }))
    await waitFor(() => expect(api.attachLaneAddon).toHaveBeenCalledWith('/packages/user-layer/manifest.json', 'run-custom', { subject_id: 'existing-target' }))
  })
  it('selects a cross-lane time range by dragging and submits that exact query window', async () => {
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot({ ...snapshot, rows: [
      { ...row, id: 'first', observed_at: 1000 },
      { ...row, id: 'second', lane_id: 'another-lane', observed_at: 2000 },
    ] }))
    api.fetchLaneAddonSlice.mockResolvedValue(parseLaneAddonSlice({ rows: [], coverage, complete: false }))
    const screen = render(html`<${LaneAddonsPanel} />`)
    const svg = await screen.findByRole('img', { name: 'Parallel lanes with events and recorded relationships' })
    vi.spyOn(svg, 'getBoundingClientRect').mockReturnValue({ left: 0, width: 960, top: 0, height: 100,
      right: 960, bottom: 100, x: 0, y: 0, toJSON: () => ({}) })
    fireEvent.pointerDown(svg, { pointerId: 7, button: 0, isPrimary: true, clientX: 430 })
    fireEvent.pointerUp(svg, { pointerId: 7, button: 0, isPrimary: true, clientX: 770 })
    expect((screen.getByLabelText('Since (Unix seconds)') as HTMLInputElement).value).toBe('1250')
    expect((screen.getByLabelText('Until (Unix seconds)') as HTMLInputElement).value).toBe('1750')
    fireEvent.click(screen.getByRole('button', { name: 'Slice', exact: true }))
    await waitFor(() => expect(api.fetchLaneAddonSlice).toHaveBeenCalledWith(
      { run_id: '', lane_id: '', since: 1250, until: 1750 }, expect.any(AbortSignal)))
  })
  it('does not restore a cleared slice when its older request finishes', async () => {
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot(snapshot))
    let finish: ((result: unknown) => void) | undefined
    api.fetchLaneAddonSlice.mockImplementation(() => new Promise(resolve => { finish = resolve }))
    const screen = render(html`<${LaneAddonsPanel} />`)
    await screen.findByText('User supplied layer')
    fireEvent.click(screen.getByRole('button', { name: 'Slice', exact: true }))
    const signal = api.fetchLaneAddonSlice.mock.calls[0]?.[1] as AbortSignal
    fireEvent.click(screen.getByRole('button', { name: 'Clear slice' }))
    expect(signal.aborted).toBe(true)
    finish?.(parseLaneAddonSlice({ rows: [{ ...row, title: 'Late discarded result' }], coverage, complete: false }))
    await waitFor(() => expect(screen.queryByText('Late discarded result')).toBeNull())
    expect(screen.getByText('Same target, different observed revision')).toBeTruthy()
  })
  it('rejects unknown control states and malformed common rows instead of inventing defaults', () => {
    expect(() => parseLaneAddonSnapshot({ ...snapshot, instances: [{ ...snapshot.instances[0], phase: { kind: 'mystery' } }] })).toThrow()
    expect(() => parseLaneAddonSnapshot({ ...snapshot, rows: [{ ...row, observed_at: 'yesterday' }] })).toThrow()
    expect(() => parseLaneAddonSnapshot({ instances: [], rows: [], coverage: [] })).toThrow()
    expect(() => parseLaneAddonSnapshot({ ...snapshot, instances: [{ ...snapshot.instances[0], configuration: undefined }] })).toThrow()
    expect(() => parseLaneAddonSnapshot({ ...snapshot, instances: [{ ...snapshot.instances[0], incarnation: undefined }] })).toThrow()
    expect(() => parseLaneAddonSnapshot({ ...snapshot, instances: [{ ...snapshot.instances[0], action_schema: undefined }] })).toThrow()
  })
  it('submits an advertised package action with an exact binding while slice and other controls remain usable', async () => {
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot(actionSnapshot))
    api.fetchLaneAddonSlice.mockResolvedValue(parseLaneAddonSlice({ rows: [row], coverage, complete: false }))
    let accept: ((value: unknown) => void) | undefined
    api.requestLaneAddonAction.mockImplementation(() => new Promise(resolve => { accept = resolve }))
    const screen = render(html`<${LaneAddonsPanel} />`)
    const selector = await screen.findByLabelText('Action instance')
    expect(screen.queryByRole('button', { name: 'Send new request' })).toBeNull()
    fireEvent.change(selector, { target: { value: 'instance-1:incarnation-1' } })
    expect(screen.getByText('Advertised action schema')).toBeTruthy()
    fireEvent.input(screen.getByLabelText('Action JSON'), { target: { value: '{"operation":"publish"}' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send new request' }))
    await screen.findByText('Awaiting acceptance receipt')
    const request = api.requestLaneAddonAction.mock.calls[0]?.[0]
    expect(request).toEqual({ ...actionRequest, request_id: expect.any(String) })
    expect(request.request_id).toMatch(/^[0-9a-f-]{36}$/)
    expect((screen.getByRole('button', { name: 'Send new request' }) as HTMLButtonElement).disabled).toBe(true)
    expect((screen.getByRole('button', { name: 'Detach' }) as HTMLButtonElement).disabled).toBe(false)
    fireEvent.click(screen.getByRole('button', { name: 'Slice', exact: true }))
    await screen.findByText('Slice: partial')
    expect(api.fetchLaneAddonSlice).toHaveBeenCalledTimes(1)
    accept?.(parseLaneAddonActionReceipt({ ...actionReceipt, request_id: request.request_id }))
    await screen.findByText('Queued')
    expect((screen.getByRole('button', { name: 'Send new request' }) as HTMLButtonElement).disabled).toBe(false)
    expect(api.fetchLaneAddonAction).not.toHaveBeenCalled()
    expect(api.fetchLaneAddons).toHaveBeenCalledTimes(1)

    api.fetchLaneAddonAction.mockResolvedValueOnce(parseLaneAddonActionReceipt({ ...actionReceipt, request_id: request.request_id, state: 'running', executor: 'worker-7' }))
    fireEvent.click(screen.getByRole('button', { name: 'Check request status' }))
    await screen.findByText('Running')
    expect(api.fetchLaneAddonAction).toHaveBeenCalledWith(request, expect.any(AbortSignal))
    api.fetchLaneAddonAction.mockResolvedValueOnce(parseLaneAddonActionReceipt({ ...actionReceipt, request_id: request.request_id,
      state: 'confirmed', executor: 'worker-7', result: { accepted_operation: 'publish' } }))
    fireEvent.click(screen.getByRole('button', { name: 'Check request status' }))
    await screen.findByText('Package confirmed returned result')
    expect(screen.getByText(/Completion of the surrounding task requires separate evidence/)).toBeTruthy()
    expect(screen.getByLabelText('Package returned result').textContent).toContain('accepted_operation')
    expect(api.requestLaneAddonAction).toHaveBeenCalledTimes(1)
  })
  it('retains uncertain requests without replay and cancels a held status read independently of slice', async () => {
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot(actionSnapshot))
    api.requestLaneAddonAction.mockRejectedValue(new Error('connection closed before receipt'))
    api.fetchLaneAddonSlice.mockResolvedValue(parseLaneAddonSlice({ rows: [], coverage, complete: false }))
    const screen = render(html`<${LaneAddonsPanel} />`)
    fireEvent.change(await screen.findByLabelText('Action instance'), { target: { value: 'instance-1:incarnation-1' } })
    fireEvent.input(screen.getByLabelText('Action JSON'), { target: { value: '{"operation":"pause"}' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send new request' }))
    await screen.findByText('Current action status unavailable')
    const request = api.requestLaneAddonAction.mock.calls[0]?.[0]
    expect(screen.getByText(`Request ID: ${request.request_id}`)).toBeTruthy()
    expect(screen.getByRole('alert').textContent).toContain('The request may have been accepted')
    api.fetchLaneAddonAction.mockImplementation(() => new Promise(() => {}))
    fireEvent.click(screen.getByRole('button', { name: 'Check request status' }))
    await screen.findByRole('button', { name: 'Checking request status…' })
    fireEvent.click(screen.getByRole('button', { name: 'Slice', exact: true }))
    await screen.findByText('Slice: partial')
    const statusSignal = api.fetchLaneAddonAction.mock.calls[0]?.[1] as AbortSignal
    expect(statusSignal.aborted).toBe(false)
    expect(api.requestLaneAddonAction).toHaveBeenCalledTimes(1)
    expect(api.fetchLaneAddonAction).toHaveBeenCalledWith(request, expect.any(AbortSignal))
    screen.unmount()
    expect(statusSignal.aborted).toBe(true)
  })
  it.each([
    ['outcome_unknown', 'Outcome unknown'], ['failed_before_effect', 'Failed before effect'],
  ])('reports %s honestly without turning the receipt into successful completion', async (state, label) => {
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot(actionSnapshot))
    api.requestLaneAddonAction.mockImplementation(request => Promise.resolve(parseLaneAddonActionReceipt({ ...actionReceipt,
      request_id: request.request_id, state, detail: 'Worker reported its current evidence boundary' })))
    const screen = render(html`<${LaneAddonsPanel} />`)
    fireEvent.change(await screen.findByLabelText('Action instance'), { target: { value: 'instance-1:incarnation-1' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send new request' }))
    await screen.findByText(label)
    expect(screen.getByText('Worker reported its current evidence boundary')).toBeTruthy()
    expect(screen.queryByText('Package confirmed returned result')).toBeNull()
    expect(api.requestLaneAddonAction).toHaveBeenCalledTimes(1)
  })
  it('requires selection after incarnation replacement while preserving old receipts and giving new requests unique IDs', async () => {
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot(actionSnapshot))
    api.requestLaneAddonAction.mockImplementation(request => Promise.resolve(parseLaneAddonActionReceipt({ ...actionReceipt,
      request_id: request.request_id, incarnation: request.expected_incarnation })))
    const screen = render(html`<${LaneAddonsPanel} />`)
    fireEvent.change(await screen.findByLabelText('Action instance'), { target: { value: 'instance-1:incarnation-1' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send new request' }))
    await screen.findByText('Queued')
    const original = api.requestLaneAddonAction.mock.calls[0]?.[0]
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot({ ...actionSnapshot,
      instances: [{ ...actionSnapshot.instances[0], incarnation: 'incarnation-2' }] }))
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    await screen.findByText('The selected instance is no longer available for new actions. Select an active instance.')
    expect(screen.queryByRole('button', { name: 'Send new request' })).toBeNull()
    api.fetchLaneAddonAction.mockResolvedValue(parseLaneAddonActionReceipt({ ...actionReceipt, request_id: original.request_id, state: 'outcome_unknown' }))
    fireEvent.click(screen.getByRole('button', { name: 'Check request status' }))
    await screen.findByText('Outcome unknown')
    expect(api.fetchLaneAddonAction).toHaveBeenCalledWith(original, expect.any(AbortSignal))
    fireEvent.change(screen.getByLabelText('Action instance'), { target: { value: 'instance-1:incarnation-2' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send new request' }))
    await screen.findByText('Queued')
    const next = api.requestLaneAddonAction.mock.calls[1]?.[0]
    expect(next.expected_incarnation).toBe('incarnation-2')
    expect(next.request_id).not.toBe(original.request_id)
    expect(screen.getByText(`Request ID: ${original.request_id}`)).toBeTruthy()
    expect(screen.getByText(`Request ID: ${next.request_id}`)).toBeTruthy()
  })
  it('keeps last recorded status visible when a later receipt read fails', async () => {
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot(actionSnapshot))
    api.requestLaneAddonAction.mockImplementation(request => Promise.resolve(parseLaneAddonActionReceipt({ ...actionReceipt, request_id: request.request_id })))
    const screen = render(html`<${LaneAddonsPanel} />`)
    fireEvent.change(await screen.findByLabelText('Action instance'), { target: { value: 'instance-1:incarnation-1' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send new request' }))
    await screen.findByText('Queued')
    api.fetchLaneAddonAction.mockRejectedValue(new Error('receipt storage unavailable'))
    fireEvent.click(screen.getByRole('button', { name: 'Check request status' }))
    await screen.findByText('Current action status unavailable')
    expect(screen.getByText('Last recorded status: Queued')).toBeTruthy()
    expect(api.requestLaneAddonAction).toHaveBeenCalledTimes(1)
  })
  it('rejects non-object action input and hides new actions for detached instances', async () => {
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot(actionSnapshot))
    const screen = render(html`<${LaneAddonsPanel} />`)
    fireEvent.change(await screen.findByLabelText('Action instance'), { target: { value: 'instance-1:incarnation-1' } })
    fireEvent.input(screen.getByLabelText('Action JSON'), { target: { value: '[]' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send new request' }))
    await screen.findByText('Action must be a JSON object matching the advertised schema.')
    expect(api.requestLaneAddonAction).not.toHaveBeenCalled()
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot({ ...actionSnapshot,
      instances: [{ ...actionSnapshot.instances[0], phase: { kind: 'detached' } }] }))
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    await screen.findByText('The selected instance is no longer available for new actions. Select an active instance.')
    expect((screen.getByRole('button', { name: 'Send new request' }) as HTMLButtonElement).disabled).toBe(true)
    expect(api.requestLaneAddonAction).not.toHaveBeenCalled()
  })
  it('uses real action transport with exact request identity and rejects mismatched or malformed receipts', async () => {
    const actual = await vi.importActual<typeof import('../api/lane-addons')>('../api/lane-addons')
    transport.post.mockResolvedValue(actionReceipt)
    expect(await actual.requestLaneAddonAction(actionRequest)).toEqual(actionReceipt)
    expect(transport.post).toHaveBeenCalledWith('/api/v1/lane-addons/actions', actionRequest)
    const signal = new AbortController().signal
    transport.get.mockResolvedValue({ ...actionReceipt, state: 'running' })
    await actual.fetchLaneAddonAction(actionRequest, signal)
    expect(transport.get).toHaveBeenCalledWith('/api/v1/lane-addons/actions?instance_id=instance-1&request_id=request-1', { signal })
    for (const wrong of [{ incarnation: 'new-owner' }, { instance_id: 'different-target' }, { request_id: 'different-request' }]) {
      transport.get.mockResolvedValue({ ...actionReceipt, ...wrong })
      await expect(actual.fetchLaneAddonAction(actionRequest)).rejects.toThrow('does not match')
    }
    expect(() => parseLaneAddonActionReceipt({ ...actionReceipt, state: 'completed' })).toThrow()
    expect(() => parseLaneAddonActionReceipt({ ...actionReceipt, action: [] })).toThrow()
    expect(() => parseLaneAddonActionReceipt({ ...actionReceipt, result: 'success' })).toThrow()
  })
})
