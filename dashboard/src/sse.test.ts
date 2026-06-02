import { afterEach, describe, expect, it } from 'vitest'
import { buildDashboardSseUrl, normalizeSSEDispatchType } from './sse'
import { clearStoredToken, setStoredToken } from './api/core'

describe('buildDashboardSseUrl', () => {
  afterEach(() => {
    clearStoredToken()
  })

  it('includes token from sessionStorage and agent from query params', () => {
    setStoredToken('secret')
    expect(
      buildDashboardSseUrl('dash_test', '?agent=keeper-a'),
    ).toBe('/mcp?agent=keeper-a&token=secret&session_id=dash_test&sse_kind=observer')
  })

  it('omits blank raw stored tokens through the shared auth reader', () => {
    sessionStorage.setItem('masc_bearer_token', '   ')

    expect(buildDashboardSseUrl('dash_test', '?agent=keeper-a')).toBe(
      '/mcp?agent=keeper-a&session_id=dash_test&sse_kind=observer',
    )
  })

  it('omits token when sessionStorage is empty', () => {
    expect(buildDashboardSseUrl('dash_test', '?agent=keeper-a')).toBe(
      '/mcp?agent=keeper-a&session_id=dash_test&sse_kind=observer',
    )
  })

  it('omits optional params when they are absent', () => {
    expect(buildDashboardSseUrl('dash_test', '')).toBe(
      '/mcp?session_id=dash_test&sse_kind=observer',
    )
  })
})

describe('normalizeSSEDispatchType', () => {
  it('routes Event_bus audit events to the audit handler', () => {
    expect(normalizeSSEDispatchType('oas:masc:audit_event')).toBe('audit_event')
  })

  it('keeps board slash events on their explicit cases', () => {
    expect(normalizeSSEDispatchType('masc/board_post')).toBe('masc/board_post')
  })

  it('strips legacy masc slash prefix for core events', () => {
    expect(normalizeSSEDispatchType('masc/keeper_turn_complete')).toBe('keeper_turn_complete')
  })
})
