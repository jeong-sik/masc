import type JSZip from 'jszip'
import { checkOfficeChart, officeNumber, type OfficeChart, type OfficeChartType } from './artifact-office-chart'
import { loadOfficeArchive, officeNs as ns, readOfficeBytes, readOfficeRelationships, readOfficeXml, resolveOfficePart,
  xmlChild, xmlChildren, xmlDescendants, type OfficeXmlElement as Element } from './artifact-office-xml'

type Reference = { readonly formula: string; readonly values: readonly (string | null)[]; readonly numeric: boolean }
type CachedData = { readonly values: readonly (string | null)[]; readonly numeric: boolean; readonly numberFormat?: string }
const relationType = (name: string) => `${ns.relationships}/${name}`
function one(node: Element, name: string): Element {
  const found = xmlChildren(node, ns.chart, name)
  if (found.length !== 1) throw new Error(`차트의 ${name} 요소가 없거나 겹칩니다.`)
  return found[0]!
}
function index(value: string | null): number {
  if (value === null || !/^(0|[1-9]\d*)$/.test(value) || !Number.isSafeInteger(Number(value))) throw new Error('차트 데이터 인덱스가 올바르지 않습니다.')
  return Number(value)
}
function data(node: Element, references: Reference[], expected?: number): CachedData {
  const alternatives = xmlChildren(node, ns.chart).filter(child => child.localName !== null && ['strRef', 'numRef', 'strLit', 'numLit'].includes(child.localName))
  if (alternatives.length !== 1) throw new Error('차트 데이터의 저장 형식을 읽을 수 없습니다.')
  const source = alternatives[0]!, numeric = source.localName === 'numRef' || source.localName === 'numLit'
  const referenced = source.localName === 'strRef' || source.localName === 'numRef'
  const cache = referenced ? one(source, numeric ? 'numCache' : 'strCache') : source
  const count = index(one(cache, 'ptCount').getAttribute('val')), points = xmlChildren(cache, ns.chart, 'pt')
  // Category/string counts are bounded by actual XML points before allocation.
  if ((expected !== undefined && count !== expected) || (expected === undefined && count !== points.length)) throw new Error('차트 항목 수와 저장된 데이터 수가 다릅니다.')
  const values: (string | null)[] = Array.from({ length: count }, () => null), seen = new Set<number>()
  for (const point of points) {
    const at = index(point.getAttribute('idx'))
    if (at >= count || seen.has(at)) throw new Error('차트 데이터 인덱스가 겹치거나 범위를 벗어났습니다.')
    seen.add(at); values[at] = one(point, 'v').textContent ?? ''
    if (numeric) officeNumber(values[at]!)
  }
  if (referenced) {
    const formula = one(source, 'f').textContent
    if (!formula?.trim()) throw new Error('차트 원본 데이터 참조가 비어 있습니다.')
    references.push({ formula, values, numeric })
  }
  const format = xmlChildren(cache, ns.chart, 'formatCode')
  if (format.length > 1) throw new Error('차트 숫자 서식이 겹칩니다.')
  return { values, numeric, numberFormat: format[0]?.textContent ?? undefined }
}
function labels(cached: CachedData): string[] {
  return cached.values.map(value => {
    if (value === null || value.trim() === '') throw new Error('차트 항목 또는 계열 이름이 비어 있습니다.')
    return cached.numeric ? String(officeNumber(value)) : value
  })
}
function chartKind(plot: Element): { node: Element; type: OfficeChartType } {
  const charts: Element[] = []
  for (const child of xmlChildren(plot, ns.chart)) {
    switch (child.localName) {
      case 'barChart': case 'lineChart': case 'pieChart': charts.push(child); break
      case 'layout': case 'catAx': case 'valAx': case 'spPr': case 'dTable': break
      default: throw new Error(`지원하지 않는 차트 구조입니다: ${child.localName}`)
    }
  }
  if (charts.length !== 1) throw new Error('혼합 차트는 가져올 수 없습니다.')
  const node = charts[0]!
  const grouping = xmlChildren(node, ns.chart, 'grouping')
  if (grouping.length > 1 || (grouping[0] && !['standard', 'clustered'].includes(grouping[0].getAttribute('val') ?? ''))) throw new Error('누적 차트는 가져올 수 없습니다.')
  let type: OfficeChartType
  if (node.localName === 'lineChart') type = 'line'
  else if (node.localName === 'pieChart') type = 'pie'
  else {
    const direction = one(node, 'barDir').getAttribute('val')
    if (direction !== 'col' && direction !== 'bar') throw new Error('막대 차트의 방향을 읽을 수 없습니다.')
    type = direction === 'col' ? 'column' : 'bar'
  }
  const categories = xmlChildren(plot, ns.chart, 'catAx'), values = xmlChildren(plot, ns.chart, 'valAx'), axes = [...categories, ...values]
  const ids = xmlChildren(node, ns.chart, 'axId').map(axis => oneValue(axis))
  const axisIds = axes.map(axis => oneValue(one(axis, 'axId')))
  if (type === 'pie' ? axes.length !== 0 || ids.length !== 0 : categories.length !== 1 || values.length !== 1 || ids.length !== 2 || new Set(ids).size !== 2
    || new Set(axisIds).size !== 2 || axisIds.some(id => !ids.includes(id))) throw new Error('보조축 또는 알 수 없는 축의 차트는 가져올 수 없습니다.')
  if (axes.some(axis => { const scaling = xmlChild(axis, ns.chart, 'scaling'); return scaling && xmlChild(scaling, ns.chart, 'logBase') })) throw new Error('로그 축의 차트는 가져올 수 없습니다.')
  return { node, type }
}
function oneValue(node: Element): string {
  const value = node.getAttribute('val')
  if (value === null || value === '') throw new Error('차트 필수 속성이 없습니다.')
  return value
}

