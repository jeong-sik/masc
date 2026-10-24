import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { parseLaneAddonSnapshot } from '../api/lane-addons'
import { clearStoredToken, setStoredToken } from '../api/core'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'
import type { Signal } from '@preact/signals'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { callbackPage } from './lane-addon-operator-callback.fixture'

const api = vi.hoisted(() => ({ readAddonOperator: vi.fn(), invokeAddonOperator: vi.fn() }))
vi.mock('../api/lane-addon-operator', () => api)
vi.mock('../store', async () => {
  const { signal } = await import('@preact/signals')
  return { executionWorkspaceAuthority: signal(null), shellAuthSummary: signal({ effective_role: 'admin' }) }
})
import { LaneAddonOperator } from './lane-addon-operator'
const authority: ExecutionWorkspaceAuthority = { epoch: 'fixture', workspaceRoot: '/fixture', connectionGeneration: 1 }
const instance = parseLaneAddonSnapshot({ configuration: null, rows: [], coverage: [], instances: [{
  instance_id: 'original', incarnation: 'original', run_id: 'fixture', addon_id: 'fixture', title: 'Account', revision: '1',
  runtime_presence: 'live', action_schema: null, configuration: null, phase: { kind: 'attached' }, observation_seq: 0, rows_count: 0,
  package: { outputs: {}, binding_schema: null, presentation: { description: null, readings: [] } },
}] }).instances[0]!
const connect = { id: 'connect', label: 'Connect fixture', arguments: {}, fields: [], opens_window: true }
const initial = { title: 'Account', message: 'Disconnected', actions: [connect] }
const pending = { title: 'Account', message: 'Approve', actions: [], open_url: 'https://provider.example/authorize',
  callback: { action: 'complete', field: 'callback_url', arguments: { state: 'fixture-state', connection_id: 'original-connection' }, state: 'fixture-state' } }
const done = { title: 'Account', message: 'Connected', actions: [],
  callback_receipt: { kind: 'captured', connection_id: 'original-connection' } }
let popup: Window
beforeEach(() => {
  vi.resetAllMocks(); clearStoredToken()
  ;(executionWorkspaceAuthority as Signal<ExecutionWorkspaceAuthority | null>).value = authority
  popup = { location: { replace: vi.fn() }, close: vi.fn(), postMessage: vi.fn() } as unknown as Window
  vi.spyOn(window, 'open').mockReturnValue(popup)
  api.readAddonOperator.mockResolvedValue(initial)
  api.invokeAddonOperator.mockResolvedValueOnce(pending).mockResolvedValue(done)
})
afterEach(() => { cleanup(); vi.restoreAllMocks() })
async function begin() {
  const screen = render(html`<${LaneAddonOperator} instance=${instance} authority=${authority} />`)
  await fireEvent.click(screen.getByRole('button', { name: 'Connection settings' }))
  await fireEvent.click(await screen.findByRole('button', { name: connect.label }))
  await waitFor(() => expect(popup.location.replace).toHaveBeenCalledWith(pending.open_url))
  return screen
}
function returned(url: string, origin = window.location.origin, source: Window = popup) {
  window.dispatchEvent(new MessageEvent('message', { origin, source,
    data: { kind: 'masc-addon-oauth-callback', url } }))
}
const callbackUrl = () => `${window.location.origin}/addons/oauth/callback?state=fixture-state&code=PRIVATE_CODE#integration_key=PRIVATE_KEY`

it('opens private app approval without synthesizing an opened acknowledgement', async () => {
  const approval = { id: 'login_approval', label: 'Open approval', arguments: { operation_id: 'original' }, fields: [], opens_window: true }
  const acknowledge = { id: 'login_opened', label: 'I opened 1Password', arguments: { operation_id: 'original' }, fields: [] }
  const app = { title: '1Password', message: 'Approve login', actions: [approval, acknowledge] }
  api.readAddonOperator.mockResolvedValue(app)
  api.invokeAddonOperator.mockReset().mockResolvedValue({ ...app, open_url: 'onepassword://grant-brokered-access?PRIVATE_LINK' })
  const screen = render(html`<${LaneAddonOperator} instance=${instance} authority=${authority} />`)
  await fireEvent.click(screen.getByRole('button', { name: 'Connection settings' }))
  await fireEvent.click(await screen.findByRole('button', { name: approval.label }))
  await waitFor(() => expect(popup.location.replace).toHaveBeenCalledWith('onepassword://grant-brokered-access?PRIVATE_LINK'))
  expect(api.invokeAddonOperator).toHaveBeenCalledTimes(1)
  await fireEvent.click(screen.getByRole('button', { name: acknowledge.label }))
  await waitFor(() => expect(api.invokeAddonOperator).toHaveBeenCalledTimes(2))
  expect(api.invokeAddonOperator).toHaveBeenLastCalledWith(
    { instance_id: 'original', expected_incarnation: 'original' }, 'login_opened', { operation_id: 'original' })
})

