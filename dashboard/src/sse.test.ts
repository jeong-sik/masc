import { describe, expect, it } from 'vitest'
import { buildDashboardSseUrl } from './sse'

describe('buildDashboardSseUrl', () => {
  it('includes agent but excludes token from SSE URL', () => {
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

  it('never leaks token into URL even when present', () => {
    const url = buildDashboardSseUrl('s1', '?token=my-secret-token')
    expect(url).not.toContain('token')
    expect(url).not.toContain('my-secret-token')
  })
})
