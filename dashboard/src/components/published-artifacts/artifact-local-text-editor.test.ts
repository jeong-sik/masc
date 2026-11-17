import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import JSZip from 'jszip'
import { publishArtifact, type ArtifactDocument, type ArtifactDraft } from '../../api/published-artifacts'
import { artifactHtmlTextEditor } from '../../lib/artifact-html-text'
import { replaceLocalArtifactText, selectLocalArtifactText, type ArtifactLocalTextInput } from '../../lib/artifact-local-text'
import { officeChartFigure, type OfficeChartType } from '../../lib/artifact-office-chart'
import { artifactWordFile } from '../../lib/artifact-word-export'
import { artifactHwpxFile } from '../../lib/artifact-hwpx-export'
import { ArtifactComposer } from './artifact-composer'

vi.mock('../../api/published-artifacts', async original => ({ ...await original<typeof import('../../api/published-artifacts')>(), publishArtifact: vi.fn() }))
const workspace = { basePath: '/fixture', mascRoot: '/fixture/.masc' }
const table = '<!-- retain -->\r\n<table style="width:250.5pt"><colgroup><col style="width:50pt"><col style="width:200.5pt"></colgroup><tr><td rowspan="2"><strong>계약</strong></td><td><p></p></td></tr><tr><td>25</td></tr></table>'
function figure(type: OfficeChartType) {
  return officeChartFigure({ type, title: '실적', categories: ['서울', '제주', '부산'], series: [{ name: '금액', values: [12.5, null, 0], numberFormat: '0.00' }] })
}
function open(content = table, format: 'html' | 'markdown' = 'html', current = () => true) {
  const initial: ArtifactDraft = { title: '원고', summary: '요약', format, content }
  const changed = vi.fn<(value: ArtifactDraft, pending: ArtifactLocalTextInput | null) => void>(), cancel = vi.fn()
  const view = render(html`<${ArtifactComposer} initial=${initial} capturedWorkspace=${workspace} workspaceRoot="/fixture" isCurrent=${current}
    onDraftChange=${changed} onRelease=${vi.fn()} onMutation=${vi.fn()} onSaved=${vi.fn()} onCancel=${cancel} />`)
  return { ...view, initial, changed, cancel }
}
async function choose(text: string, occurrence = 0) {
  const frame = await screen.findByTitle('글과 셀을 눌러 편집하는 미리보기') as HTMLIFrameElement
  const document = new DOMParser().parseFromString(frame.srcdoc, 'text/html')
  const node = [...document.querySelectorAll('[data-masc-artifact-text]')].filter(node => node.textContent === text)[occurrence]!
  const token = document.querySelector('script')!.getAttribute('nonce')
  fireEvent(window, new MessageEvent('message', { source: frame.contentWindow,
    data: { type: 'masc.artifact.text.selected.v1', token, id: Number(node.getAttribute('data-masc-artifact-text')) } }))
  return await screen.findByLabelText('선택한 글 또는 셀 값') as HTMLTextAreaElement
}
beforeEach(() => { vi.mocked(publishArtifact).mockReset(); vi.mocked(publishArtifact).mockImplementation(() => new Promise(() => {})) })
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals() })

it('edits a blank imported cell while retaining all other source bytes, spans and widths', async () => {
  const view = open()
  expect(screen.queryByLabelText('문서 본문')).toBeNull()
  fireEvent.input(await choose(''), { target: { value: '25 < 30 & 😀' } })
  expect(view.changed.mock.lastCall![0].content).toBe(table)
  expect(view.changed.mock.lastCall![1]!.input).toBe('25 < 30 & 😀')
  expect((screen.getByRole('button', { name: '아티팩트 등록' }) as HTMLButtonElement).disabled).toBe(true)
  fireEvent.click(screen.getByRole('button', { name: '원고에 반영' }))
  expect(view.changed.mock.lastCall).toEqual([{ ...view.initial, content: table.replace('<p></p>', '<p>25 &lt; 30 &amp; 😀</p>') }, null])
  expect(screen.queryByLabelText('선택한 글 또는 셀 값')).toBeNull()
})