it('accepts only the original popup, origin, callback path and OAuth state', async () => {
  await begin()
  await act(() => {
    returned(callbackUrl(), 'https://attacker.example')
    returned(callbackUrl(), window.location.origin, {} as Window)
    returned(callbackUrl().replace('fixture-state', 'other-state'))
    returned(callbackUrl().replace('/addons/oauth/callback', '/different'))
  })
  expect(api.invokeAddonOperator).toHaveBeenCalledTimes(1)
  await act(() => returned(callbackUrl()))
  await waitFor(() => expect(api.invokeAddonOperator).toHaveBeenCalledTimes(2))
  expect(api.invokeAddonOperator).toHaveBeenLastCalledWith(
    { instance_id: 'original', expected_incarnation: 'original' }, 'complete',
    { ...pending.callback.arguments, callback_url: callbackUrl() },
  )
  await act(() => returned(callbackUrl()))
  expect(api.invokeAddonOperator).toHaveBeenCalledTimes(2)
})

it('clears private continuation when the dashboard credential changes', async () => {
  await begin()
  await act(() => setStoredToken('different-fixture-credential'))
  await act(() => returned(callbackUrl()))
  expect(api.invokeAddonOperator).toHaveBeenCalledTimes(1)
  expect(popup.close).not.toHaveBeenCalled()
  expect(popup.postMessage).not.toHaveBeenCalled()
})

it('does not apply a late connect response to a different workspace', async () => {
  let finish!: (value: typeof pending) => void
  api.invokeAddonOperator.mockReset().mockReturnValue(new Promise(resolve => { finish = resolve }))
  const screen = render(html`<${LaneAddonOperator} instance=${instance} authority=${authority} />`)
  await fireEvent.click(screen.getByRole('button', { name: 'Connection settings' }))
  await fireEvent.click(await screen.findByRole('button', { name: connect.label }))
  await act(() => { (executionWorkspaceAuthority as Signal<ExecutionWorkspaceAuthority | null>).value = {
    ...authority, workspaceRoot: '/other',
  } })
  await act(() => finish(pending))
  expect(popup.location.replace).not.toHaveBeenCalled()
  expect(popup.close).toHaveBeenCalled()
  expect(api.invokeAddonOperator).toHaveBeenCalledTimes(1)
})

it('preserves a valid callback arriving while Inspect is pending and dispatches it once', async () => {
  const screen = await begin()
  let finish!: (value: typeof pending) => void
  api.readAddonOperator.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
  await fireEvent.click(screen.getByRole('button', { name: 'Inspect connection' }))
  await act(() => returned(callbackUrl()))
  expect(api.invokeAddonOperator).toHaveBeenCalledTimes(1)
  await act(() => finish(pending))
  await waitFor(() => expect(api.invokeAddonOperator).toHaveBeenCalledTimes(2))
  expect(api.invokeAddonOperator).toHaveBeenLastCalledWith(
    { instance_id: 'original', expected_incarnation: 'original' }, 'complete',
    { ...pending.callback.arguments, callback_url: callbackUrl() },
  )
})

it('closes an opened popup immediately when unmounted before connect returns', async () => {
  let finish!: (value: typeof pending) => void
  api.invokeAddonOperator.mockReset().mockReturnValue(new Promise(resolve => { finish = resolve }))
  const screen = render(html`<${LaneAddonOperator} instance=${instance} authority=${authority} />`)
  await fireEvent.click(screen.getByRole('button', { name: 'Connection settings' }))
  await fireEvent.click(await screen.findByRole('button', { name: connect.label }))
  screen.unmount()
  expect(popup.close).toHaveBeenCalled()
  await act(() => finish(pending))
  expect(popup.location.replace).not.toHaveBeenCalled()
})

