import { html } from 'htm/preact'
import { useLayoutEffect, useState } from 'preact/hooks'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import * as Y from 'yjs'
import { sendArtifactDraftCommand, type ArtifactDraftView } from '../../api/artifact-drafts'
import { sendArtifactPresence, streamArtifactDraft } from '../../api/artifact-draft-live'
import { ArtifactLiveSession, draftBase64, draftBytes, type ArtifactLiveState } from '../../lib/artifact-live-session'
import { artifactDraftRecoveries, discardArtifactDraftRecovery } from '../../lib/artifact-draft-recovery'
import { artifactSentenceRecoveries, discardArtifactSentence } from '../../lib/artifact-sentence-recovery'
import { replaceSharedSelection, seedSharedDocument, selectSharedTextRange, sharedSource, sharedState } from '../../lib/artifact-shared-document'
import { officeChartFigure, type OfficeChartType } from '../../lib/artifact-office-chart'
import { ArtifactSentenceEditor } from './artifact-sentence-editor'

vi.mock('../../api/artifact-drafts', async original => ({ ...await original<typeof import('../../api/artifact-drafts')>(), sendArtifactDraftCommand: vi.fn() }))
vi.mock('../../api/artifact-draft-live', async original => ({ ...await original<typeof import('../../api/artifact-draft-live')>(), streamArtifactDraft: vi.fn(), sendArtifactPresence: vi.fn() }))
const workspace = { basePath: '/sentence-fixture', mascRoot: '/sentence-fixture/.masc' }
const id = `artifact-${'d'.repeat(32)}`, documents: Y.Doc[] = []
function figure(type: OfficeChartType = 'line') {
  return officeChartFigure({ type, title: '실적', categories: ['서울', '제주', '부산'], series: [{ name: '금액', values: [12.5, null, 0], numberFormat: '0.00' }] })
}
function open(source = figure()) {
  const authority = seedSharedDocument(source); documents.push(authority)
  const target = { artifact_id: id, generation: '019f0000-0000-7000-8000-000000000000' }
  let sequence = 0, changed: (state: ArtifactLiveState) => void = () => {}
  const snapshot = (): ArtifactDraftView => ({ content: sharedSource(authority), threads: [], discussion_receipts: [], selection: null,
    draft: { schema: 'masc.artifact_draft.v2', target, state: draftBase64(sharedState(authority)), base_revision: 1,
      base_sha256: 'a'.repeat(64), sequence, updated_by: 'human', updated_at: '2026-11-17T03:00:00Z' } })
  vi.mocked(streamArtifactDraft).mockImplementation(async (_, __, onFrame, signal) => {
    onFrame({ schema: 'masc.artifact_draft_live.v1', target, session_id: 'self', document: snapshot(),
      peers: [{ session_id: 'self', actor: 'human', source: { kind: 'dashboard_connection' }, position: null, observed_at: '2026-11-17T03:00:00Z' }] })
    await new Promise<void>(resolve => signal.addEventListener('abort', () => resolve(), { once: true }))
  })
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command => {
    if (command.action !== 'merge') throw new Error('Unexpected command in sentence fixture')
    command.updates.forEach(update => Y.applyUpdate(authority, draftBytes(update))); sequence++
    return snapshot()
  })
  const session = new ArtifactLiveSession(snapshot(), workspace, state => changed(state)), pending = vi.fn()
  function Editor() {
    const [state, setState] = useState(session.snapshot)
    useLayoutEffect(() => {
      changed = setState; void session.connect()
      return () => { changed = () => {}; session.dispose() }
    }, [])
    return html`<${ArtifactSentenceEditor} session=${session} state=${state} format="html" onPending=${pending} />`
  }
  render(html`<${Editor} />`)
  return { authority, session, snapshot, pending }
}
async function choose(text: string) {
  const frame = await screen.findByTitle('문장을 눌러 편집하는 미리보기') as HTMLIFrameElement
  const projected = new DOMParser().parseFromString(frame.srcdoc, 'text/html')
  const node = [...projected.querySelectorAll('[data-masc-artifact-text]')].find(node => node.textContent === text)!
  fireEvent(window, new MessageEvent('message', { source: frame.contentWindow, data: { type: 'masc.artifact.text.selected.v1',
    token: projected.querySelector('script')!.getAttribute('nonce'), id: Number(node.getAttribute('data-masc-artifact-text')) } }))
  const input = await screen.findByLabelText('선택한 문장') as HTMLTextAreaElement
  await waitFor(() => expect((screen.getByRole('button', { name: '문장 반영' }) as HTMLButtonElement).disabled).toBe(true))
  return input
}
beforeEach(() => {
  vi.mocked(sendArtifactDraftCommand).mockReset(); vi.mocked(streamArtifactDraft).mockReset()
  vi.mocked(sendArtifactPresence).mockReset().mockResolvedValue()
})
afterEach(() => {
  cleanup()
  artifactSentenceRecoveries(workspace, id).forEach(discardArtifactSentence)
  artifactDraftRecoveries(workspace, id).forEach(discardArtifactDraftRecovery)
  documents.splice(0).forEach(doc => doc.destroy())
  vi.restoreAllMocks()
})

