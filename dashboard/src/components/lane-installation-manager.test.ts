// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, within } from '@testing-library/preact'
import '@testing-library/jest-dom'
import { h } from 'preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { LaneAddonInstance, LaneAddonSnapshot } from '../api/lane-addons'
import type { LaneDeclaration } from '../lib/lane-installation-status'
import { LaneInstallationManager } from './lane-installation-manager'

afterEach(cleanup)

function declaration(id: string, overrides: Partial<LaneDeclaration> = {}): LaneDeclaration {
  return {
    id, source_path: `/config/lanes/${id}.toml`, enabled: true,
    desired_revision: `desired-${id}`, applied_revision: `desired-${id}`,
    source_revision: `file-${id}`, instance_id: `worker-${id}`,
    application: { kind: 'applied', instance_id: `worker-${id}` }, ...overrides,
  }
}

function worker(declaration: LaneDeclaration, overrides: Partial<LaneAddonInstance> = {}): LaneAddonInstance {
  return {
    instance_id: declaration.instance_id!, run_id: `run-${declaration.id}`, addon_id: 'example-addon',
    title: `Browser ${declaration.id}`, revision: 'package-v1', incarnation: `epoch-${declaration.id}`,
    action_schema: null, runtime_presence: 'live',
    package: { outputs: {}, binding_schema: null, presentation: { description: null, readings: [] } },
    configuration: { id: declaration.id, source_path: declaration.source_path,
      revision: declaration.applied_revision! },
    phase: { kind: 'attached' }, observation_seq: 3, rows_count: 2, ...overrides,
  }
}

function snapshot(declarations: readonly LaneDeclaration[], instances: readonly LaneAddonInstance[],
  overrides: Partial<NonNullable<LaneAddonSnapshot['configuration']>> = {}): LaneAddonSnapshot {
  return { configuration: { directory: '/config/lanes', complete: true,
    issues: [], declarations, ...overrides }, instances, rows: [], coverage: [] }
}

function mount(value: LaneAddonSnapshot, editable = true) {
  const callbacks = { onEdit: vi.fn(), onActivity: vi.fn(), onObserve: vi.fn() }
  const props = { snapshot: value, editable, readState: 'settled' as const, ...callbacks }
  const view = render(h(LaneInstallationManager, props))
  return { ...view, ...callbacks,
    update: (next: LaneAddonSnapshot) => view.rerender(h(LaneInstallationManager, { ...props, snapshot: next })) }
}

function installation(id: string) {
  return screen.getByRole('row', { name: `Installation ${id}` })
}

function observeButton(row: HTMLElement) {
  return within(row).getByRole('button', { name: /^Observe installation / })
}

function visibleIds(): string[] {
  return screen.getAllByRole('row').filter(row => row.hasAttribute('aria-label'))
    .map(row => row.getAttribute('aria-label')!)
}

