import { html } from 'htm/preact'
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { parseLaneAddonSnapshot, parseLaneAddonSlice } from '../api/lane-addons'

const api = vi.hoisted(() => ({
  fetchLaneAddons: vi.fn(), fetchLaneAddonSlice: vi.fn(), attachLaneAddon: vi.fn(),
  observeLaneAddon: vi.fn(), detachLaneAddon: vi.fn(), preserveLaneAddonEvidence: vi.fn(),
}))
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
  instances: [{ instance_id: 'instance-1', run_id: 'run-2', addon_id: 'unregistered-package',
    title: 'User supplied layer', revision: 'digest-1', phase: { kind: 'observing' },
    observation_seq: 1, rows_count: 1 }], rows: [row], coverage,
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
    expect(api.preserveLaneAddonEvidence).not.toHaveBeenCalled()
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
    api.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot({ instances: [], rows: [], coverage: [] }))
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
  })
})
