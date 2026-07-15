import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h, render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { IdeMemoryPanel } from './ide-memory-panel'

describe('IdeMemoryPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    vi.stubGlobal('fetch', vi.fn(async () =>
      new Response(JSON.stringify({
        entries: [{
          id: 'mem-1',
          kind: 'Comment',
          content: 'remember this',
          file_path: 'lib/runtime.ml',
          line_start: 12,
          line_end: 12,
          keeper_id: 'sangsu',
          created_at_ms: Date.now(),
          source_kind: 'ide_annotation',
          retrieval_status: 'annotation_index_only',

          task_id: null,
        }],
        total: 1,
        limit: 50,
        contract: {
          source_kind: 'ide_annotation',
          retrieval_status: 'annotation_index_only',
          semantic_memory_status: 'not_configured',
          episodic_memory_status: 'not_configured',
        },
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))
  })

  afterEach(() => {
    render(null, container)
    vi.unstubAllGlobals()
  })

  it('renders v2 IDE marker classes for the panel, rows, and action button', async () => {
    render(h(IdeMemoryPanel, { keeperName: 'sangsu', repoId: 'masc' }), container)

    await waitFor(() => {
      expect(container.querySelector('.ide-memory-panel.v2-ide-panel')).not.toBeNull()
      expect(container.querySelector('.ide-memory-panel__entry.v2-ide-row')).not.toBeNull()
    })
    expect(container.querySelector('.ide-memory-panel__refresh.v2-ide-action')).not.toBeNull()
    expect(container.textContent).toContain('source:annotation')
    expect(container.textContent).toContain('semantic:not configured')
    expect(container.textContent).toContain('retrieval:annotation index')
  })

  it('includes keeper and repository scope when fetching memory', async () => {
    render(h(IdeMemoryPanel, { keeperName: 'sangsu', repoId: 'masc' }), container)

    await waitFor(() => {
      expect(globalThis.fetch).toHaveBeenCalled()
    })
    const [url] = vi.mocked(globalThis.fetch).mock.calls[0]!
    expect(String(url)).toContain('/api/v1/ide/memory?')
    expect(String(url)).toContain('keeper_id=sangsu')
    expect(String(url)).toContain('repo_id=masc')
    expect(String(url)).toContain('limit=50')
  })

  it('includes canonical URL scope without repo_id when fetching memory', async () => {
    render(h(IdeMemoryPanel, {
      keeperName: 'sangsu',
      scope: {
        kind: 'canonical_url',
        canonicalUrl: 'https://github.com/jeong-sik/masc.git',
      },
    }), container)

    await waitFor(() => {
      expect(globalThis.fetch).toHaveBeenCalled()
    })
    const [url] = vi.mocked(globalThis.fetch).mock.calls[0]!
    expect(String(url)).toContain('/api/v1/ide/memory?')
    expect(String(url)).toContain('keeper_id=sangsu')
    expect(String(url)).toContain('canonical_url=https%3A%2F%2Fgithub.com%2Fjeong-sik%2Fmasc.git')
    expect(String(url)).not.toContain('repo_id=')
  })

  it('renders an explicit no-repo-selected state and never calls the API without a scope', async () => {
    render(h(IdeMemoryPanel, { keeperName: 'sangsu' }), container)

    await waitFor(() => {
      const notice = container.querySelector('[data-testid="ide-memory-panel-no-scope"]')
      expect(notice?.textContent).toBe('저장소를 선택하면 메모리를 조회합니다')
    })
    expect(globalThis.fetch).not.toHaveBeenCalled()
    expect(container.querySelector('.ide-memory-panel__error')).toBeNull()
  })

  it('shows the typed API error message instead of a bare status code', async () => {
    vi.stubGlobal('fetch', vi.fn(async () =>
      new Response(JSON.stringify({ error: 'repo_index_unavailable', message: 'Repository index is rebuilding' }), {
        status: 503,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    render(h(IdeMemoryPanel, { keeperName: 'sangsu', repoId: 'masc' }), container)

    await waitFor(() => {
      const errorNode = container.querySelector('[data-testid="ide-memory-panel-error"]')
      expect(errorNode?.textContent).toContain('Repository index is rebuilding')
    })
    expect(container.querySelector('[data-testid="ide-memory-panel-error"]')?.textContent).not.toBe('HTTP 503')
  })
})