it.each(['abc', '0.10000000000000001', '1e-324', '\u0001', '\ud800'])('rejects shared chart input %j before changing any Y.Doc bytes and retains the input', async value => {
  const view = open()
  fireEvent.input(await choose('12.5'), { target: { value } })
  const before = sharedState(view.session.doc)
  fireEvent.click(screen.getByRole('button', { name: '문장 반영' }))
  expect(sharedState(view.session.doc)).toEqual(before)
  expect(sharedSource(view.session.doc)).toBe(figure())
  expect(sendArtifactDraftCommand).not.toHaveBeenCalled()
  expect((screen.getByLabelText('선택한 문장') as HTMLTextAreaElement).value).toBe(value)
  expect(artifactSentenceRecoveries(workspace, id).some(record => record.input === value)).toBe(true)
  expect(view.pending).toHaveBeenLastCalledWith(true)
})

for (const type of ['column', 'bar', 'line', 'pie'] as const) it(`validates ${type} at the current relative range after another writer inserts before it`, async () => {
  const source = figure(type), view = open(source)
  fireEvent.input(await choose('12.5'), { target: { value: '7.5' } })
  await act(() => {
    view.authority.getText('content').insert(0, '<p>다른 편집자의 문단</p>')
    view.session.acceptServerView(view.snapshot())
  })
  fireEvent.input(screen.getByLabelText('선택한 문장'), { target: { value: 'abc' } })
  const before = sharedState(view.session.doc)
  fireEvent.click(screen.getByRole('button', { name: '문장 반영' }))
  expect(sharedState(view.session.doc)).toEqual(before)
  expect(screen.getByRole('status').textContent).toContain('차트 값은 숫자 또는 빈 셀이어야 합니다')
  fireEvent.input(screen.getByLabelText('선택한 문장'), { target: { value: '7.5' } })
  fireEvent.click(screen.getByRole('button', { name: '문장 반영' }))
  expect(sharedSource(view.session.doc)).toBe('<p>다른 편집자의 문단</p>' + source.replace('<td>12.5</td>', '<td>7.5</td>'))
  expect(view.pending).toHaveBeenLastCalledWith(false)
})

it.each(['', '0'])('preserves the meaning of a shared numeric replacement %j', async value => {
  const source = figure(), view = open(source)
  fireEvent.input(await choose('12.5'), { target: { value } })
  fireEvent.click(screen.getByRole('button', { name: '문장 반영' }))
  expect(sharedSource(view.session.doc)).toBe(source.replace('<td>12.5</td>', `<td>${value}</td>`))
})

it('refuses a stale shared scalar after another writer changes the selected value', async () => {
  const view = open()
  fireEvent.input(await choose('12.5'), { target: { value: '7.5' } })
  await act(() => {
    const start = sharedSource(view.authority).indexOf('12.5')
    view.authority.getText('content').delete(start, '12.5'.length); view.authority.getText('content').insert(start, '99')
    view.session.acceptServerView(view.snapshot())
  })
  const before = sharedState(view.session.doc)
  fireEvent.click(screen.getByRole('button', { name: '문장 반영' }))
  expect(sharedState(view.session.doc)).toEqual(before)
  expect((screen.getByLabelText('선택한 문장') as HTMLTextAreaElement).value).toBe('7.5')
})

it('does not validate an unrelated chart while editing ordinary HTML text', async () => {
  const source = '<p>본문</p>' + figure().replace('<td>12.5</td>', '<td>abc</td>'), view = open(source)
  fireEvent.input(await choose('본문'), { target: { value: '고친 <본문> & 😀' } })
  fireEvent.click(screen.getByRole('button', { name: '문장 반영' }))
  expect(sharedSource(view.session.doc)).toBe(source.replace('<p>본문</p>', '<p>고친 &lt;본문&gt; &amp; 😀</p>'))
})

it('keeps the generic shared source edit API independent from visual chart validation', () => {
  const source = figure(), doc = seedSharedDocument(source); documents.push(doc)
  const start = source.indexOf('12.5'), selection = selectSharedTextRange(doc, { anchor: start, head: start + '12.5'.length })
  replaceSharedSelection(doc, selection, '12.5', 'abc')
  expect(sharedSource(doc)).toBe(source.replace('<td>12.5</td>', '<td>abc</td>'))
})