/** Read DrawingML values; linked workbooks must agree with every referenced cache. */
export async function readOfficeChart(zip: JSZip, path: string): Promise<OfficeChart> {
  const document = await readOfficeXml(zip, path), root = document.documentElement!
  if (root.namespaceURI !== ns.chart || root.localName !== 'chartSpace') throw new Error('표준 DrawingML 차트 파일이 아닙니다.')
  const chartNode = one(root, 'chart'), plot = one(chartNode, 'plotArea'), { node, type } = chartKind(plot), references: Reference[] = []
  const titleNodes = xmlChildren(chartNode, ns.chart, 'title')
  if (titleNodes.length > 1) throw new Error('차트 제목이 겹칩니다.')
  let title = ''
  if (titleNodes[0]) {
    const text = xmlChildren(titleNodes[0], ns.chart, 'tx')
    if (text.length > 1) throw new Error('차트 제목의 글자가 겹칩니다.')
    if (text[0]) {
      if (xmlChildren(text[0]).length !== 1) throw new Error('차트 제목의 저장 형식이 겹칩니다.')
      const rich = xmlChildren(text[0], ns.chart, 'rich')
      if (rich.length > 1) throw new Error('차트 제목의 서식이 겹칩니다.')
      if (rich.length === 1) title = xmlChildren(rich[0]!, ns.drawing, 'p').map(paragraph => xmlDescendants(paragraph, ns.drawing, 't').map(text => text.textContent ?? '').join('')).join('\n')
      else title = labels(data(text[0], references, 1))[0]!
    }
  }
  const nodes = xmlChildren(node, ns.chart, 'ser').map(series => ({ series, order: index(one(series, 'order').getAttribute('val')), id: index(one(series, 'idx').getAttribute('val')) })).sort((a, b) => a.order - b.order)
  if (new Set(nodes.map(series => series.order)).size !== nodes.length || new Set(nodes.map(series => series.id)).size !== nodes.length) throw new Error('차트 계열의 순서 또는 인덱스가 겹칩니다.')
  let categories: string[] | undefined
  const series = nodes.map(({ series: entry }) => {
    if (xmlChildren(entry, ns.chart, 'trendline').length || xmlChildren(entry, ns.chart, 'errBars').length) throw new Error('추세선 또는 오차 막대가 있는 차트는 가져올 수 없습니다.')
    const current = labels(data(one(entry, 'cat'), references))
    if (categories && (categories.length !== current.length || categories.some((label, at) => label !== current[at]))) throw new Error('계열마다 차트 항목이 다릅니다.')
    categories = current
    const tx = one(entry, 'tx'), literal = xmlChildren(tx, ns.chart, 'v')
    if (literal.length === 1 && xmlChildren(tx).length !== 1) throw new Error('차트 계열 이름의 저장 형식이 겹칩니다.')
    const name = literal.length === 1 ? literal[0]!.textContent ?? '' : labels(data(tx, references, 1))[0]!
    const values = data(one(entry, 'val'), references, current.length)
    if (!values.numeric) throw new Error('차트 값이 숫자로 저장되지 않았습니다.')
    return { name, values: values.values.map(value => value === null ? null : officeNumber(value)), numberFormat: values.numberFormat }
  })
  const blanks = xmlChildren(chartNode, ns.chart, 'dispBlanksAs')
  if (blanks.length > 1) throw new Error('차트 결측치 설정이 겹칩니다.')
  let emptyValues: 'gap' | 'zero' | 'connect' | undefined
  if (blanks[0]) {
    switch (oneValue(blanks[0])) {
      case 'gap': emptyValues = 'gap'; break
      case 'zero': emptyValues = 'zero'; break
      case 'span': emptyValues = 'connect'; break
      default: throw new Error('차트 결측치 표시 방법을 읽을 수 없습니다.')
    }
  }
  const axisFormats = xmlChildren(plot, ns.chart, 'valAx').flatMap(axis => xmlChildren(axis, ns.chart, 'numFmt'))
  if (axisFormats.length > 1) throw new Error('차트 숫자 축 서식이 겹칩니다.')
  const common = { title, categories: categories ?? [], series }
  const chart: OfficeChart = type === 'pie' ? { ...common, type } : { ...common, type, emptyValues, valueFormat: axisFormats[0]?.getAttribute('formatCode') ?? undefined }
  checkOfficeChart(chart)
  const sources = xmlChildren(root, ns.chart, 'externalData')
  if (sources.length > 1) throw new Error('차트 원본 워크북 참조가 겹칩니다.')
  if (sources[0]) await verifyWorkbook(zip, path, sources[0], references)
  return chart
}

