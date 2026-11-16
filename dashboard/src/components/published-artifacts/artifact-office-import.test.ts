import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { clearStoredToken, get, getWithResponse, post, setStoredToken } from '../../api/core'
import type { ArtifactDocument } from '../../api/published-artifacts'
import { artifactWordFile } from '../../lib/artifact-word-export'
import { artifactHwpxFile } from '../../lib/artifact-hwpx-export'
import { importArtifactDocx } from '../../lib/artifact-docx-import'
import { importArtifactHwpx } from '../../lib/artifact-hwpx-import'
import { importArtifactHwp } from '../../lib/artifact-hwp-import'
import { officeImportLimits } from '../../lib/artifact-office-xml'
import { officeChartFigure } from '../../lib/artifact-office-chart'
import { ArtifactImport } from './artifact-import'
import type { ArtifactDraftSnapshot } from './artifact-composer'

vi.mock('../../api/core', async original => ({ ...await original<typeof import('../../api/core')>(), get: vi.fn(), getWithResponse: vi.fn(), post: vi.fn() }))
// These tests cover the component and publication. The real WASM conversion is verified separately.
vi.mock('../../lib/artifact-hwp-import', () => ({ importArtifactHwp: vi.fn() }))
const chart = officeChartFigure({ type: 'column', title: '지역 실적', categories: ['서울', '제주'], series: [{ name: '실적', values: [12.5, null] }] })
const content = '<table><tr><td colspan="2">합계</td></tr><tr><td>건수</td><td>3</td></tr></table>' + chart
const meta = { id: `artifact-${'a'.repeat(32)}`, revision: 1, title: '실적', summary: '보고서', format: 'html' as const, author: 'fixture',
  created_at: '2026-11-16T00:00:00Z', task_id: null, goal_id: null, url: '/', body: { _blob: { sha256: 'b'.repeat(64) } } }
const input: ArtifactDocument = { content, artifact: meta, revisions: [meta] }
function file(bytes: ArrayBuffer, name: string): File {
  const value = new File([bytes], name)
  Object.defineProperty(value, 'arrayBuffer', { value: vi.fn(async () => bytes) })
  return value
}
function open(isCurrent = () => true) {
  const drafts: ArtifactDraftSnapshot[] = [], saved = vi.fn(), forget = vi.fn(), cancelled = vi.fn()
  const view = render(html`<${ArtifactImport} workspaceRoot="/office-fixture" isCurrent=${isCurrent}
    draftRetention=${{ remember: (draft: ArtifactDraftSnapshot) => drafts.push(draft), release: vi.fn(), forget }}
    onMutation=${vi.fn()} onSaved=${saved} onCancel=${cancelled} />`)
  return { ...view, drafts, saved, forget, cancelled }
}
function pendingHwp() {
  let resolve!: (value: Awaited<ReturnType<typeof importArtifactHwp>>) => void
  const promise = new Promise<Awaited<ReturnType<typeof importArtifactHwp>>>(done => { resolve = done })
  return { promise, resolve }
}
beforeEach(() => {
  setStoredToken('office-fixture')
  vi.mocked(get).mockReset(); vi.mocked(getWithResponse).mockReset(); vi.mocked(post).mockReset()
  vi.mocked(importArtifactHwp).mockReset()
  vi.mocked(importArtifactHwp).mockResolvedValue({ content, notices: [] })
  vi.mocked(get).mockResolvedValue({ paths: { effective_base_path: '/office-fixture', effective_masc_root: '/office-fixture/.masc' } })
})
afterEach(() => { cleanup(); clearStoredToken(); vi.restoreAllMocks() })

