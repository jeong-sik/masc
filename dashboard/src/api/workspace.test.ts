import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  fetchWorkspaceTree,
  fetchWorkspaceFile,
  fetchGitBlame,
  fetchGitDiff,
} from './workspace'

afterEach(() => {
  mockFetch.mockClear()
  vi.unstubAllGlobals()
})

const mockFetch = vi.fn()

function stubFetch(
  response: unknown,
  ok = true,
  headers: Record<string, string> = {},
  status = ok ? 200 : 500,
): void {
  mockFetch.mockResolvedValue({
    ok,
    status,
    statusText: ok ? 'OK' : status === 404 ? 'Not Found' : 'Internal Server Error',
    headers: new Headers(headers),
    json: () => Promise.resolve(response),
    text: () => Promise.resolve(JSON.stringify(response)),
    clone() { return this },
  } as Response)
  vi.stubGlobal('fetch', mockFetch)
}

describe('workspace API', () => {
  it('fetchWorkspaceTree returns file nodes and project source by default', async () => {
    const nodes = [{ path: 'lib/main.ml', label: 'main.ml', depth: 1, parent: 'lib', hasChildren: false, diff: null, keeperId: null, hueIndex: null }]
    stubFetch(nodes)

    const result = await fetchWorkspaceTree(2)
    expect(result.nodes).toHaveLength(1)
    expect(result.nodes[0]!.path).toBe('lib/main.ml')
    expect(result.source).toEqual({ kind: 'project' })

    expect(mockFetch.mock.calls[0]![0]).toContain('/api/v1/workspace/tree?depth=2')
  })

  it('fetchWorkspaceTree appends keeper param when provided', async () => {
    stubFetch([])

    await fetchWorkspaceTree(1, { keeper: 'sangsu' })
    expect(mockFetch.mock.calls[0]![0]).toContain('keeper=sangsu')
  })

  it('fetchWorkspaceTree appends repo_id param when provided', async () => {
    stubFetch([], true, { 'X-Workspace-Source': 'repository:masc' })

    const result = await fetchWorkspaceTree(1, { repoId: 'masc' })
    expect(mockFetch.mock.calls[0]![0]).toContain('repo_id=masc')
    expect(result.source).toEqual({ kind: 'repository', repoId: 'masc' })
  })

  it('fetchWorkspaceTree can request changed-file diff badges', async () => {
    stubFetch([])

    await fetchWorkspaceTree(2, { includeDiff: true })
    expect(mockFetch.mock.calls[0]![0]).toContain('diff=true')
  })

  it('fetchWorkspaceTree decodes X-Workspace-Source playground header', async () => {
    stubFetch([], true, { 'X-Workspace-Source': 'playground:alpha' })

    const result = await fetchWorkspaceTree(1, { keeper: 'alpha' })
    expect(result.source).toEqual({ kind: 'playground', keeper: 'alpha' })
  })

  it('fetchWorkspaceTree decodes X-Workspace-Source fallback variants', async () => {
    stubFetch([], true, { 'X-Workspace-Source': 'playground_missing:beta' })
    expect((await fetchWorkspaceTree(1, { keeper: 'beta' })).source)
      .toEqual({ kind: 'playground_missing', keeper: 'beta' })

    stubFetch([], true, { 'X-Workspace-Source': 'keeper_unknown:ghost' })
    expect((await fetchWorkspaceTree(1, { keeper: 'ghost' })).source)
      .toEqual({ kind: 'keeper_unknown', keeper: 'ghost' })
  })

  it('fetchWorkspaceFile returns file content', async () => {
    stubFetch({ ok: true, content: 'let x = 1\n', language: 'ocaml' })

    const result = await fetchWorkspaceFile('lib/main.ml')
    expect(result).toEqual({ ok: true, content: 'let x = 1\n', language: 'ocaml' })

    expect(mockFetch.mock.calls[0]![0]).toContain('/api/v1/workspace/file?path=')
    expect(mockFetch.mock.calls[0]![0]).toContain('lib%2Fmain.ml')
  })

  it('fetchWorkspaceFile appends repo_id param when provided', async () => {
    stubFetch({ ok: true, content: 'let x = 1\n', language: 'ocaml' })

    await fetchWorkspaceFile('lib/main.ml', { repoId: 'oas' })
    expect(mockFetch.mock.calls[0]![0]).toContain('repo_id=oas')
  })

  it('fetchWorkspaceFile projects the route HTTP 404 as typed not-found', async () => {
    stubFetch({ ok: false, error: 'File not found' }, false, {}, 404)

    await expect(fetchWorkspaceFile('missing.ml')).resolves.toEqual({ ok: false })
  })

  it('fetchWorkspaceFile preserves non-404 API failures', async () => {
    stubFetch({ ok: false, error: 'Failed to read file' }, false, {}, 500)

    await expect(fetchWorkspaceFile('broken.ml')).rejects.toMatchObject({ status: 500 })
  })

  it('fetchGitBlame returns blame blocks', async () => {
    const blocks = [{ file_path: 'a.ml', line_start: 1, line_end: 5, keeper_id: 'claude', timestamp_ms: 1000, kind: 'edit' }]
    stubFetch(blocks)

    const result = await fetchGitBlame('a.ml')
    expect(result).toHaveLength(1)
    expect(result[0]!.keeper_id).toBe('claude')
  })

  it('fetchGitDiff extracts unified rows from response', async () => {
    const unified = [{ kind: 'add', oldLine: null, newLine: 1, text: 'new line' }]
    stubFetch({ unified })

    const result = await fetchGitDiff('a.ml')
    expect(result).toHaveLength(1)
    expect(result[0]!.kind).toBe('add')
  })

  it('fetchGitDiff defaults to empty array when unified missing', async () => {
    stubFetch({})

    const result = await fetchGitDiff('a.ml')
    expect(result).toHaveLength(0)
  })

  it('fetchGitDiff uses HEAD as default baseRef', async () => {
    stubFetch({ unified: [] })

    await fetchGitDiff('a.ml')
    expect(mockFetch.mock.calls[0]![0]).toContain('base_ref=HEAD')
  })

  it('fetchGitDiff accepts custom baseRef', async () => {
    stubFetch({ unified: [] })

    await fetchGitDiff('a.ml', { baseRef: 'v0.19.0' })
    expect(mockFetch.mock.calls[0]![0]).toContain('base_ref=v0.19.0')
  })

  it('fetchGitDiff appends repo_id param when provided', async () => {
    stubFetch({ unified: [] })

    await fetchGitDiff('a.ml', { repoId: 'masc' })
    expect(mockFetch.mock.calls[0]![0]).toContain('repo_id=masc')
  })
})
