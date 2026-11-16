import { defaultTreeAdapter as tree, html, type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import { checkOfficeText, officeHtmlText } from './artifact-office-text'

export type OfficeChartType = 'column' | 'bar' | 'line' | 'pie'
export type OfficeChart = {
  readonly title: string;
  readonly categories: readonly string[];
  readonly series: readonly { readonly name: string; readonly values: readonly (number | null)[]; readonly numberFormat?: string }[];
} & ({ readonly type: 'pie'; readonly emptyValues?: never; readonly valueFormat?: never }
  | { readonly type: 'column' | 'bar' | 'line'; readonly emptyValues?: 'gap' | 'zero' | 'connect'; readonly valueFormat?: string })
export const officeChartAttribute = 'data-masc-chart'
const categoryHeading = '항목'

export function officeChartType(value: string): OfficeChartType {
  switch (value) {
    case 'column': case 'bar': case 'line': case 'pie': return value
    default: throw new Error(`지원하지 않는 차트 종류입니다: ${value}`)
  }
}

function emptyValues(value: string): NonNullable<OfficeChart['emptyValues']> {
  switch (value) {
    case 'gap': case 'zero': case 'connect': return value
    default: throw new Error(`지원하지 않는 차트 결측치 표시입니다: ${value}`)
  }
}

export function officeNumber(value: string): number | null {
  if (value.trim() === '') return null
  if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(value.trim())) {
    throw new Error(`차트 값은 숫자 또는 빈 셀이어야 합니다: ${value}`)
  }
  const number = Number(value)
  if (!Number.isFinite(number) || (Number.isInteger(number) && !Number.isSafeInteger(number))) {
    throw new Error(`정확하게 옮길 수 없는 차트 숫자입니다: ${value}`)
  }
  // Compare decimal values, allowing only notation changes such as 0.10 -> 0.1.
  // A finite Number alone does not detect rounding or underflow to zero.
  const decimal = (source: string): string => {
    const match = /^([+-]?)(\d*(?:\.\d*)?)(?:[eE]([+-]?\d+))?$/.exec(source.trim())!
    const mantissa = match[2]!, point = mantissa.indexOf('.'), digits = mantissa.replace('.', '').replace(/^0+/, '')
    if (!digits || /^0+$/.test(digits)) return '0'
    const significant = digits.replace(/0+$/, '')
    const exponent = Number(match[3] ?? '0') - (point < 0 ? 0 : mantissa.length - point - 1) + digits.length - significant.length
    return `${match[1] === '-' ? '-' : ''}${significant}e${exponent}`
  }
  if (decimal(value) !== decimal(String(number))) throw new Error(`정확하게 옮길 수 없는 차트 숫자입니다: ${value}`)
  return number
}

export function checkOfficeChart(chart: OfficeChart): void {
  for (const value of [chart.title, ...chart.categories, ...(chart.valueFormat === undefined ? [] : [chart.valueFormat])]) checkOfficeText(value)
  if (chart.categories.length === 0 || chart.categories.some(category => !category.trim())) throw new Error('차트 항목 이름이 비어 있습니다.')
  if (chart.series.length === 0) throw new Error('차트 계열이 없습니다.')
  for (const series of chart.series) {
    checkOfficeText(series.name)
    if (series.numberFormat !== undefined) checkOfficeText(series.numberFormat)
    if (!series.name.trim()) throw new Error('차트 계열 이름이 비어 있습니다.')
    if (series.values.length !== chart.categories.length) throw new Error('차트 항목 수와 계열의 값 수가 다릅니다.')
    for (const value of series.values) {
      if (value !== null && (!Number.isFinite(value) || (Number.isInteger(value) && !Number.isSafeInteger(value)))) {
        throw new Error('정확하게 옮길 수 없는 차트 숫자입니다.')
      }
    }
  }
  if (chart.type === 'pie' && (chart.series.length !== 1 || chart.series[0]!.values.some(value => value !== null && value < 0))) {
    throw new Error('원형 차트에는 음수가 없는 계열 하나가 필요합니다.')
  }
}

function children(node: Nodes.ParentNode, tag: string): Nodes.Element[] {
  return node.childNodes.filter((child): child is Nodes.Element => tree.isElementNode(child) && child.tagName === tag)
}
function chartChildren(node: Nodes.ParentNode, allowed: readonly string[]): void {
  if (node.childNodes.some(child => tree.isElementNode(child)
    ? child.namespaceURI !== html.NS.HTML || !allowed.includes(child.tagName)
    : tree.isTextNode(child) && !!child.value.trim())) {
    throw new Error('차트 데이터 구조에 지원하지 않는 내용이 있습니다. 추가 설명은 figure 바깥의 문단에 넣어 주세요.')
  }
}
function text(node: Nodes.ChildNode): string {
  if (tree.isTextNode(node)) return node.value
  if (!tree.isElementNode(node)) return ''
  if (node.childNodes.some(child => tree.isElementNode(child))) throw new Error('차트 제목과 데이터 표에는 서식 없이 글자와 숫자만 넣어 주세요.')
  return node.childNodes.map(text).join('')
}

