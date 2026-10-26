import { html } from 'htm/preact'
import { cleanup, render, within } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import { parseLaneAddonSnapshot, type LaneAddonRow } from '../api/lane-addons'
import { BrowserLaneConnections } from './browser-lane-connections'

const work = { requestId: 'request-1', actor: 'keeper/research', action: 'page.native_workflow', tabId: 0, phase: 'running' }
const client = { clientId: 'b932c512-51e0-45bc-9fcb-3fde7bd2767b', browser: 'ego_lite',
  version: '0.6.1.11', engineVersion: 'chromium', transport: 'ego_task_space', space: { id: 32, name: 'Research' },
  interactions: [work, { ...work, requestId: 'request-2', actor: 'agent/helper', phase: 'queued', tabId: null }],
  lastActivities: [{ work: { ...work, requestId: 'previous', actor: 'operator' }, outcome: 'unknown' }] }
const instance = { instance_id: 'worker', run_id: 'run', addon_id: 'browser', title: 'Browser connections',
  revision: 'revision', runtime_presence: 'live', incarnation: 'original', action_schema: null,
  configuration: null, phase: { kind: 'attached' }, observation_seq: 1, rows_count: 1,
  package: { binding_schema: null, presentation: { description: null, readings: [] }, outputs: {} } }
const row: LaneAddonRow = { id: 'worker/1/browser', lane_id: 'worker/browser/connections', kind: 'value',
  title: 'Browser worker', observed_at: 1793037600, subject_id: 'browser', actor: null, clock: null,
  fields: { state: 'serving', clients: [client], owned_backends: {} }, evidence: [], related_ids: [] }
function show(fields = row.fields, runtime_presence = 'live') {
  const snapshot = parseLaneAddonSnapshot({ configuration: null, rows: [{ ...row, fields }],
    instances: [{ ...instance, runtime_presence }], coverage: [] })
  return render(html`<${BrowserLaneConnections} row=${snapshot.rows[0]} instances=${snapshot.instances} />`)
}
afterEach(cleanup)

describe('browser caller observations', () => {
  it('renders host caller, Space and request scopes even when the aggregate row actor is absent', () => {
    const view = show()
    const connection = within(view.getByLabelText(`Browser client ${client.clientId}`))
    expect(connection.getByText('Ego Lite · Ego TaskSpace')).toBeTruthy()
    expect(connection.getByText('Space 32 · Research')).toBeTruthy()
    expect(connection.getByText(/keeper\/research · page.native_workflow · Tab 0/)).toBeTruthy()
    expect(connection.getByText(/agent\/helper · page.native_workflow · Space scope/)).toBeTruthy()
    expect(connection.getByText(/Outcome unknown/)).toBeTruthy()
    expect(connection.getByText(/Request previous/)).toBeTruthy()
    expect(view.container.querySelector('button')).toBeNull()
  })
  it('keeps retained observations dated and never labels old running work as current control', () => {
    const view = show(row.fields, 'retained')
    expect(view.getByText(/2026-10-26T18:00:00.000Z/)).toBeTruthy()
    expect(view.getByText(/Retained worker observation/)).toBeTruthy()
    expect(view.getByText('Requests pending at observation')).toBeTruthy()
  })
  it('keeps callers and Spaces distinct across multiple browser connections', () => {
    const other = { ...client, clientId: 'other', space: { id: 0, name: '<img src=x onerror=alert(1)>' },
      interactions: [{ ...work, actor: '<b>keeper/other</b>' }], lastActivities: [] }
    const view = show({ ...row.fields, clients: [client, other] })
    const original = view.getByLabelText(`Browser client ${client.clientId}`)
    const second = view.getByLabelText('Browser client other')
    expect(original.textContent).not.toContain('keeper/other')
    expect(second.textContent).not.toContain('keeper/research')
    expect(second.textContent).toContain('Space 0 · <img src=x onerror=alert(1)>')
    expect(second.textContent).toContain('<b>keeper/other</b>')
    expect(second.querySelector('img,b')).toBeNull()
  })
  it('uses recorded phase/outcome and preserves absent caller without inventing Keeper identity', () => {
    const view = show({ ...row.fields, clients: [{ ...client, interactions: [{ ...work, actor: null }],
      lastActivities: ['returned', 'refused', 'partial', 'unknown'].map(outcome => ({
        work: { ...work, actor: null, requestId: outcome }, outcome,
      })) }] })
    expect(view.getAllByText(/Caller not recorded/)).toHaveLength(5)
    for (const label of ['Returned', 'Not performed', 'Partly performed', 'Outcome unknown']) {
      expect(view.getByText(new RegExp(`^${label} ·`))).toBeTruthy()
    }
    expect(view.container.textContent).not.toContain('keeper/research')
  })
  it('distinguishes empty connection/activity lists from unreadable data', () => {
    const view = show({ ...row.fields, clients: [{ ...client, interactions: [], lastActivities: [] },
      { ...client, clientId: 'firefox', browser: 'firefox', transport: 'webdriver_bidi', space: null,
        interactions: [], lastActivities: [] }] })
    expect(view.getAllByText('No pending requests recorded.')).toHaveLength(2)
    expect(view.getAllByText('No previous result recorded.')).toHaveLength(2)
    expect(view.getByText('Firefox · WebDriver BiDi')).toBeTruthy()
    view.unmount()
    expect(show({ ...row.fields, clients: [] }).getByText('No live connections recorded in this observation.')).toBeTruthy()
  })
  it.each([
    { ...client, space: null }, { ...client, space: { id: Number.MAX_SAFE_INTEGER + 1, name: 'unsafe' } },
    { ...client, transport: 'webdriver_bidi' }, { ...client, interactions: [{ ...work, phase: 'done' }] },
    { ...client, lastActivities: [{ work, outcome: 'success' }] },
    { ...client, interactions: [{ ...work, tabId: -1 }] },
  ])('refuses a malformed or inconsistent nested connection without hiding raw row data', malformed => {
    const view = show({ ...row.fields, clients: [malformed] })
    expect(view.getByRole('status').textContent).toContain('observation unreadable')
    expect(view.queryByText('No pending requests recorded.')).toBeNull()
  })
  it('refuses duplicate clients and respects retired state', () => {
    const view = show({ ...row.fields, clients: [client, client] })
    expect(view.getByRole('status')).toBeTruthy()
    view.unmount()
    expect(show({ ...row.fields, state: 'retired', clients: [] }).getByText('Worker state at observation: retired')).toBeTruthy()
  })
  it('does not infer a browser contract from title, category or another instance prefix', () => {
    const snapshot = parseLaneAddonSnapshot({ configuration: null, rows: [row], coverage: [],
      instances: [{ ...instance, addon_id: 'unrelated', package: { ...instance.package, ui_category: 'browser' } },
        { ...instance, instance_id: 'worker2' }] })
    const view = render(html`<${BrowserLaneConnections} row=${row} instances=${snapshot.instances} />`)
    expect(view.container.textContent).toBe('')
  })
})
