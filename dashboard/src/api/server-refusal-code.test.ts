import { afterEach, describe, expect, it, vi } from 'vitest'
import { post } from './core'

// Regression for the server-refusal wiring gap found on main:
// lib/server/server_refusal.ml emits {"error": "<sentence>", "code": "<code>"}
// with `code` as a TOP-LEVEL field. The parser used to read `code` only when
// `error` was an object, so errorCode fell through to the error sentence and
// every `errorCode === '<code>'` branch in the UI was dead.
describe('server refusal bodies (top-level code)', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  const refuse = (body: string, status = 422) =>
    new Response(body, {
      status,
      statusText: 'Unprocessable Entity',
      headers: { 'Content-Type': 'application/json' },
    })

  it('keeps the top-level code from Server_refusal.json bodies', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(
        refuse(
          '{"error":"workspace snapshot is not the published head","code":"workspace_precondition_failed"}',
        ),
      ),
    )
    await expect(post('/api/v1/published-artifacts/x/sections', {})).rejects.toMatchObject({
      name: 'ApiRequestError',
      status: 422,
      errorCode: 'workspace_precondition_failed',
      detail: 'workspace snapshot is not the published head',
    })
  })

  it('still prefers auth_error_code over the refusal code', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(
        refuse('{"error":"actor mismatch","code":"actor_mismatch","auth_error_code":"token_revoked"}'),
      ),
    )
    await expect(post('/api/v1/published-artifacts/x/sections', {})).rejects.toMatchObject({
      errorCode: 'token_revoked',
    })
  })

  it('still prefers error_code when both top-level codes exist', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(
        refuse('{"error":"stale","code":"stale_code","error_code":"declared_error_code"}'),
      ),
    )
    await expect(post('/api/v1/published-artifacts/x/sections', {})).rejects.toMatchObject({
      errorCode: 'declared_error_code',
    })
  })

  it('keeps the sentence as errorCode when the refusal carries no code', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(refuse('{"error":"plain refusal without code"}', 400)),
    )
    await expect(post('/api/v1/published-artifacts/x/sections', {})).rejects.toMatchObject({
      status: 400,
      errorCode: 'plain refusal without code',
    })
  })
})
