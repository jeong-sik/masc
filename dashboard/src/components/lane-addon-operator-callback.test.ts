import { expect, it, vi } from 'vitest'
import { callbackPage } from './lane-addon-operator-callback.fixture'

const returned = 'https://masc.example/addons/oauth/callback?state=original-state&code=PRIVATE_CODE#integration_key=PRIVATE_KEY'
const pending = { kind: 'masc-addon-oauth-pending', state: 'original-state', connection_id: 'original-connection' }
const captured = { ...pending, kind: 'masc-addon-oauth-captured', receipt_kind: 'captured' }

it('keeps the original URL/window until the original opener acknowledges the same pending identity', () => {
  const opener = { postMessage: vi.fn() }
  const child = callbackPage(returned, opener)
  expect(child.page.history.replaceState).not.toHaveBeenCalled()
  expect(child.page.close).not.toHaveBeenCalled()
  expect(opener.postMessage).toHaveBeenCalledExactlyOnceWith({ kind: 'masc-addon-oauth-callback', url: returned }, 'https://masc.example')
  child.retry()
  expect(opener.postMessage).toHaveBeenCalledTimes(2)
  child.receive(captured)
  child.receive(pending, {}, 'https://masc.example')
  child.receive(pending, opener, 'https://attacker.example')
  child.receive({ ...pending, state: 'other-state' })
  child.receive(pending)
  child.receive({ ...captured, connection_id: 'replacement' })
  child.receive({ ...captured, receipt_kind: 'declined' })
  expect(child.page.history.replaceState).not.toHaveBeenCalled()
  expect(child.page.close).not.toHaveBeenCalled()
  child.receive(captured)
  expect(child.page.history.replaceState).toHaveBeenCalledExactlyOnceWith(null, '', '/addons/oauth/callback')
  expect(child.page.close).toHaveBeenCalledTimes(1)
  expect(opener.postMessage).toHaveBeenLastCalledWith({ kind: 'masc-addon-oauth-cleared', url: returned,
    connection_id: 'original-connection' }, 'https://masc.example')
  child.receive(captured)
  child.retry()
  expect(child.page.close).toHaveBeenCalledTimes(1)
  expect(child.status.textContent).not.toContain('PRIVATE_')
})

it('retains a key when the original opener is unavailable and rejects a replacement opener', () => {
  const child = callbackPage(returned, null)
  child.page.opener = { postMessage: vi.fn() }
  child.receive(pending, child.page.opener)
  child.receive(captured, child.page.opener)
  child.retry()
  expect(child.page.close).not.toHaveBeenCalled()
  expect(child.page.history.replaceState).not.toHaveBeenCalled()
  expect(child.page.opener.postMessage).not.toHaveBeenCalled()
})
