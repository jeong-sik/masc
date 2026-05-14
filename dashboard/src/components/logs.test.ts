import { h } from 'preact'
import { cleanup, render, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'

async function loadLogs(fetchLogs: ReturnType<typeof vi.fn>) {
  vi.resetModules()
  vi.doMock('../api/dashboard.js', () => ({
    fetchLogs,
  }))
  return import('./logs')
}

describe('LogViewer Code links', () => {
  afterEach(() => {
    cleanup()
    vi.clearAllMocks()
    vi.resetModules()
    vi.doUnmock('../api/dashboard.js')
    window.location.hash = ''
  })

  it('links safe structured log file details back to the Code IDE route', async () => {
    const fetchLogs = vi.fn().mockResolvedValue({
      total: 1,
      entries: [{
        seq: 1,
        ts: '2026-05-14T00:00:00Z',
        level: 'INFO',
        raw_level: 'INFO',
        normalized_level: 'INFO',
        source: 'structured',
        legacy_classified: false,
        module: 'keeper_tool',
        message: 'read file',
        details: { file_path: 'lib/runtime.ml', line: 12 },
      }],
    })
    const { LogViewer } = await loadLogs(fetchLogs)
    const { container } = render(h(LogViewer, {}))

    await waitFor(() => expect(container.querySelector('[data-testid="logs-code-link"]')).not.toBeNull())
    const codeLink = container.querySelector('[data-testid="logs-code-link"]') as HTMLButtonElement
    expect(codeLink.textContent).toBe('Code')
    expect(codeLink.getAttribute('title')).toBe('Code lib/runtime.ml:12')

    codeLink.click()
    expect(window.location.hash).toBe('#code?section=ide-shell&view=source&file=lib%2Fruntime.ml&line=12&surface=Log&label=keeper_tool&source_id=log%3A1')
  })

  it('does not render Code links for unsafe absolute log file paths', async () => {
    const fetchLogs = vi.fn().mockResolvedValue({
      total: 1,
      entries: [{
        seq: 2,
        ts: '2026-05-14T00:00:00Z',
        level: 'INFO',
        raw_level: 'INFO',
        normalized_level: 'INFO',
        source: 'structured',
        legacy_classified: false,
        module: 'keeper_tool',
        message: 'read file',
        details: { file_path: '/tmp/runtime.ml', line: 12 },
      }],
    })
    const { LogViewer } = await loadLogs(fetchLogs)
    const { container } = render(h(LogViewer, {}))

    await waitFor(() => expect(container.textContent).toContain('read file'))
    expect(container.querySelector('[data-testid="logs-code-link"]')).toBeNull()
  })
})