it('does not borrow a previous popup after a same-workspace connection generation changes', async () => {
  const screen = await begin()
  const replacement = { ...authority, connectionGeneration: 2 }
  await act(() => { (executionWorkspaceAuthority as Signal<ExecutionWorkspaceAuthority | null>).value = replacement })
  screen.rerender(html`<${LaneAddonOperator} instance=${instance} authority=${replacement} />`)
  await act(() => returned(callbackUrl()))
  expect(api.invokeAddonOperator).toHaveBeenCalledTimes(1)
})

it('retains the original callback after a transport failure and retries only that same return', async () => {
  const screen = await begin()
  api.invokeAddonOperator.mockRejectedValueOnce(new Error('PRIVATE_TRANSPORT_MARKER'))
  await act(() => returned(callbackUrl()))
  await screen.findByRole('button', { name: 'Retry original connection return' })
  expect(popup.close).not.toHaveBeenCalled()
  expect(popup.postMessage).toHaveBeenCalledExactlyOnceWith({ kind: 'masc-addon-oauth-pending',
    state: pending.callback.state, connection_id: pending.callback.arguments.connection_id }, window.location.origin)
  expect(screen.container.textContent).not.toContain('PRIVATE_TRANSPORT_MARKER')
  expect(screen.container.innerHTML).not.toContain('PRIVATE_KEY')
  await fireEvent.click(screen.getByRole('button', { name: 'Retry original connection return' }))
  await waitFor(() => expect(popup.postMessage).toHaveBeenLastCalledWith({ kind: 'masc-addon-oauth-captured',
    state: pending.callback.state, connection_id: pending.callback.arguments.connection_id,
    receipt_kind: 'captured' }, window.location.origin))
  expect(api.invokeAddonOperator).toHaveBeenLastCalledWith(
    { instance_id: 'original', expected_incarnation: 'original' }, 'complete',
    { ...pending.callback.arguments, callback_url: callbackUrl() })
})

it('does not acknowledge absent or another original connection receipt and never auto-retries', async () => {
  const screen = await begin()
  api.invokeAddonOperator.mockResolvedValueOnce({ ...done, callback_receipt: { kind: 'captured', connection_id: 'replacement' } })
  await act(() => returned(callbackUrl()))
  await screen.findByRole('button', { name: 'Retry original connection return' })
  expect(api.invokeAddonOperator).toHaveBeenCalledTimes(2)
  expect(popup.postMessage).toHaveBeenCalledTimes(1)
  expect(popup.close).not.toHaveBeenCalled()
  api.readAddonOperator.mockResolvedValue({ ...done, callback_receipt: undefined })
  await fireEvent.click(screen.getByRole('button', { name: 'Inspect connection' }))
  expect(api.invokeAddonOperator).toHaveBeenCalledTimes(2)
  expect(popup.postMessage).toHaveBeenCalledTimes(1)
})

it('does not dispatch a queued return into an Inspect replacement or acknowledge a late credential', async () => {
  const screen = await begin()
  let finish!: (value: typeof pending) => void
  api.readAddonOperator.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
  await fireEvent.click(screen.getByRole('button', { name: 'Inspect connection' }))
  await act(() => returned(callbackUrl()))
  await act(() => finish({ ...pending, callback: { ...pending.callback,
    state: 'replacement-state', arguments: { state: 'replacement-state', connection_id: 'replacement' } } }))
  expect(api.invokeAddonOperator).toHaveBeenCalledTimes(1)
  expect(popup.close).not.toHaveBeenCalled()
  await act(() => setStoredToken('replaced-credential'))
  await act(() => returned(callbackUrl()))
  expect(api.invokeAddonOperator).toHaveBeenCalledTimes(1)
  expect(popup.postMessage).toHaveBeenCalledTimes(1)
})

it('queues a return delivered during connect navigation and sends it once after the original response', async () => {
  popup.location.replace = vi.fn(() => returned(callbackUrl()))
  await begin()
  await waitFor(() => expect(api.invokeAddonOperator).toHaveBeenCalledTimes(2))
  expect(api.invokeAddonOperator).toHaveBeenLastCalledWith(
    { instance_id: 'original', expected_incarnation: 'original' }, 'complete',
    { ...pending.callback.arguments, callback_url: callbackUrl() })
})