for (const format of ['docx', 'hwpx', 'hwp'] as const) it(`imports ${format}, edits chart data and publishes once before re-exporting the edited native chart`, async () => {
  const write = format === 'docx' ? artifactWordFile : artifactHwpxFile
  const read = format === 'docx' ? importArtifactDocx : importArtifactHwpx
  const generated = format === 'hwp' ? { data: new ArrayBuffer(0) } : await write(input)
  const view = open(), selected = file(generated.data, `실적.${format}`)
  fireEvent.change(screen.getByLabelText('가져올 문서 파일'), { target: { files: [selected] } })
  const body = await screen.findByLabelText('문서 본문') as HTMLTextAreaElement
  expect(body.value).toContain('data-masc-chart="column"')
  expect(body.value).toContain('colspan="2"')
  expect(body.value).toContain('<td>12.5</td>')
  expect(body.value).toContain('<td></td>')
  expect(view.drafts.at(-1)!.value.content).toBe(body.value)
  expect(post).not.toHaveBeenCalled()
  const edited = body.value.replace('<td>12.5</td>', '<td>42</td>')
  fireEvent.input(body, { target: { value: edited } })
  const sent = view.drafts.at(-1)!.value, stored = { ...meta, title: sent.title, summary: sent.summary }
  const publication = { schema: 'masc.published_artifact.v1', artifact: stored, revision_url: '/' }
  vi.mocked(post).mockResolvedValue(publication)
  vi.mocked(getWithResponse).mockResolvedValue({ data: { artifact: stored, content: sent.content, revisions: [stored] }, headers: new Headers({ 'x-masc-workspace-read': 'matched-v1' }) })
  const button = screen.getByRole('button', { name: '아티팩트 등록' }) as HTMLButtonElement
  await waitFor(() => expect(button.disabled).toBe(false))
  fireEvent.click(button)
  await waitFor(() => expect(view.saved).toHaveBeenCalledTimes(1))
  expect(post).toHaveBeenCalledTimes(1)
  expect(vi.mocked(post).mock.calls[0]![1]).toEqual({ ...sent,
    expected_workspace: { base_path: '/office-fixture', masc_root: '/office-fixture/.masc' },
  })
  expect(getWithResponse).toHaveBeenCalledWith(expect.stringContaining('revision=1'), expect.objectContaining({ extraHeaders: {
    'x-masc-expected-base-path': '/office-fixture', 'x-masc-expected-masc-root': '/office-fixture/.masc',
  } }))
  const result = await read((await write({ content: edited, artifact: stored, revisions: [stored] })).data)
  expect(result.content).toContain('<td>42</td>')
  expect(result.content).not.toContain('<td>12.5</td>')
  expect(result.content).toContain('colspan="2"')
})

for (const format of ['docx', 'hwpx', 'hwp']) it(`refuses an oversized ${format} before allocating its file buffer`, async () => {
  open()
  const selected = file(new ArrayBuffer(0), `large.${format}`)
  Object.defineProperty(selected, 'size', { value: officeImportLimits.inputBytes + 1 })
  fireEvent.change(screen.getByLabelText('가져올 문서 파일'), { target: { files: [selected] } })
  await screen.findByText('가져올 문서는 32 MiB 이하여야 합니다.')
  expect(selected.arrayBuffer).not.toHaveBeenCalled()
  expect(screen.queryByLabelText('문서 본문')).toBeNull()
  expect(post).not.toHaveBeenCalled()
})

it('does not publish or open a draft when HWP conversion fails', async () => {
  const view = open()
  vi.mocked(importArtifactHwp).mockRejectedValue(new Error('지원하지 않는 HWP 개체입니다.'))
  fireEvent.change(screen.getByLabelText('가져올 문서 파일'), { target: { files: [file(new ArrayBuffer(0), '문서.hwp')] } })
  await screen.findByText('지원하지 않는 HWP 개체입니다.')
  expect(view.drafts).toHaveLength(0)
  expect(screen.queryByLabelText('문서 본문')).toBeNull()
  expect(post).not.toHaveBeenCalled()
})

it('aborts an outstanding HWP worker when the import surface closes', async () => {
  const view = open()
  vi.mocked(importArtifactHwp).mockImplementation((_data, signal) => new Promise((_resolve, reject) => {
    signal?.addEventListener('abort', () => reject(new DOMException('closed', 'AbortError')), { once: true })
  }))
  fireEvent.change(screen.getByLabelText('가져올 문서 파일'), { target: { files: [file(new ArrayBuffer(0), '문서.hwp')] } })
  await waitFor(() => expect(importArtifactHwp).toHaveBeenCalledTimes(1))
  const signal = vi.mocked(importArtifactHwp).mock.calls[0]![1]!
  view.unmount()
  expect(signal.aborted).toBe(true)
  expect(view.drafts).toHaveLength(0)
  expect(post).not.toHaveBeenCalled()
})

