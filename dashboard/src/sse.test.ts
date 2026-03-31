import { describe, expect, it } from 'vitest'
import { buildDashboardSseUrl } from './sse'

describe('buildDashboardSseUrl', () => {
  it('uses /mcp observer stream with dashboard query params', () => {
    // Since #4272, token is read from sessionStorage not URL params.
    // URL ?token=secret is ignored by buildDashboardSseUrl.
    expect(
      buildDashboardSseUrl(
        'dash_test',
        '?agent=keeper-a&token=secret',
      ),
    ).toBe('/mcp?agent=keeper-a&session_id=dash_test&sse_kind=observer')
  })

  it('omits optional params when they are absent', () => {
    expect(buildDashboardSseUrl('dash_test', '')).toBe(
      '/mcp?session_id=dash_test&sse_kind=observer',
    )
  })
})
