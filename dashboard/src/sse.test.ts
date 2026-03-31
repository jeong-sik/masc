import { afterEach, describe, expect, it } from 'vitest'
import { buildDashboardSseUrl } from './sse'

describe('buildDashboardSseUrl', () => {
  afterEach(() => {
    sessionStorage.removeItem('masc_bearer_token')
  })

  it('omits stored auth tokens from the SSE URL', () => {
    sessionStorage.setItem('masc_bearer_token', 'secret')
    expect(
      buildDashboardSseUrl('dash_test', '?agent=keeper-a'),
    ).toBe('/mcp?agent=keeper-a&session_id=dash_test&sse_kind=observer')
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
