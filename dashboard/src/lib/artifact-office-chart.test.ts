import { expect, it } from 'vitest'
import { parse, defaultTreeAdapter as tree, type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import JSZip from 'jszip'
import { DOMParser } from '@xmldom/xmldom'
import { officeChartFigure, officeChartFromFigure, officeNumber, type OfficeChart, type OfficeChartType } from './artifact-office-chart'
import { artifactWordFile } from './artifact-word-export'
import type { ArtifactDocument } from '../api/published-artifacts'

function chart(type: OfficeChartType = 'column'): OfficeChart {
  return { type, title: '표 & 차트', categories: ['첫째', '둘째', '셋째'], series: [{ name: '실적', values: [0, null, 12.5] }] }
}
function figure(source: string): Nodes.Element {
  const document = parse(source)
  const find = (node: Nodes.ParentNode): Nodes.Element | undefined => {
    for (const child of node.childNodes) if (tree.isElementNode(child)) {
      if (child.tagName === 'figure') return child
      const result = find(child); if (result) return result
    }
    return undefined
  }
  return find(document)!
}
function document(content: string): ArtifactDocument {
  return { content, revisions: [], artifact: { id: `artifact-${'a'.repeat(32)}`, revision: 1, title: '보고서', summary: '표와 차트',
    format: 'html', author: 'keeper', created_at: '2026-11-16T00:00:00Z', task_id: null, goal_id: null, url: '/', body: { _blob: { sha256: 'b'.repeat(64) } } } }
}

it('stores chart data once in an editable table and preserves zero, missing values and Unicode labels', () => {
  for (const type of ['column', 'bar', 'line', 'pie'] as const) {
    const input = chart(type), html = officeChartFigure(input)
    expect(officeChartFromFigure(figure(html))).toEqual(input)
    expect(html).not.toContain('<script')
    expect(html).toContain('<td>0</td>')
    expect(html).toContain('<td></td>')
  }
})

it('rejects invalid or imprecise numbers instead of silently substituting zero', () => {
  expect(officeNumber('')).toBeNull()
  expect(officeNumber(' -1.25e2 ')).toBe(-125)
  for (const value of ['12원', 'NaN', 'Infinity', '0x10', '9007199254740993', '9007199254740991.1', '0.10000000000000001', '1e-324']) expect(() => officeNumber(value)).toThrow()
  expect(officeNumber('0.1000')).toBe(0.1)
  expect(officeNumber('1.25e2')).toBe(125)
  expect(() => officeChartFromFigure(figure('<figure data-masc-chart="column"><table><tr><th>항목</th><th>값</th></tr><tr><td>A</td><td>알 수 없음</td></tr></table></figure>'))).toThrow('숫자')
})

it('refuses multiline numeric cells and extra chart content instead of merging or discarding it', () => {
  const source = officeChartFigure(chart())
  expect(() => officeChartFromFigure(figure(source.replace('<td>0</td>', '<td>1<br>2</td>')))).toThrow('서식 없이')
  expect(() => officeChartFromFigure(figure(source.replace('표 &amp; 차트', '2025<br>2026')))).toThrow('서식 없이')
  for (const heading of ['항목<br>단위: 원', '항목\u0001', '단위: 원']) expect(() => officeChartFromFigure(figure(source.replace('<th>항목</th>', `<th>${heading}</th>`)))).toThrow()
  expect(() => officeChartFromFigure(figure(source.replace('</figure>', '<p>회계기준: 세전 금액</p></figure>')))).toThrow('설명')
  expect(() => officeChartFromFigure(figure(source.replace('<table>', '<table><caption>회계기준: 세전 금액</caption>')))).toThrow('설명')
  expect(() => officeChartFromFigure(figure(officeChartFigure(chart('pie')).replace('data-masc-chart="pie"', 'data-masc-chart="pie" data-masc-empty-values="gap"')))).toThrow('원형 차트')
})

it('retains percentage formats and the meaning of missing values as chart metadata', async () => {
  const input: OfficeChart = { ...chart('line'), type: 'line', emptyValues: 'zero', valueFormat: '0.0%',
    series: [{ name: '비율', values: [0, null, 0.125], numberFormat: '0.0%' }] }
  expect(officeChartFromFigure(figure(officeChartFigure(input)))).toEqual(input)
  const file = await artifactWordFile(document(officeChartFigure(input)))
  const zip = await JSZip.loadAsync(file.data), xml = await zip.file('word/charts/chart1.xml')!.async('string')
  expect(xml).toContain('formatCode="0.0%"')
  expect(xml).toContain('<c:dispBlanksAs val="zero"')
})

it('rejects chart tables with missing columns and pie charts with negative data', () => {
  expect(() => officeChartFromFigure(figure('<figure data-masc-chart="line"><table><tr><th>항목</th><th>값</th></tr><tr><td>A</td></tr></table></figure>'))).toThrow('열 수')
  expect(() => officeChartFigure({ ...chart('pie'), series: [{ name: '값', values: [-1, 0, 1] }] })).toThrow('음수')
})

it('exports real Word charts with embedded workbooks instead of pictures or duplicate data tables', async () => {
  const ns = 'http://schemas.openxmlformats.org/drawingml/2006/chart'
  for (const type of ['column', 'bar', 'line', 'pie'] as const) {
    const file = await artifactWordFile(document(officeChartFigure(chart(type))))
    const zip = await JSZip.loadAsync(file.data)
    const xml = new DOMParser().parseFromString(await zip.file('word/charts/chart1.xml')!.async('string'), 'application/xml')
    expect(xml.getElementsByTagNameNS(ns, type === 'column' || type === 'bar' ? 'barChart' : `${type}Chart`).length).toBe(1)
    const cache = Array.from(xml.getElementsByTagNameNS(ns, 'numCache'))[0]!
    const points = Array.from(cache.getElementsByTagNameNS(ns, 'pt'))
    expect(points.map(point => [point.getAttribute('idx'), point.textContent])).toEqual([['0', '0'], ['2', '12.5']])
    expect(Object.keys(zip.files).filter(path => path.startsWith('word/embeddings/') && !zip.files[path]!.dir)).toHaveLength(1)
    expect(await zip.file('word/document.xml')!.async('string')).not.toContain('<w:tbl>')
  }
})
