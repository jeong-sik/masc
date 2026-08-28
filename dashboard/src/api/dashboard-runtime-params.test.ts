import { afterEach, describe, expect, it, vi } from 'vitest'

const getMock = vi.hoisted(() => vi.fn())
const postMock = vi.hoisted(() => vi.fn())

vi.mock('./core', () => ({
  ApiRequestError: class ApiRequestError extends Error {},
  get: getMock,
  post: postMock,
}))

import { clearRuntimeParam, setRuntimeParam } from './dashboard-runtime'

// The server admits these bodies with Server_runtime_param_request, whose
// field is `param_key` (Missing_param_key otherwise). The panel test mocks
// this whole module, so only this file pins the actual request body — the
// original bug shipped `{ key }` and every save 400ed with no test red.
describe('runtime param request bodies', () => {
  afterEach(() => {
    getMock.mockReset()
    postMock.mockReset()
  })

  it('setRuntimeParam sends param_key and value', async () => {
    postMock.mockResolvedValue({})
    await setRuntimeParam('keeper.hitl.thinking_blocks', 3)
    expect(postMock).toHaveBeenCalledWith('/api/v1/runtime/params/set', {
      param_key: 'keeper.hitl.thinking_blocks',
      value: 3,
    })
  })

  it('clearRuntimeParam sends param_key', async () => {
    postMock.mockResolvedValue({})
    await clearRuntimeParam('keeper.hitl.thinking_blocks')
    expect(postMock).toHaveBeenCalledWith('/api/v1/runtime/params/clear', {
      param_key: 'keeper.hitl.thinking_blocks',
    })
  })
})