type CellValue = string | number | null
const excelMaxRows = 1048576, excelMaxColumns = 16384
function address(value: string): { column: number; row: number } {
  const match = /^\$?([A-Z]+)\$?([1-9]\d*)$/.exec(value)
  if (!match) throw new Error('차트 원본 셀 주소가 올바르지 않습니다.')
  const column = Array.from(match[1]!).reduce((total, letter) => total * 26 + letter.charCodeAt(0) - 64, 0), row = Number(match[2])
  if (column > excelMaxColumns || row > excelMaxRows) throw new Error('차트 원본 셀 주소가 Excel 범위를 벗어났습니다.')
  return { column, row }
}
function cellName(column: number, row: number): string {
  let name = ''
  for (let at = column; at > 0; at = Math.floor((at - 1) / 26)) name = String.fromCharCode(65 + (at - 1) % 26) + name
  return `${name}${row}`
}
async function verifyWorkbook(outer: JSZip, chartPath: string, source: Element, references: readonly Reference[]): Promise<void> {
  const relationship = (await readOfficeRelationships(outer, chartPath)).get(source.getAttributeNS(ns.relationships, 'id') ?? '')
  if (!relationship || relationship.external || relationship.type !== relationType('package')) throw new Error('차트 외부 원본을 읽거나 원본 참조를 확인할 수 없습니다.')
  const workbookZip = await loadOfficeArchive(await readOfficeBytes(outer, resolveOfficePart(chartPath, relationship.target)), outer)
  const entry = [...(await readOfficeRelationships(workbookZip, '')).values()].filter(relation => relation.type === relationType('officeDocument'))
  if (entry.length !== 1 || entry[0]!.external) throw new Error('차트 내장 워크북의 시작 파일을 읽을 수 없습니다.')
  const path = resolveOfficePart('', entry[0]!.target), workbook = await readOfficeXml(workbookZip, path), relationships = await readOfficeRelationships(workbookZip, path)
  if (workbook.documentElement?.namespaceURI !== ns.spreadsheet || workbook.documentElement.localName !== 'workbook') throw new Error('차트 원본 워크북이 올바르지 않습니다.')
  const stringsRelation = [...relationships.values()].find(relation => relation.type === relationType('sharedStrings'))
  if (stringsRelation?.external) throw new Error('차트의 외부 문자열 파일은 읽을 수 없습니다.')
  const strings = stringsRelation ? xmlDescendants(await readOfficeXml(workbookZip, resolveOfficePart(path, stringsRelation.target)), ns.spreadsheet, 'si').map(si => xmlDescendants(si, ns.spreadsheet, 't').map(text => text.textContent ?? '').join('')) : []
  const sheets = new Map<string, Map<string, Element>>()
  for (const sheet of xmlDescendants(workbook, ns.spreadsheet, 'sheet')) {
    const name = sheet.getAttribute('name'), relation = relationships.get(sheet.getAttributeNS(ns.relationships, 'id') ?? '')
    if (!name || sheets.has(name) || !relation || relation.external || relation.type !== relationType('worksheet')) throw new Error('차트 원본 워크시트를 확인할 수 없습니다.')
    const xml = await readOfficeXml(workbookZip, resolveOfficePart(path, relation.target)), cells = new Map<string, Element>()
    if (xml.documentElement?.namespaceURI !== ns.spreadsheet || xml.documentElement.localName !== 'worksheet') throw new Error('차트 원본 워크시트가 올바르지 않습니다.')
    for (const cell of xmlDescendants(xml, ns.spreadsheet, 'c')) {
      const ref = cell.getAttribute('r')
      if (!ref || cells.has(ref)) throw new Error('차트 원본 셀 주소가 없거나 겹칩니다.')
      cells.set(ref, cell)
    }
    sheets.set(name, cells)
  }
  function cellValue(cell: Element | undefined): CellValue {
    if (!cell) return null
    if (xmlChild(cell, ns.spreadsheet, 'f')) throw new Error('수식 계산 결과의 최신성을 확인할 수 없는 차트는 가져올 수 없습니다.')
    const value = xmlChild(cell, ns.spreadsheet, 'v')?.textContent
    switch (cell.getAttribute('t')) {
      case 'inlineStr': return xmlDescendants(cell, ns.spreadsheet, 't').map(text => text.textContent ?? '').join('')
      case 's': {
        const at = index(value ?? null)
        if (at >= strings.length) throw new Error('차트 원본 문자열 참조가 범위를 벗어났습니다.')
        return strings[at]!
      }
      case 'str': return value ?? ''
      case null: case '': case 'n': return value === undefined || value === null ? null : officeNumber(value)
      default: throw new Error('차트 원본 셀의 데이터 형식을 읽을 수 없습니다.')
    }
  }
  for (const reference of references) {
    const formula = /^(?:'((?:[^']|'')+)'|([^'!\[\]:]+))!(\$?[A-Z]+\$?[1-9]\d*)(?::(\$?[A-Z]+\$?[1-9]\d*))?$/.exec(reference.formula)
    if (!formula) throw new Error('차트 원본 데이터의 수식 범위를 읽을 수 없습니다.')
    const cells = sheets.get(formula[1]?.replaceAll("''", "'") ?? formula[2]!), start = address(formula[3]!), end = address(formula[4] ?? formula[3]!)
    const count = Math.max(end.column - start.column, end.row - start.row) + 1
    if (!cells || end.column < start.column || end.row < start.row || (end.column !== start.column && end.row !== start.row) || count !== reference.values.length) throw new Error('차트 원본 데이터 범위와 캐시의 항목 수가 다릅니다.')
    reference.values.forEach((cached, at) => {
      const value = cellValue(cells.get(cellName(start.column + (end.column === start.column ? 0 : at), start.row + (end.row === start.row ? 0 : at))))
      const expected = cached === null ? null : reference.numeric ? officeNumber(cached) : cached
      if (reference.numeric ? value !== expected : value === null ? expected !== null : String(value) !== expected) throw new Error('차트 표시 데이터와 내장 워크북 값이 다릅니다. 원본 프로그램에서 저장한 뒤 다시 가져와 주세요.')
    })
  }
}
