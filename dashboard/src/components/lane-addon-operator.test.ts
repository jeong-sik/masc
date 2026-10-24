import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { parseLaneAddonSnapshot } from '../api/lane-addons'
import { clearStoredToken, setStoredToken } from '../api/core'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'
import type { Signal } from '@preact/signals'

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
const done = { title: 'Account', message: 'Connected', actions: [] }
let popup: Window
beforeEach(() => {
  vi.resetAllMocks(); clearStoredToken()
  ;(executionWorkspaceAuthority as Signal<ExecutionWorkspaceAuthority | null>).value = authority
  popup = { location: { replace: vi.fn() }, close: vi.fn() } as unknown as Window
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
  expect(popup.close).toHaveBeenCalled()
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