it('does not acknowledge a late capture after the original component is unmounted', async () => {
  const screen = await begin()
  let finish!: (value: typeof done) => void
  api.invokeAddonOperator.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
  await act(() => returned(callbackUrl()))
  await waitFor(() => expect(api.invokeAddonOperator).toHaveBeenCalledTimes(2))
  expect(popup.postMessage).toHaveBeenCalledTimes(1)
  screen.unmount()
  await act(() => finish(done))
  expect(popup.postMessage).toHaveBeenCalledTimes(1)
  expect(popup.close).not.toHaveBeenCalled()
})

it('connects actual backend capture receipts to the component and literal callback page before clearing', async () => {
  const packet = JSON.parse(readFileSync(resolve(process.cwd(), '../docs/evidence/2026-10-25-onepassword-callback-capture/backend-receipts.json'), 'utf8'))
  // This fixture is configured with the same HTTPS origin as its actual
  // backend. The transport port replays actual, source-bound Python replies.
  const previousUrl = window.location.href
  const browserFixture = (window as unknown as { happyDOM: { setURL: (url: string) => void } }).happyDOM
  browserFixture.setURL('https://masc.example')
  expect(window.location.origin).toBe('https://masc.example')
  api.invokeAddonOperator.mockReset().mockResolvedValueOnce(packet.pending)
    .mockResolvedValueOnce(packet.not_captured).mockResolvedValueOnce(packet.replayed)
  const screen = render(html`<${LaneAddonOperator} instance=${instance} authority=${authority} />`)
  await fireEvent.click(screen.getByRole('button', { name: 'Connection settings' }))
  await fireEvent.click(await screen.findByRole('button', { name: connect.label }))
  await waitFor(() => expect(popup.location.replace).toHaveBeenCalledWith(packet.pending.open_url))
  let child!: ReturnType<typeof callbackPage>
  popup.postMessage = vi.fn((data, origin) => queueMicrotask(() => child.receive(data, window, origin)))
  vi.spyOn(window, 'postMessage').mockImplementation((data, target) => {
    const origin = typeof target === 'string' ? target : target?.targetOrigin ?? ''
    window.dispatchEvent(new MessageEvent('message', { data, origin, source: popup }))
  })
  await act(() => { child = callbackPage(packet.callback_url, window) })
  await screen.findByRole('button', { name: 'Retry original connection return' })
  expect(child.page.close).not.toHaveBeenCalled()
  expect(child.page.history.replaceState).not.toHaveBeenCalled()
  expect(api.invokeAddonOperator).toHaveBeenCalledTimes(2)
  await act(() => child.retry())
  await waitFor(() => expect(child.page.close).toHaveBeenCalledTimes(1))
  expect(child.page.history.replaceState).toHaveBeenCalledExactlyOnceWith(null, '', '/addons/oauth/callback')
  expect(api.invokeAddonOperator).toHaveBeenLastCalledWith(
    { instance_id: 'original', expected_incarnation: 'original' }, 'complete',
    { ...packet.pending.callback.arguments, callback_url: packet.callback_url })
  expect(screen.container.innerHTML).not.toContain('FIXTURE_KEY')
  browserFixture.setURL(previousUrl)
})

