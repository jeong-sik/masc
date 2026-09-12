// @vitest-environment jsdom
import { webcrypto } from 'node:crypto'
import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { get, ApiRequestError } from '../../api/core'
import { fetchToolBlob } from '../../api/tool-blob'
import { ChatTranscript, _resetTraceCardOpenChoicesForTests } from './primitives'
import { chatHistoryEntriesFromRest } from '../../keeper-state'
import { lookupToolCallOutput, recordToolCallOutputs, resetToolCallOutputs } from '../../tool-call-output-store'
vi.mock('../../api/core', async importOriginal => ({ ...await importOriginal<typeof import('../../api/core')>(), get: vi.fn() }))
vi.mock('../../api/tool-blob', () => ({ fetchToolBlob: vi.fn() }))
const id = 'old-execution/with+symbols'
const entries = chatHistoryEntriesFromRest('display-label-is-not-owner', [{
  id: 'autonomous:trace-writer#428', role: 'assistant', ts: 1789223399, content: null,
  autonomous_turn: { turn_id: 'trace-writer#428' },
  blocks: [{ t: 'trace', trace: [{ kind: 'tool', name: 'Edit', status: 'ok', execution_id: id }] }],
}])
function response(keeper = 'writer') { return { keeper, execution_id: id, entry: {
  keeper, execution_id: id, ts: 1, tool: 'Edit', success: true, duration_ms: 3,
  input: { old_string: 'old', new_string: 'new' },
  output: JSON.stringify({ ok: true, mode: 'patch', path: `${keeper}.md`, occurrences: 1 }),
  route_evidence: { descriptor_id: 'agent.edit_file' },
} } }
const transcript = (keeper = 'writer') => html`<${ChatTranscript} keeperName=${keeper} entries=${entries} emptyText="empty" />`
async function artifact(content: string) {
  const bytes = new TextEncoder().encode(content)
  const sha256 = Buffer.from(await webcrypto.subtle.digest('SHA-256', bytes)).toString('hex')
  return { content, bytes: bytes.length, sha256, mime: 'application/vnd.masc.tool-result-manifest+json' }
}
const openTurn = (view: { container: Element }) => fireEvent.click(view.container.querySelector<HTMLButtonElement>('.chat-block-trace-hd')!)
beforeEach(() => { vi.stubGlobal('crypto', webcrypto); resetToolCallOutputs(); _resetTraceCardOpenChoicesForTests() })
afterEach(() => { cleanup(); vi.resetAllMocks(); vi.unstubAllGlobals(); resetToolCallOutputs() })
describe('historical autonomous tool outputs', () => {
  it('opens a retained Edit outside the recent tail and resolves its verified manifest', async () => {
    const before = { _blob: { sha256: 'a'.repeat(64), bytes: 9, mime: 'application/octet-stream', preview: '' } }
    const after = { _blob: { sha256: 'b'.repeat(64), bytes: 12, mime: 'application/octet-stream', preview: '' } }
    const result = { ok: true, mode: 'patch', path: 'old-story.md', occurrences: 1, edit_snapshots: { status: 'stored', before, after } }
    const manifest = await artifact(JSON.stringify({ schema: 'masc.tool-result-artifact-manifest.v1', content: JSON.stringify(result), structured_content: result }))
    const payload = response()
    vi.mocked(get).mockResolvedValue({ ...payload, entry: { ...payload.entry, output: { _blob: { ...manifest, preview: '' } }, artifact_refs: [after, before] } })
    vi.mocked(fetchToolBlob).mockResolvedValue(manifest)
    const view = render(transcript()); expect(get).not.toHaveBeenCalled(); openTurn(view)
    await waitFor(() => expect(view.getByRole('button', { name: '편집 전후 원본 보기' })).toBeTruthy())
    const firstCall = vi.mocked(get).mock.calls[0]
    if (!firstCall) throw new Error('Expected a historical tool-output request')
    const requested = new URL(firstCall[0] as string, 'http://localhost')
    expect(requested.pathname).toBe('/api/v1/keepers/writer/tool-calls')
    expect(requested.searchParams.get('execution_id')).toBe(id)
    expect(requested.searchParams.has('limit')).toBe(false)
    expect(fetchToolBlob).toHaveBeenCalledWith(manifest.sha256, expect.objectContaining({ signal: expect.any(AbortSignal) }))
    expect(view.getByText('old-story.md · 1곳 편집')).toBeTruthy()
    expect(lookupToolCallOutput(id)?.keeper).toBe('writer'); expect(get).toHaveBeenCalledTimes(1)
  })
  it.each([[404, '저장된 실행 기록을 찾지 못했습니다.'], [409, '실행 기록이 중복되어'], [503, '저장된 실행 기록을 불러오지 못했습니다.']])('shows HTTP %i and retries only on operator action', async (status, message) => {
    vi.mocked(get).mockRejectedValueOnce(new ApiRequestError({ method: 'GET', path: '/tool-calls', status: status as number })).mockResolvedValueOnce(response())
    const view = render(transcript()); openTurn(view)
    await waitFor(() => expect(view.getByRole('alert').textContent).toContain(message))
    expect(view.queryByLabelText('편집 변경 기록')).toBeNull(); expect(get).toHaveBeenCalledTimes(1)
    fireEvent.click(view.getByRole('button', { name: '다시 조회' }))
    await waitFor(() => expect(view.getByText('writer.md · 1곳 편집')).toBeTruthy()); expect(get).toHaveBeenCalledTimes(2)
  })
  it.each(['keeper', 'execution'])('rejects a mismatched %s response identity', async axis => {
    const payload = response()
    vi.mocked(get).mockResolvedValue({ ...payload, entry: { ...payload.entry, ...(axis === 'keeper' ? { keeper: 'peer' } : { execution_id: 'other' }) } })
    const view = render(transcript()); openTurn(view)
    await waitFor(() => expect(view.getByRole('alert').textContent).toContain('불러오지 못했습니다'))
    expect(view.queryByLabelText('편집 변경 기록')).toBeNull(); expect(lookupToolCallOutput(id)).toBeNull()
  })
  it('does not display an old response after switching Keeper', async () => {
    let resolveOld!: (value: unknown) => void
    vi.mocked(get).mockImplementationOnce(() => new Promise(resolve => { resolveOld = resolve })).mockResolvedValueOnce(response('peer'))
    const view = render(transcript()); openTurn(view); await waitFor(() => expect(get).toHaveBeenCalledTimes(1))
    view.rerender(transcript('peer')); await waitFor(() => expect(view.getByText('peer.md · 1곳 편집')).toBeTruthy())
    resolveOld(response()); await Promise.resolve()
    expect(view.queryByText('writer.md · 1곳 편집')).toBeNull(); expect(lookupToolCallOutput(id)?.keeper).toBe('peer')
  })
  it('keeps concurrent Keeper results isolated without refetching after peer hydration', async () => {
    vi.mocked(get).mockImplementation(async path => response(
      new URL(path, 'http://localhost').pathname === '/api/v1/keepers/writer/tool-calls' ? 'writer' : 'peer'))
    const view = render(html`<div>
      <section data-testid="writer">${transcript('writer')}</section>
      <section data-testid="peer">${transcript('peer')}</section>
    </div>`)
    const writer = view.getByTestId('writer'), peer = view.getByTestId('peer')
    openTurn({ container: writer }); openTurn({ container: peer })
    await waitFor(() => {
      expect(within(writer).getByText('writer.md · 1곳 편집')).toBeTruthy()
      expect(within(peer).getByText('peer.md · 1곳 편집')).toBeTruthy()
    })
    expect(get).toHaveBeenCalledTimes(2)
    // Both mounted views observe the same store replacement, then retain their
    // own validated result while a third Keeper hydrates the colliding ID.
    for (const keeper of ['writer', 'peer', 'third']) {
      await act(async () => { recordToolCallOutputs([response(keeper).entry]) })
      expect(within(writer).getByText('writer.md · 1곳 편집')).toBeTruthy()
      expect(within(peer).getByText('peer.md · 1곳 편집')).toBeTruthy()
      expect(within(writer).queryByText('peer.md · 1곳 편집')).toBeNull()
      expect(within(peer).queryByText('writer.md · 1곳 편집')).toBeNull()
      expect(view.queryByText('third.md · 1곳 편집')).toBeNull()
      expect(get).toHaveBeenCalledTimes(2)
    }
  })
  it('rejects altered manifest bytes before presenting original-file controls', async () => {
    const manifest = await artifact('{"schema":"masc.tool-result-artifact-manifest.v1"}')
    const payload = response(); vi.mocked(get).mockResolvedValue({ ...payload, entry: { ...payload.entry, output: { _blob: { ...manifest, preview: '' } } } })
    vi.mocked(fetchToolBlob).mockResolvedValue({ ...manifest, content: 'altered' })
    const view = render(transcript()); openTurn(view)
    await waitFor(() => expect(view.getByRole('alert').textContent).toContain('바이트 검증'))
    expect(view.queryByRole('button', { name: '편집 전후 원본 보기' })).toBeNull()
  })
})