describe('LaneInstallationManager', () => {
  it('routes observation, TOML editing and activity to the exact installation identity', () => {
    const first = declaration('first')
    const second = declaration('second', { source_path: '/config/custom/second.toml' })
    // Inventory order and a retained worker must not choose the action target.
    const view = mount(snapshot([first, second], [
      worker(second, { runtime_presence: 'retained', instance_id: 'old-second' }),
      worker(second), worker(first),
    ]))
    const row = installation('second')
    expect(within(row).getByText('Worker attached')).toBeInTheDocument()
    fireEvent.click(observeButton(row))
    fireEvent.click(within(row).getByRole('button', { name: `Edit TOML ${second.source_path}` }))
    fireEvent.click(within(row).getByRole('button', { name: 'Configure activity for second' }))
    expect(view.onObserve).toHaveBeenCalledExactlyOnceWith('worker-second')
    expect(view.onEdit).toHaveBeenCalledExactlyOnceWith('/config/custom/second.toml')
    expect(view.onActivity).toHaveBeenCalledExactlyOnceWith(second)
    expect(view.onActivity.mock.calls[0]![0]).toBe(second)
  })

  it('blocks observation when any live worker ownership coordinate is absent or mismatched', () => {
    const declared = declaration('owned')
    const current = worker(declared)
    const inventories: readonly LaneAddonInstance[][] = [
      [], [worker(declared, { runtime_presence: 'retained' })],
      [worker(declared, { runtime_presence: undefined })],
      [worker(declared, { instance_id: 'foreign-worker' })],
      [worker(declared, { configuration: null })],
      [worker(declared, { configuration: { ...current.configuration!, id: 'another-id' } })],
      [worker(declared, { configuration: { ...current.configuration!, source_path: '/config/renamed.toml' } })],
      [worker(declared, { configuration: { ...current.configuration!, revision: 'old-revision' } })],
      [current, worker(declared)],
    ]
    const view = mount(snapshot([declared], []))
    for (const inventory of inventories) {
      view.update(snapshot([declared], inventory))
      const row = installation('owned')
      expect(within(row).queryByText('Worker attached')).toBeNull()
      expect(observeButton(row)).toBeDisabled()
      fireEvent.click(observeButton(row))
    }
    const differentApplication = { ...declared, application: { kind: 'applied' as const, instance_id: 'foreign-worker' } }
    view.update(snapshot([differentApplication], [current]))
    expect(observeButton(installation('owned'))).toBeDisabled()
    expect(view.onObserve).not.toHaveBeenCalled()
  })

  it('does not attach a renamed file or ambiguous duplicate declarations to the old worker', () => {
    const original = declaration('same-id')
    const renamed = { ...original, source_path: '/config/lanes/renamed.toml' }
    const view = mount(snapshot([renamed], [worker(original)]))
    expect(observeButton(installation('same-id'))).toBeDisabled()
    expect(within(installation('same-id')).queryByText('Worker attached')).toBeNull()
    view.update(snapshot([original, renamed], [worker(original), worker(renamed)]))
    for (const row of screen.getAllByRole('row', { name: 'Installation same-id' })) {
      expect(within(row).getByText(/ambiguous/i)).toBeInTheDocument()
      expect(observeButton(row)).toBeDisabled()
      fireEvent.click(observeButton(row))
    }
    const samePath = declaration('other-id', { source_path: original.source_path })
    view.update(snapshot([original, samePath], [worker(original), worker(samePath)]))
    expect(observeButton(installation('same-id'))).toBeDisabled()
    expect(observeButton(installation('other-id'))).toBeDisabled()
    expect(view.onObserve).not.toHaveBeenCalled()
  })

  it('keeps cleanup failure and unknown or incomplete readings from appearing applied or off', () => {
    const disabled = declaration('cleanup', { enabled: false, instance_id: null,
      application: { kind: 'failed', messages: ['Native cleanup could not finish'] } })
    const enabled = declaration('uncertain')
    const view = mount(snapshot([disabled], [worker(declaration('cleanup'), { runtime_presence: 'retained' })]))
    expect(within(installation('cleanup')).getByText('Native cleanup could not finish')).toBeInTheDocument()
    expect(within(installation('cleanup')).queryByText(/^Configured off/)).toBeNull()
    expect(observeButton(installation('cleanup'))).toBeDisabled()
    for (const reading of [
      snapshot([{ ...enabled, application: { kind: 'failed', messages: ['Apply failed'] } }], [worker(enabled)]),
      snapshot([{ ...enabled, application: { kind: 'unknown', messages: ['State read failed'] } }], [worker(enabled)]),
      snapshot([enabled], [worker(enabled)], { complete: false }),
    ]) {
      view.update(reading)
      const row = installation('uncertain')
      expect(observeButton(row)).toBeDisabled()
      expect(within(row).queryByText('Worker attached')).toBeNull()
      expect(within(row).queryByText('Desired revision applied')).toBeNull()
      fireEvent.click(observeButton(row))
    }
    expect(view.onObserve).not.toHaveBeenCalled()
  })

  it('uses server inactive, starting and cleaning states for off and pending filters', () => {
    const off = declaration('off', { enabled: false, instance_id: null, application: { kind: 'inactive' } })
    const starting = declaration('starting', { applied_revision: null, instance_id: null,
      application: { kind: 'starting' } })
    const cleaning = declaration('cleaning', { enabled: false, application: { kind: 'cleaning' } })
    const view = mount(snapshot([off, starting, cleaning], [worker(cleaning)]))
    expect(within(installation('off')).getByText('Configured off', { exact: true })).toBeInTheDocument()
    expect(within(installation('starting')).getByText('Waiting for first application')).toBeInTheDocument()
    expect(within(installation('cleaning')).getAllByText('Worker cleanup pending')).toHaveLength(2)
    fireEvent.click(screen.getByRole('button', { name: /^Configured off:/ }))
    expect(visibleIds()).toEqual(['Installation off'])
    fireEvent.click(screen.getByRole('button', { name: /^Pending changes:/ }))
    expect(visibleIds()).toEqual(['Installation starting', 'Installation cleaning'])
    expect(view.onActivity).not.toHaveBeenCalled()
    expect(view.onObserve).not.toHaveBeenCalled()
  })

  it('shows configuration problems matched by path, declaration ID or global directory', () => {
    const owned = declaration('issue-owner')
    const view = mount(snapshot([owned], [worker(owned)], { issues: [
      { source_path: owned.source_path, id: null, message: 'Path issue' },
      { source_path: '/other/location.toml', id: owned.id, message: 'ID issue' },
      { source_path: '/config/lanes', id: null, message: 'Directory issue' },
      { source_path: '/unrelated.toml', id: 'foreign', message: 'Unrelated issue' },
    ] }))
    const row = installation('issue-owner')
    for (const message of ['Path issue', 'ID issue', 'Directory issue']) {
      expect(within(row).getByText(message)).toBeInTheDocument()
    }
    expect(within(row).queryByText('Unrelated issue')).toBeNull()
    expect(observeButton(row)).toBeDisabled()
    fireEvent.click(observeButton(row))
    expect(view.onObserve).not.toHaveBeenCalled()
  })

  it('searches package, run and path within status filters without performing any action', () => {
    const alpha = declaration('alpha', { source_path: '/config/special/alpha.toml' })
    const beta = declaration('beta', { application: { kind: 'unknown', messages: ['Read failed'] } })
    const view = mount(snapshot([alpha, beta], [worker(alpha), worker(beta)]))
    fireEvent.input(screen.getByRole('searchbox'), { target: { value: 'EXAMPLE-ADDON run-alpha special' } })
    expect(visibleIds()).toEqual(['Installation alpha'])
    fireEvent.click(screen.getByRole('button', { name: /^Needs attention:/ }))
    expect(visibleIds()).toEqual([])
    fireEvent.input(screen.getByRole('searchbox'), { target: { value: '' } })
    expect(visibleIds()).toEqual(['Installation beta'])
    fireEvent.click(screen.getByRole('button', { name: /^Worker available:/ }))
    expect(visibleIds()).toEqual(['Installation alpha'])
    expect(view.onEdit).not.toHaveBeenCalled()
    expect(view.onActivity).not.toHaveBeenCalled()
    expect(view.onObserve).not.toHaveBeenCalled()
    fireEvent.click(observeButton(installation('alpha')))
    expect(view.onObserve).toHaveBeenCalledExactlyOnceWith('worker-alpha')
  })

  it('disables TOML and activity changes for a readonly operator while retaining valid observation', () => {
    const owned = declaration('readonly')
    const view = mount(snapshot([owned], [worker(owned)]), false)
    const row = installation('readonly')
    for (const name of [`Edit TOML ${owned.source_path}`, 'Configure activity for readonly']) {
      const button = within(row).getByRole('button', { name })
      expect(button).toBeDisabled()
      fireEvent.click(button)
    }
    expect(view.onEdit).not.toHaveBeenCalled()
    expect(view.onActivity).not.toHaveBeenCalled()
    expect(observeButton(row)).toBeEnabled()
    fireEvent.click(observeButton(row))
    expect(view.onObserve).toHaveBeenCalledExactlyOnceWith('worker-readonly')
  })

  it('retains the previous reading while preventing observation during a pending or failed refresh', () => {
    const owned = declaration('refresh')
    const props = { snapshot: snapshot([owned], [worker(owned)]), editable: true,
      onEdit: vi.fn(), onActivity: vi.fn(), onObserve: vi.fn() }
    const view = render(h(LaneInstallationManager, { ...props, readState: 'settled' }))
    for (const readState of ['pending', 'failed'] as const) {
      view.rerender(h(LaneInstallationManager, { ...props, readState }))
      expect(installation('refresh')).toBeInTheDocument()
      expect(observeButton(installation('refresh'))).toBeDisabled()
      fireEvent.click(observeButton(installation('refresh')))
      expect(props.onObserve).not.toHaveBeenCalled()
    }
    view.rerender(h(LaneInstallationManager, { ...props, readState: 'settled' }))
    fireEvent.click(observeButton(installation('refresh')))
    expect(props.onObserve).toHaveBeenCalledExactlyOnceWith('worker-refresh')
  })
})