it('keeps the manual Finish connection return through failure and clears it only for its own receipt', async () => {
  const packet = JSON.parse(readFileSync(resolve(process.cwd(), '../docs/evidence/2026-10-25-onepassword-callback-capture/backend-receipts.json'), 'utf8'))
  const previousUrl = window.location.href
  const browserFixture = (window as unknown as { happyDOM: { setURL: (url: string) => void } }).happyDOM
  browserFixture.setURL('https://masc.example')
  api.readAddonOperator.mockResolvedValue(packet.pending)
  api.invokeAddonOperator.mockReset().mockRejectedValueOnce(new Error('PRIVATE_MANUAL_FAILURE'))
    .mockResolvedValueOnce({ ...packet.captured, callback_receipt: { kind: 'captured', connection_id: 'replacement' } })
    .mockResolvedValueOnce(packet.replayed)
  const screen = render(html`<${LaneAddonOperator} instance=${instance} authority=${authority} />`)
  await fireEvent.click(screen.getByRole('button', { name: 'Connection settings' }))
  const input = await screen.findByLabelText('Returned connection URL') as HTMLInputElement
  await fireEvent.input(input, { target: { value: packet.callback_url } })
  await fireEvent.click(screen.getByRole('button', { name: 'Finish connection' }))
  await screen.findByRole('button', { name: 'Retry original connection return' })
  expect(input.value).toBe(packet.callback_url)
  expect(screen.container.textContent).not.toContain('PRIVATE_MANUAL_FAILURE')
  await fireEvent.click(screen.getByRole('button', { name: 'Retry original connection return' }))
  await waitFor(() => expect(api.invokeAddonOperator).toHaveBeenCalledTimes(2))
  expect(screen.queryByRole('button', { name: 'Retry original connection return' })).not.toBeNull()
  await fireEvent.click(screen.getByRole('button', { name: 'Retry original connection return' }))
  await waitFor(() => expect(screen.queryByRole('button', { name: 'Retry original connection return' })).toBeNull())
  for (const call of api.invokeAddonOperator.mock.calls) expect(call).toEqual([
    { instance_id: 'original', expected_incarnation: 'original' }, 'complete',
    { ...packet.pending.callback.arguments, callback_url: packet.callback_url }])
  expect(popup.postMessage).not.toHaveBeenCalled()
  expect(popup.close).not.toHaveBeenCalled()
  expect(screen.queryByLabelText('Returned connection URL')).toBeNull()
  browserFixture.setURL(previousUrl)
})

it.each(['closed', 'cleared-lost'] as const)('allows the next operator window after capture when the original page is %s', async mode => {
  const screen = await begin()
  let finish!: (value: unknown) => void
  api.invokeAddonOperator.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
  await act(() => returned(callbackUrl()))
  popup.postMessage = mode === 'closed' ? vi.fn(() => { throw new Error('PRIVATE_CLOSED_POPUP') }) : vi.fn()
  const approval = { id: 'login_approval', label: 'Open original approval',
    arguments: { operation_id: 'original' }, fields: [], opens_window: true }
  await act(() => finish({ ...done, actions: [approval] }))
  expect(popup.close).not.toHaveBeenCalled()
  expect(screen.container.textContent).not.toContain('PRIVATE_CLOSED_POPUP')
  const next = { location: { replace: vi.fn() }, close: vi.fn(), postMessage: vi.fn() } as unknown as Window
  vi.mocked(window.open).mockReturnValueOnce(next)
  api.invokeAddonOperator.mockResolvedValueOnce({ ...done, actions: [approval], open_url: 'onepassword://grant-brokered-access?PRIVATE_LINK' })
  await fireEvent.click(await screen.findByRole('button', { name: approval.label }))
  await waitFor(() => expect(next.location.replace).toHaveBeenCalledWith('onepassword://grant-brokered-access?PRIVATE_LINK'))
  expect(api.invokeAddonOperator).toHaveBeenLastCalledWith(
    { instance_id: 'original', expected_incarnation: 'original' }, 'login_approval', { operation_id: 'original' })
  expect(popup.close).not.toHaveBeenCalled()
})

it('does not auto-dispatch a queued return after exact cancel removes its pending authorization', async () => {
  const cancel = { id: 'cancel', label: 'Cancel original attempt', arguments: pending.callback.arguments, fields: [] }
  api.invokeAddonOperator.mockReset().mockResolvedValueOnce({ ...pending, actions: [cancel] })
  const screen = await begin()
  let finish!: (value: typeof initial) => void
  api.invokeAddonOperator.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
  await fireEvent.click(screen.getByRole('button', { name: cancel.label }))
  await act(() => returned(callbackUrl()))
  expect(api.invokeAddonOperator).toHaveBeenCalledTimes(2)
  await act(() => finish(initial))
  expect(api.invokeAddonOperator).toHaveBeenCalledTimes(2)
  expect(popup.postMessage).toHaveBeenCalledTimes(1)
  expect(popup.close).not.toHaveBeenCalled()
  expect(screen.queryByRole('button', { name: 'Retry original connection return' })).not.toBeNull()
})