for (const kind of ['column', 'bar', 'line', 'pie'] as const) it(`edits ${kind} values without changing metadata or confusing blanks with zero`, async () => {
  const source = figure(kind), view = open(source)
  fireEvent.input(await choose('12.5'), { target: { value: '42' } })
  fireEvent.click(screen.getByRole('button', { name: '원고에 반영' }))
  expect(view.changed.mock.lastCall![0].content).toBe(source.replace('<td>12.5</td>', '<td>42</td>'))
  fireEvent.input(await choose('0'), { target: { value: '' } })
  fireEvent.click(screen.getByRole('button', { name: '원고에 반영' }))
  const expected = source.replace('<td>12.5</td>', '<td>42</td>').replace('<td>0</td>', '<td></td>')
  expect(view.changed.mock.lastCall![0].content).toBe(expected)
  fireEvent.input(await choose('', 0), { target: { value: '0' } })
  fireEvent.click(screen.getByRole('button', { name: '원고에 반영' }))
  expect(view.changed.mock.lastCall![0].content).toBe(expected.replace('<td></td>', '<td>0</td>'))
})

for (const kind of ['column', 'bar', 'line', 'pie'] as const) it(`reselects a cleared ${kind} title and enters a new title at its original source position`, async () => {
  const source = figure(kind), view = open(source)
  fireEvent.input(await choose('실적'), { target: { value: '' } })
  fireEvent.click(screen.getByRole('button', { name: '원고에 반영' }))
  const cleared = source.replace('<figcaption>실적</figcaption>', '<figcaption></figcaption>')
  expect(view.changed.mock.lastCall![0].content).toBe(cleared)
  const frame = screen.getByTitle('글과 셀을 눌러 편집하는 미리보기') as HTMLIFrameElement
  const projected = new DOMParser().parseFromString(frame.srcdoc, 'text/html')
  expect(projected.querySelector('figcaption [aria-label="빈 차트 제목 편집"]')?.textContent).toBe('제목 추가')
  const input = await choose('제목 추가')
  expect(input.value).toBe('')
  fireEvent.input(input, { target: { value: '새 제목 <& 😀' } })
  fireEvent.click(screen.getByRole('button', { name: '원고에 반영' }))
  expect(view.changed.mock.lastCall![0].content).toBe(cleared.replace('<figcaption></figcaption>', '<figcaption>새 제목 &lt;&amp; 😀</figcaption>'))
})

for (const kind of ['column', 'bar', 'line', 'pie'] as const) it(`shows an empty ${kind} title prompt without adding it to the input or native exports`, async () => {
  const source = figure(kind).replace('<figcaption>실적</figcaption>', '<figcaption></figcaption>'), view = open(source)
  expect((await choose('제목 추가')).value).toBe('')
  expect((screen.getByRole('button', { name: '원고에 반영' }) as HTMLButtonElement).disabled).toBe(true)
  const draft = view.changed.mock.lastCall![0]
  expect(draft.content).toBe(source)
  expect(draft.content).not.toContain('제목 추가')
  const doc: ArtifactDocument = { content: draft.content, revisions: [], artifact: { id: `artifact-${'a'.repeat(32)}`,
    revision: 1, title: draft.title, summary: draft.summary, format: draft.format, author: 'human',
    created_at: '2026-11-17T03:00:00Z', task_id: null, goal_id: null, url: '/', body: { _blob: { sha256: 'b'.repeat(64) } } } }
  for (const format of ['docx', 'hwpx'] as const) {
    const file = await (format === 'docx' ? artifactWordFile : artifactHwpxFile)(doc), zip = await JSZip.loadAsync(file.data)
    const path = format === 'docx' ? 'word/charts/chart1.xml' : 'Chart/chart1.xml'
    const xml = new DOMParser().parseFromString(await zip.file(path)!.async('string'), 'application/xml')
    const title = xml.getElementsByTagNameNS('http://schemas.openxmlformats.org/drawingml/2006/chart', 'title')[0]
    expect(title?.textContent ?? '').toBe('')
  }
})

it.each(['abc', '0.10000000000000001', '1e-324'])('keeps invalid chart input %s unapplied and downloadable', async value => {
  const source = figure('line'), view = open(source)
  fireEvent.input(await choose('12.5'), { target: { value } })
  fireEvent.click(screen.getByRole('button', { name: '원고에 반영' }))
  await screen.findByRole('status')
  expect(view.changed.mock.lastCall![0].content).toBe(source)
  expect((screen.getByLabelText('선택한 글 또는 셀 값') as HTMLTextAreaElement).value).toBe(value)
  expect(screen.getByRole('button', { name: '미반영 입력 다운로드' })).toBeTruthy()
})