/** The table is the only stored authority for the chart's categories and values. */
export function officeChartFromFigure(node: Nodes.Element): OfficeChart | null {
  const kind = node.attrs.find(attr => attr.name === officeChartAttribute)
  if (!kind) return null
  if (node.tagName !== 'figure') throw new Error('차트 데이터는 figure 안에 넣어 주세요.')
  chartChildren(node, ['figcaption', 'table'])
  if (children(node, 'figcaption').length > 1) throw new Error('차트 제목은 하나만 넣어 주세요.')
  const type = officeChartType(kind.value), tables = children(node, 'table')
  if (tables.length !== 1) throw new Error('차트에는 데이터 표 하나가 필요합니다.')
  const table = tables[0]!
  chartChildren(table, ['tr', 'thead', 'tbody', 'tfoot'])
  for (const group of table.childNodes) if (tree.isElementNode(group) && group.tagName !== 'tr') chartChildren(group, ['tr'])
  const rows = table.childNodes.flatMap(child => tree.isElementNode(child)
    ? child.tagName === 'tr' ? [child] : ['thead', 'tbody', 'tfoot'].includes(child.tagName) ? children(child, 'tr') : []
    : [])
  const cells = rows.map(row => { chartChildren(row, ['th', 'td']); return row.childNodes.filter((child): child is Nodes.Element => tree.isElementNode(child)) })
  const header = cells[0]
  if (!header || header.length < 2 || !header.every(cell => cell.tagName === 'th')) throw new Error('차트 첫 행에 항목과 계열 이름을 넣어 주세요.')
  for (const row of cells) for (const cell of row) {
    if (cell.attrs.some(attr => ['rowspan', 'colspan'].includes(attr.name) && attr.value !== '1')) throw new Error('차트 데이터 표의 셀은 병합할 수 없습니다.')
  }
  const cellText = cells.map(row => row.map(cell => { const value = text(cell); checkOfficeText(value); return value }))
  if (cellText[0]![0] !== categoryHeading) throw new Error("차트 첫 열의 제목은 '항목'이어야 합니다. 단위와 설명은 차트 바깥에 적어 주세요.")
  const data = cellText.slice(1)
  if (data.some(row => row.length !== header.length)) throw new Error('차트 데이터 표의 열 수가 다릅니다.')
  const blankDisplay = node.attrs.find(attr => attr.name === 'data-masc-empty-values')?.value
  const valueFormat = node.attrs.find(attr => attr.name === 'data-masc-value-format')?.value
  if (type === 'pie' && (blankDisplay !== undefined || valueFormat !== undefined)) throw new Error('원형 차트에는 값 축과 결측치 표시를 지정할 수 없습니다.')
  const base = { title: children(node, 'figcaption').map(text).join(''),
    categories: data.map(row => row[0]!),
    series: header.slice(1).map((cell, index) => {
      const numberFormat = cell.attrs.find(attr => attr.name === 'data-masc-number-format')?.value
      const values = data.map(row => {
        return officeNumber(row[index + 1]!)
      })
      return { name: cellText[0]![index + 1]!, values, ...(numberFormat === undefined ? {} : { numberFormat }) }
    }) }
  const chart: OfficeChart = type === 'pie' ? { ...base, type } : { ...base, type,
    ...(blankDisplay === undefined ? {} : { emptyValues: emptyValues(blankDisplay) }), ...(valueFormat === undefined ? {} : { valueFormat }) }
  checkOfficeChart(chart)
  return chart
}

export function officeChartFigure(chart: OfficeChart): string {
  checkOfficeChart(chart)
  const header = `<th>${categoryHeading}</th>` + chart.series.map(series => `<th${series.numberFormat === undefined ? '' : ` data-masc-number-format="${officeHtmlText(series.numberFormat)}"`}>${officeHtmlText(series.name)}</th>`).join('')
  const rows = chart.categories.map((category, index) => `<tr><td>${officeHtmlText(category)}</td>${chart.series.map(series => `<td>${series.values[index] === null ? '' : String(series.values[index])}</td>`).join('')}</tr>`).join('')
  const metadata = `${chart.emptyValues === undefined ? '' : ` data-masc-empty-values="${chart.emptyValues}"`}${chart.valueFormat === undefined ? '' : ` data-masc-value-format="${officeHtmlText(chart.valueFormat)}"`}`
  return `<figure ${officeChartAttribute}="${chart.type}"${metadata}><figcaption>${officeHtmlText(chart.title)}</figcaption><table><thead><tr>${header}</tr></thead><tbody>${rows}</tbody></table></figure>`
}
