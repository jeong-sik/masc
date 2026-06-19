import { afterEach, describe, expect, it, vi } from 'vitest'

describe('sanitizeHtml fallback', () => {
  afterEach(() => {
    vi.doUnmock('dompurify')
    vi.resetModules()
  })

  it('degrades to escaped plaintext when DOMPurify is unsupported', async () => {
    vi.resetModules()
    vi.doMock('dompurify', () => ({
      __esModule: true,
      default: () => ({
        isSupported: false,
        sanitize: (value: string) => value,
      }),
    }))

    const { sanitizeHtml } = await import('./dompurify')
    const clean = sanitizeHtml('<img src=x onerror=alert(1)><b>ok</b>')

    expect(clean).toContain('&lt;img')
    expect(clean).toContain('&lt;b&gt;ok&lt;/b&gt;')
    expect(clean).not.toContain('<img')
    expect(clean).not.toContain('<b>')
  })
})
