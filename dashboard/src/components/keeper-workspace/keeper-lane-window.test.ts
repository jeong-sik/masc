import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { DashboardKeeperWaitingInventory, DashboardKeeperWaitingRow } from '../../api'
import type { Keeper } from '../../types'
import { KeeperLaneStrip } from './keeper-lane-strip'
import type { LaneEventQueueActions } from './keeper-lane-event-actions'

function rows(name: string, count = 2000): DashboardKeeperWaitingRow[] {
  return Array.from({ length: count }, (_, index) => ({
    keeper_name: name, source: 'event_queue_pending', waiting_on: 'workspace_message',
    what: `${name}-event-${index}`, since: 1000 + index, next_action: 'keeper_drain_event_queue',
    detail: { source_ref: index.toString(16).padStart(64, '0'),
      source_incarnation: (9007199254740993n + BigInt(index)).toString() },
  }))
}
function inventory(entries: Array<[string, DashboardKeeperWaitingRow[]]>): DashboardKeeperWaitingInventory {
  return { keeper_count: entries.length, waiting_keeper_count: entries.length,
    row_count: entries.reduce((total, [, rows]) => total + rows.length, 0),
    keepers: entries.map(([keeper_name, waiting_on]) => ({ keeper_name, state: 'waiting', waiting_count: waiting_on.length, waiting_on })) }
}
function strip(name: string, data: DashboardKeeperWaitingInventory, actions: LaneEventQueueActions) {
  return html`<${KeeperLaneStrip} keeper=${{ name, agent_name: name } as Keeper} inventory=${data}
    ready=${true} loading=${false} error=${null} eventActions=${actions} />`
}
function actions(): LaneEventQueueActions {
  return { pendingKey: null, recoveries: [], error: null, operate: vi.fn(async () => undefined) }
}
function viewport(container: HTMLElement): HTMLElement {
  const result = container.querySelector<HTMLElement>('[aria-label="대기 나이순 작업 흐름"]')!
  Object.defineProperty(result, 'clientHeight', { configurable: true, value: 240 })
  return result
}
async function scroll(viewport: HTMLElement, index: number) {
  await act(async () => { viewport.scrollTop = index * 40; fireEvent.scroll(viewport) })
}
async function expand(element: HTMLDetailsElement) {
  await act(async () => { element.open = true; fireEvent(element, new Event('toggle')) })
}
afterEach(() => { cleanup(); vi.restoreAllMocks() })

describe('Keeper lane window', () => {
  it('windows a large inventory while preserving access and exact actions at the final server row', async () => {
    const all = rows('alpha'); const controls = actions()
    const view = render(strip('alpha', inventory([['alpha', all]]), controls))
    expect(view.container.querySelectorAll('[data-testid="keeper-lane-waiting-row"]').length).toBeLessThan(all.length)
    const list = viewport(view.container)
    await scroll(list, all.length - 1)
    await screen.findByText('alpha-event-1999', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' })
    expect(screen.queryByText('alpha-event-0', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' })).toBeNull()
    const detail = screen.getByText('alpha-event-1999', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' }).closest('details')!
    await expand(detail)
    fireEvent.click(within(detail).getByRole('button', { name: 'normal' }))
    expect(controls.operate).toHaveBeenCalledTimes(1)
    expect(controls.operate).toHaveBeenCalledWith(`event:${all[1999]!.detail!.source_ref}`, {
      action: 'reprioritize', sourceRef: all[1999]!.detail!.source_ref,
      sourceIncarnation: all[1999]!.detail!.source_incarnation, urgency: 'normal',
    })
  })
  it('retains expansion by exact identity across window removal, return and insertion', async () => {
    const all = rows('alpha'); const controls = actions()
    const view = render(strip('alpha', inventory([['alpha', all]]), controls))
    const detail = screen.getByText('alpha-event-0', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' }).closest('details')!
    await expand(detail)
    const list = viewport(view.container)
    await scroll(list, 1999)
    await screen.findByText('alpha-event-1999', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' })
    expect(screen.queryByText('alpha-event-0', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' })).toBeNull()
    await scroll(list, 0)
    await screen.findByText('alpha-event-0', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' })
    expect(screen.getByText('alpha-event-0', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' }).closest('details')!.open).toBe(true)
    const inserted = { ...all[0]!, what: 'inserted-observation', since: 1,
      detail: { source_ref: 'f'.repeat(64), source_incarnation: '42' } }
    view.rerender(strip('alpha', inventory([['alpha', [inserted, ...all]]]), controls))
    await waitFor(() => expect(screen.getByText('alpha-event-0', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' }).closest('details')!.open).toBe(true))
    expect(screen.getByText('inserted-observation', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' }).closest('details')!.open).toBe(false)
  })
  it('starts a different Keeper at the first row with fresh scroll and expansion state', async () => {
    const data = inventory([['alpha', rows('alpha')], ['beta', rows('beta')]])
    const controls = actions(); const view = render(strip('alpha', data, controls))
    await expand(screen.getByText('alpha-event-0', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' }).closest('details')!)
    const oldViewport = viewport(view.container)
    await scroll(oldViewport, 1999)
    await screen.findByText('alpha-event-1999', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' })
    view.rerender(strip('beta', data, controls))
    await screen.findByText('beta-event-0', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' })
    const current = viewport(view.container)
    expect(current).not.toBe(oldViewport)
    expect(current.scrollTop).toBe(0)
    expect(screen.getByText('beta-event-0', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' }).closest('details')!.open).toBe(false)
    expect(screen.queryByText('alpha-event-1999', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' })).toBeNull()
  })
  it('returns keyboard focus to the list when the focused row leaves its viewport', async () => {
    const view = render(strip('alpha', inventory([['alpha', rows('alpha')]]), actions()))
    const detail = screen.getByText('alpha-event-0', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' }).closest('details')!
    await expand(detail)
    const button = within(detail).getByRole('button', { name: 'normal' })
    button.focus(); expect(document.activeElement).toBe(button)
    const list = viewport(view.container)
    await scroll(list, 1999)
    await screen.findByText('alpha-event-1999', { selector: '[data-testid=\"keeper-lane-waiting-what\"]' })
    await waitFor(() => expect(document.activeElement).toBe(list))
  })
})
