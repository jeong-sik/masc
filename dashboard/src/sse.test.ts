import { afterEach, describe, expect, it } from 'vitest'
import { buildDashboardSseUrl } from './sse'

describe('buildDashboardSseUrl', () => {
  afterEach(() => {
    sessionStorage.removeItem('masc_bearer_token')
  })

  it('uses /mcp observer stream with dashboard query params', () => {
    sessionStorage.setItem('masc_bearer_token', 'secret')
    expect(
      buildDashboardSseUrl(
        'dash_test',
        '?agent=keeper-a',
      ),
    ).toBe('/mcp?agent=keeper-a&token=secret&session_id=dash_test&sse_kind=observer')
  })

  it('omits token when sessionStorage has no bearer token', () => {
    expect(
      buildDashboardSseUrl('dash_test', '?agent=keeper-a'),
    ).toBe('/mcp?agent=keeper-a&session_id=dash_test&sse_kind=observer')
  })

  it('omits optional params when they are absent', () => {
    expect(buildDashboardSseUrl('dash_test', '')).toBe(
      '/mcp?session_id=dash_test&sse_kind=observer',
    )
  })
})