it('cancels a non-responding HWP read, retries the same file and ignores the old result', async () => {
  const old = pendingHwp(), next = pendingHwp(), view = open()
  const input = screen.getByLabelText('가져올 문서 파일') as HTMLInputElement, selected = file(new ArrayBuffer(0), '문서.hwp')
  const select = () => {
    const transfer = new DataTransfer(); transfer.items.add(selected)
    input.files = transfer.files
    fireEvent.change(input)
  }
  vi.mocked(importArtifactHwp).mockReturnValueOnce(old.promise).mockReturnValueOnce(next.promise)
  select()
  expect(input.value).toBe('')
  expect(input.files).toHaveLength(0)
  await waitFor(() => expect(importArtifactHwp).toHaveBeenCalledTimes(1))
  const oldSignal = vi.mocked(importArtifactHwp).mock.calls[0]![1]!
  fireEvent.click(screen.getByRole('button', { name: '가져오기 취소', exact: true }))
  expect(oldSignal.aborted).toBe(true)
  expect(view.cancelled).not.toHaveBeenCalled()
  expect(screen.getByRole('status').textContent).toBe('파일 가져오기를 취소했습니다.')
  expect(screen.queryByRole('button', { name: '가져오기 취소', exact: true })).toBeNull()
  select()
  expect(input.value).toBe('')
  await waitFor(() => expect(importArtifactHwp).toHaveBeenCalledTimes(2))
  await act(async () => { old.resolve({ content: '<p>취소한 원고</p>', notices: [] }) })
  expect(screen.queryByLabelText('문서 본문')).toBeNull()
  expect(screen.getByRole('status').textContent).toBe('파일을 읽고 있습니다.')
  await act(async () => { next.resolve({ content: '<p>새 원고</p>', notices: [] }) })
  expect((await screen.findByLabelText('문서 본문') as HTMLTextAreaElement).value).toBe('<p>새 원고</p>')
  expect(view.drafts).toHaveLength(1)
  expect(post).not.toHaveBeenCalled()
})

it('aborts immediately on Close even before the owner unmounts the surface', async () => {
  const old = pendingHwp(), view = open()
  vi.mocked(importArtifactHwp).mockReturnValue(old.promise)
  fireEvent.change(screen.getByLabelText('가져올 문서 파일'), { target: { files: [file(new ArrayBuffer(0), '이전.hwp')] } })
  await waitFor(() => expect(importArtifactHwp).toHaveBeenCalledTimes(1))
  const signal = vi.mocked(importArtifactHwp).mock.calls[0]![1]!
  fireEvent.click(screen.getByRole('button', { name: '닫기', exact: true }))
  expect(signal.aborted).toBe(true)
  expect(view.cancelled).toHaveBeenCalledTimes(1)
  await act(async () => { old.resolve({ content: '<p>늦은 원고</p>', notices: [] }) })
  expect(view.drafts).toHaveLength(0)
  expect(screen.queryByLabelText('문서 본문')).toBeNull()
})

it('does not start an HWP worker when the user cancels while file bytes are still being read', async () => {
  let finish!: (bytes: ArrayBuffer) => void
  const bytes = new Promise<ArrayBuffer>(resolve => { finish = resolve }), selected = new File([], '읽는 중.hwp'), view = open()
  const read = vi.fn(() => bytes)
  Object.defineProperty(selected, 'arrayBuffer', { value: read })
  fireEvent.change(screen.getByLabelText('가져올 문서 파일'), { target: { files: [selected] } })
  await waitFor(() => expect(read).toHaveBeenCalledTimes(1))
  fireEvent.click(screen.getByRole('button', { name: '가져오기 취소', exact: true }))
  await act(async () => { finish(new ArrayBuffer(0)) })
  expect(importArtifactHwp).not.toHaveBeenCalled()
  expect(view.drafts).toHaveLength(0)
  expect(post).not.toHaveBeenCalled()
})

