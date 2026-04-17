import { afterEach, describe, expect, it, vi } from 'vitest'
import { buildErrorPayload, reportDashboardError } from './error-reporter'

describe('reportDashboardError', () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('always calls console.error with a tagged prefix', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const err = new Error('kaboom')
    reportDashboardError(err, { componentStack: 'at <Foo>' })

    expect(spy).toHaveBeenCalledTimes(1)
    const call = spy.mock.calls[0]
    if (!call) throw new Error('console.error not called')
    expect(call[0]).toBe('[dashboard-error]')
    expect(call[1]).toBe(err)
    expect(call[2]).toEqual({ componentStack: 'at <Foo>' })
  })

  it('does not throw when console.error throws', () => {
    vi.spyOn(console, 'error').mockImplementation(() => {
      throw new Error('console exploded')
    })
    expect(() =>
      reportDashboardError(new Error('x'), { componentStack: 's' }),
    ).not.toThrow()
  })

  it('accepts a missing info argument', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    expect(() => reportDashboardError(new Error('noinfo'))).not.toThrow()
    expect(spy).toHaveBeenCalled()
  })
})

describe('buildErrorPayload', () => {
  it('includes stack when present', () => {
    const err = new Error('with-stack')
    // Node auto-populates err.stack.
    expect(err.stack).toBeTruthy()
    const payload = buildErrorPayload(err, { componentStack: 'cs' })
    expect(payload.message).toBe('with-stack')
    expect(payload.component_stack).toBe('cs')
    expect(payload.stack).toBe(err.stack)
    expect(typeof payload.ts).toBe('string')
  })

  it('omits stack when error has no stack', () => {
    const err = new Error('no-stack')
    // Force-remove the stack to simulate engines that omit it.
    Object.defineProperty(err, 'stack', { value: undefined, configurable: true })
    const payload = buildErrorPayload(err)
    expect('stack' in payload).toBe(false)
    expect(payload.message).toBe('no-stack')
  })

  it('sets url and user_agent in a browser-like env (happy-dom)', () => {
    const payload = buildErrorPayload(new Error('env'))
    // happy-dom provides window.location and navigator.
    expect(typeof payload.url).toBe('string')
    expect(typeof payload.user_agent).toBe('string')
  })
})
