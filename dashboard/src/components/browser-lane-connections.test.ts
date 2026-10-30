import { html } from 'htm/preact'
import { cleanup, render, within } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import { parseLaneAddonSnapshot, type LaneAddonRow } from '../api/lane-addons'
import { BrowserLaneConnections } from './browser-lane-connections'

const work = { requestId: 'request-1', actor: 'keeper/research', action: 'page.native_workflow', tabId: 0, phase: 'running' }
const client = { clientId: 'b932c512-51e0-45bc-9fcb-3fde7bd2767b', browser: 'ego_lite',
  version: '0.6.1.11', engineVersion: 'chromium', transport: 'ego_task_space', space: { id: 32, name: 'Research' }, spaceObservation: null,
  interactions: [work, { ...work, requestId: 'request-2', actor: 'agent/helper', phase: 'queued', tabId: null }],
  lastActivities: [{ work: { ...work, requestId: 'previous', actor: 'operator' }, outcome: 'unknown' }] }
const unavailable = { backend: 'ego', reason: 'user_owned_name', space: 'Research', observedAt: 42, recheck: 'worker_restart' }
const instance = { instance_id: 'worker', run_id: 'run', addon_id: 'browser', title: 'Browser connections',
  revision: 'revision', runtime_presence: 'live', incarnation: 'original', action_schema: null,
  configuration: null, phase: { kind: 'attached' }, observation_seq: 1, rows_count: 1,
  package: { binding_schema: null, presentation: { description: null, readings: [] }, outputs: {} } }
const row: LaneAddonRow = { id: 'worker/1/browser', lane_id: 'worker/browser/connections', kind: 'value',
  title: 'Browser worker', observed_at: 1793037600, subject_id: 'browser', actor: null, clock: null,
  fields: { state: 'serving', clients: [client], owned_backends: { automation: { activity: 'disabled', registered: false, session: 'closed', locate: false },
        stagehand: { activity: 'unobserved', registered: false, session: 'unknown', locate: false } } }, evidence: [], related_ids: [] }
function show(fields = row.fields, runtime_presence = 'live') {
  const snapshot = parseLaneAddonSnapshot({ configuration: null, rows: [{ ...row, fields }],
    instances: [{ ...instance, runtime_presence }], coverage: [] })
  return render(html`<${BrowserLaneConnections} row=${snapshot.rows[0]} instances=${snapshot.instances} />`)
}
afterEach(cleanup)

