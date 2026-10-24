import { beforeEach, describe, expect, it, vi } from 'vitest'
import { invokeAddonOperator, readAddonOperator } from './lane-addon-operator'
import { postControlPlane } from './core'
vi.mock('./core', () => ({ postControlPlane: vi.fn() }))
const post = vi.mocked(postControlPlane)
const owner = { instance_id: 'original', expected_incarnation: 'original' }
const view = { title: 'Account', message: 'Ready', actions: [] }
beforeEach(() => vi.resetAllMocks())
describe('private Add-on operator transport', () => {
  it('does not invoke an absent private capability', async () => {
    post.mockResolvedValue({ schema: null })
    expect(await readAddonOperator(owner)).toBeNull()
    expect(post).toHaveBeenCalledExactlyOnceWith('/api/v1/lane-addons/operator', { ...owner, mode: 'describe' })
  })
  it('pins discovery and the private view to the same original incarnation', async () => {
    post.mockResolvedValueOnce({ schema: { type: 'object' } }).mockResolvedValueOnce(view)
    expect(await readAddonOperator(owner)).toEqual(view)
    expect(post).toHaveBeenLastCalledWith('/api/v1/lane-addons/operator', {
      ...owner, mode: 'invoke', arguments: { action: 'view', arguments: {} },
    })
  })
  it('never retries an uncertain callback and erases transport exception text', async () => {
    post.mockRejectedValue(new Error('PRIVATE_TOKEN_MARKER'))
    await expect(invokeAddonOperator(owner, 'complete', { callback_url: 'PRIVATE_CALLBACK_MARKER' }))
      .rejects.toThrow('Private operation outcome unavailable.')
    expect(post).toHaveBeenCalledTimes(1)
  })
  it('refuses unsafe navigation without exposing its contents', async () => {
    post.mockResolvedValue({ ...view, open_url: 'javascript:PRIVATE_MARKER' })
    const failure = await invokeAddonOperator(owner, 'connect', {}).catch(error => error)
    expect(failure).toBeInstanceOf(Error)
    expect(String(failure)).not.toContain('PRIVATE_MARKER')
    expect(post).toHaveBeenCalledTimes(1)
  })
  it('allows the exact private 1Password approval destination', async () => {
    const approval = { ...view, open_url: 'onepassword://grant-brokered-access?PRIVATE_MARKER' }
    post.mockResolvedValue(approval)
    expect(await invokeAddonOperator(owner, 'login_approval', { operation_id: 'original' })).toEqual(approval)
  })
  it('preserves only typed original capture receipts and refuses malformed receipts', async () => {
    const receipt = { kind: 'captured', connection_id: 'original-connection' }
    post.mockResolvedValue({ ...view, callback_receipt: receipt })
    expect((await invokeAddonOperator(owner, 'complete', {})).callback_receipt).toEqual(receipt)
    for (const callback_receipt of [null, {}, { kind: 'connected', connection_id: 'original-connection' },
      { kind: 'captured', connection_id: '' }, { kind: 'captured', connection_id: 1 }]) {
      post.mockResolvedValue({ ...view, callback_receipt })
      await expect(invokeAddonOperator(owner, 'complete', {})).rejects.toThrow('Private operation outcome unavailable.')
    }
  })
  it('refuses other app authorities, credentials, paths and fragments', async () => {
    for (const open_url of ['onepassword://other?PRIVATE_MARKER', 'onepassword://grant-brokered-access/other',
      'onepassword://user@grant-brokered-access', 'onepassword://grant-brokered-access#PRIVATE_MARKER',
      'onepassword://grant-brokered-access:123', 'file:///PRIVATE_MARKER', 'data:text/html,PRIVATE_MARKER']) {
      post.mockResolvedValue({ ...view, open_url })
      const failure = await invokeAddonOperator(owner, 'login_approval', {}).catch(error => error)
      expect(failure).toBeInstanceOf(Error)
      expect(String(failure)).not.toContain('PRIVATE_MARKER')
    }
  })
})