it('retains input through source mode and refuses stale offsets even when expected text still matches', async () => {
  const source = '<p>같은 글</p><p>같은 글</p>', view = open(source)
  fireEvent.input(await choose('같은 글'), { target: { value: '보관할 입력' } })
  const selected = view.changed.mock.lastCall![1]!
  fireEvent.click(screen.getByRole('button', { name: 'HTML 원본 편집' }))
  expect(screen.getByRole('complementary', { name: '미반영 입력' }).textContent).toContain('보관할 입력')
  fireEvent.input(screen.getByLabelText('문서 본문'), { target: { value: source + '<p>끝 문단</p>' } })
  expect(view.changed.mock.lastCall![1]).toBe(selected)
  fireEvent.click(screen.getByRole('button', { name: '글·셀 편집' }))
  expect((screen.getByLabelText('선택한 글 또는 셀 값') as HTMLTextAreaElement).value).toBe('보관할 입력')
  fireEvent.click(screen.getByRole('button', { name: '원고에 반영' }))
  expect(screen.getByRole('status').textContent).toContain('원본이 바뀌었습니다')
  expect(view.changed.mock.lastCall![0].content).toBe(source + '<p>끝 문단</p>')
  vi.stubGlobal('confirm', vi.fn().mockReturnValueOnce(false).mockReturnValueOnce(true))
  fireEvent.click(screen.getByRole('button', { name: '선택 취소' }))
  expect(view.changed.mock.lastCall![1]).toBe(selected)
  fireEvent.click(screen.getByRole('button', { name: '선택 취소' }))
  expect(view.changed.mock.lastCall![1]).toBeNull()
})

it('keeps an unchanged projection usable after source-view changes and excludes UI metadata from publication', async () => {
  const view = open('<p>원래</p>')
  fireEvent.input(await choose('원래'), { target: { value: '수정' } })
  fireEvent.click(screen.getByRole('button', { name: 'HTML 원본 편집' }))
  fireEvent.click(screen.getByRole('button', { name: '글·셀 편집' }))
  fireEvent.click(screen.getByRole('button', { name: '원고에 반영' }))
  const button = screen.getByRole('button', { name: '아티팩트 등록' }) as HTMLButtonElement
  await waitFor(() => expect(button.disabled).toBe(false))
  fireEvent.click(button)
  expect(publishArtifact).toHaveBeenCalledExactlyOnceWith({ ...view.initial, content: '<p>수정</p>' }, workspace)
})

it('does not apply after authority retirement and keeps Markdown in source mode', async () => {
  let current = true
  const view = open('<p>원래</p>', 'html', () => current)
  fireEvent.input(await choose('원래'), { target: { value: '보관할 입력' } })
  const retained = view.changed.mock.lastCall
  current = false
  fireEvent.click(screen.getByRole('button', { name: '원고에 반영' }))
  expect(view.changed.mock.lastCall).toBe(retained)
  fireEvent.click(screen.getByRole('button', { name: '편집 닫기' }))
  expect(view.cancel).toHaveBeenCalledOnce()
  expect((screen.getByLabelText('선택한 글 또는 셀 값') as HTMLTextAreaElement).value).toBe('보관할 입력')
  view.unmount()
  open('# Markdown', 'markdown')
  expect((screen.getByLabelText('문서 본문') as HTMLTextAreaElement).value).toBe('# Markdown')
  expect(screen.queryByTitle('글과 셀을 눌러 편집하는 미리보기')).toBeNull()
})

it('preserves bytes outside a selected formatted leaf and rejects obsolete projection identities', () => {
  const source = '<p>앞 <strong>한글 😀</strong> &amp; 뒤</p>', projection = {}
  const part = artifactHtmlTextEditor(source).parts.find(part => part.text === '한글 😀')!
  const input = { ...selectLocalArtifactText(projection, part), input: '<새 글> & 친구' }
  expect(replaceLocalArtifactText(source, projection, input)).toBe(source.replace('한글 😀', '&lt;새 글&gt; &amp; 친구'))
  expect(() => replaceLocalArtifactText(source, {}, input)).toThrow('원본이 바뀌었습니다')
})