describe('browser caller observations', () => {
  it('shows owned browser sessions beside personal browser callers without inventing login or caller identity', () => {
    const view = show({ ...row.fields, owned_backends: {
      automation: { activity: 'enabled', registered: true, session: 'open', locate: true },
      stagehand: { activity: 'enabled', registered: true, session: 'changing', locate: false },
    } }, 'retained')
    const automation = view.getByLabelText('Automation browser session')
    const stagehand = view.getByLabelText('Stagehand browser session')
    expect(automation.textContent).toContain('Browser session at observation: open')
    expect(stagehand.textContent).toContain('Browser session at observation: changing')
    expect(automation.textContent).toContain('Executor registered: yes')
    expect(automation.textContent).not.toContain('keeper/research')
    expect(view.getByLabelText(`Browser client ${client.clientId}`)).toBeTruthy()
    expect(view.getByText(/do not identify a current caller or verify login/)).toBeTruthy()
    expect(view.getByText(/Retained worker observation/)).toBeTruthy()
    expect(view.container.querySelector('button')).toBeNull()
  })
  it('preserves unknown and closed session states independently of registration', () => {
    const view = show({ ...row.fields, clients: [], owned_backends: {
      automation: { activity: 'enabled', registered: true, session: 'closed', locate: false },
      stagehand: { activity: 'unobserved', registered: false, session: 'unknown', locate: false },
    } })
    expect(view.getByLabelText('Automation browser session').textContent).toContain('Browser session at observation: closed')
    expect(view.getByLabelText('Stagehand browser session').textContent).toContain('Browser session at observation: unknown')
    expect(view.getByLabelText('Stagehand browser session').textContent).toContain('Availability at observation: unobserved')
  })
  it.each([
    null, {}, { automation: {} },
    { automation: { activity: 'enabled', registered: true, session: 'ready', locate: true },
      stagehand: { activity: 'disabled', registered: false, session: 'closed', locate: false } },
    { automation: { activity: 'enabled', registered: 'yes', session: 'open', locate: true },
      stagehand: { activity: 'disabled', registered: false, session: 'closed', locate: false } },
    { automation: { activity: 'enabled', registered: true, session: 'open', locate: true, caller: 'fake' },
      stagehand: { activity: 'disabled', registered: false, session: 'closed', locate: false } },
  ])('refuses malformed owned browser observations', owned_backends => {
    expect(show({ ...row.fields, owned_backends }).getByRole('status').textContent).toContain('observation unreadable')
  })

  it('preserves healthy clients alongside a dated Ego connection refusal', () => {
    const firefox = { ...client, clientId: 'firefox', browser: 'firefox', transport: 'webdriver_bidi',
      space: null, interactions: [], lastActivities: [] }
    const view = show({ ...row.fields, clients: [firefox], unavailable: [unavailable] }, 'retained')
    expect(view.getByLabelText('Browser client firefox')).toBeTruthy()
    expect(view.getByText('Firefox · WebDriver BiDi')).toBeTruthy()
    expect(view.queryByText(/observation unreadable/)).toBeNull()
    const refusal = view.getByLabelText('Ego connection unavailable')
    expect(refusal.textContent).toContain('Research')
    expect(refusal.textContent).toContain('1970-01-01T00:00:42.000Z')
    expect(refusal.textContent).toContain('user-owned Space')
    expect(refusal.textContent).toContain('worker restart')
    expect(view.queryByText(/Last SDK control observation/)).toBeNull()
    expect(view.container.querySelector('button')).toBeNull()
  })
  it('shows an unavailable Ego connection without inventing a client or caller', () => {
    const view = show({ ...row.fields, clients: [], unavailable: [{ ...unavailable, space: '<b>Research</b>' }] })
    expect(view.getByText('No live connections recorded in this observation.')).toBeTruthy()
    expect(view.getByLabelText('Ego connection unavailable').textContent).toContain('<b>Research</b>')
    expect(view.container.querySelector('b')).toBeNull()
    expect(view.queryByText(/keeper\/research/)).toBeNull()
    view.unmount()
    expect(show({ ...row.fields, unavailable: [] }).getByLabelText(`Browser client ${client.clientId}`)).toBeTruthy()
  })
  it.each([
    null, {}, [null], [{ ...unavailable, backend: 'other' }], [{ ...unavailable, reason: 'other' }],
    [{ ...unavailable, space: '' }], [{ ...unavailable, observedAt: -1 }],
    [{ ...unavailable, observedAt: Infinity }], [{ ...unavailable, observedAt: Number.NaN }],
    [{ ...unavailable, observedAt: '42' }], [{ ...unavailable, recheck: 'automatic' }],
    [{ ...unavailable, authority: 'agent' }], [{ backend: 'ego', reason: 'user_owned_name', space: 'Research' }],
  ])('keeps malformed unavailable records unreadable', invalid => {
    expect(show({ ...row.fields, unavailable: invalid }).getByRole('status').textContent).toContain('observation unreadable')
  })
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
  it('shows opaque native control with its own observation time, without inferring login or authority', () => {
    const spaceObservation = { spaceId: 32, spaceName: 'Renamed research', ownership: 'agentDelegatedToUser', observedAt: 42 }
    const view = show({ ...row.fields, clients: [{ ...client, spaceObservation }] })
    expect(view.getByText(/Last SDK control observation: agentDelegatedToUser/).textContent).toContain('1970-01-01T00:00:42.000Z')
    expect(view.getByText(/Last SDK control observation/).textContent).toContain('Space 32 · Renamed research')
    expect(view.getByText(/does not verify current control, window visibility or login/)).toBeTruthy()
    expect(view.container.querySelector('button')).toBeNull()
    view.unmount()
    const future = show({ ...row.fields, clients: [{ ...client,
      spaceObservation: { ...spaceObservation, ownership: '<b>future-native-owner</b>' } }] }, 'retained')
    expect(future.getByText(/Last SDK control observation/).textContent).toContain('<b>future-native-owner</b>')
    expect(future.container.querySelector('b')).toBeNull()
    expect(future.getByText(/Retained worker observation/)).toBeTruthy()
  })
  it('keeps a missing native observation unknown and does not infer it from a pending Keeper request', () => {
    const view = show()
    expect(view.getByText(/No SDK control observation recorded/)).toBeTruthy()
    expect(view.queryByText(/Last SDK control observation/)).toBeNull()
    expect(view.getByText(/keeper\/research · page.native_workflow · Tab 0/)).toBeTruthy()
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
    ...[
      { spaceId: 33, spaceName: 'foreign', ownership: 'agent', observedAt: 42 },
      { spaceId: 32, spaceName: 'same', ownership: ' ', observedAt: 42 },
      { spaceId: 32, spaceName: 'same', ownership: 'agent', observedAt: Number.NaN },
      { spaceId: 32, spaceName: 'same', ownership: 'agent', observedAt: Infinity },
      { spaceId: 32, spaceName: 'same', ownership: 'agent', observedAt: 42, claim: true },
    ].map(spaceObservation => ({ ...client, spaceObservation })),
    { ...client, transport: 'webdriver_bidi', browser: 'firefox', space: null,
      spaceObservation: { spaceId: 32, spaceName: 'same', ownership: 'agent', observedAt: 42 } },
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
