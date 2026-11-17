import parseCss from 'postcss/lib/parse'

export type OfficeTableWidth = { readonly kind: 'absent' }
  | { readonly kind: 'absolute'; readonly hwpUnits: number }
  | { readonly kind: 'percent'; readonly value: number }
  | { readonly kind: 'auto' }
  | { readonly kind: 'unsupported'; readonly value: string }
export type OfficeTableWidthCell = { readonly column: number; readonly columns: number; readonly width: OfficeTableWidth }
export type OfficeTableWidthResolution = { readonly kind: 'unique'; readonly widths: readonly number[] }
  | { readonly kind: 'partial' | 'conflicting'; readonly widths: readonly (number | null)[] }
type WidthSources = { readonly columns?: readonly OfficeTableWidth[]; readonly table?: OfficeTableWidth }
export type OfficeTableFixedLayout = { readonly width: number; readonly widths: readonly number[] }
type Edge = { readonly to: number; readonly width: number }
const hwpUnitsPerPoint = 100
const units: Readonly<Record<string, readonly [number, number]>> = {
  pt: [100, 1], px: [75, 1], pc: [1200, 1], in: [7200, 1], mm: [36000, 127], cm: [360000, 127],
}
const decimalPattern = /^([+]?)(?:(\d+)(?:\.(\d*))?|\.(\d+))(?:e([+-]?\d+))?$/i

// Normalize notation without expanding exponents or allocating a large integer.
function decimalKey(value: string): string | null {
  const match = decimalPattern.exec(value)
  if (!match) return null
  const exponent = Number(match[5] ?? '0'), fraction = match[3] ?? match[4] ?? ''
  if (!Number.isSafeInteger(exponent)) return null
  const digits = `${match[2] ?? ''}${fraction}`.replace(/^0+/, '')
  if (!digits) return '0'
  const significant = digits.replace(/0+$/, ''), power = exponent - fraction.length + digits.length - significant.length
  return Number.isSafeInteger(power) ? `${significant}e${power}` : null
}
function cssIdentifier(value: string): string {
  return value.replace(/\\(?:([a-f\d]{1,6})(?:\r\n|[\t\n\f\r ])?|([^\n\r\f]))/gi, (_escape, hex: string | undefined, character: string | undefined) => {
    if (hex === undefined) return character ?? ''
    const code = Number.parseInt(hex, 16)
    return code === 0 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff) ? '\uFFFD' : String.fromCodePoint(code)
  }).toLowerCase()
}
function widthValue(source: string, htmlAttribute: boolean): OfficeTableWidth {
  const value = source.trim()
  if (cssIdentifier(value) === 'auto' && !htmlAttribute) return { kind: 'auto' }
  // Decode only the dimension's unit identifier. Escaping a digit after the
  // numeric token starts a unit (1\\30 pt is unit "0pt"), not the number 10.
  const match = /^([+]?(?:\d*\.\d+|\d+)(?:e[+-]?\d+)?)([\s\S]*)$/i.exec(value)
  if (!match) return { kind: 'unsupported', value: source }
  const numberText = match[1]!, unit = match[2] ? cssIdentifier(match[2]) : (htmlAttribute ? 'px' : '')
  const key = decimalKey(numberText), number = Number(numberText)
  if (key === null || !Number.isFinite(number) || number < 0 || decimalKey(String(number)) !== key) return { kind: 'unsupported', value: source }
  if (unit === '%') return { kind: 'percent', value: number }
  const conversion = units[unit]
  if (!conversion) return unit === '' && number === 0 ? { kind: 'absolute', hwpUnits: 0 } : { kind: 'unsupported', value: source }
  const hwpUnits = Math.round(number * conversion[0] / conversion[1])
  if (!Number.isSafeInteger(hwpUnits) || decimalKey(String(hwpUnits * conversion[1] / conversion[0])) !== key) return { kind: 'unsupported', value: source }
  return { kind: 'absolute', hwpUnits }
}

/** Parse inline declarations with CSS syntax and cascade order, including !important.
 * map:false prevents source-map comments from reading a local file in Node. */
export function parseOfficeTableWidth(style: string | undefined, widthAttribute?: string): OfficeTableWidth {
  if (style !== undefined && style.trim() !== '') {
    const root = parseCss(`masc{${style}}`, { from: undefined, map: false })
    if (root.nodes.length !== 1 || root.first?.type !== 'rule' || root.first.selector !== 'masc') throw new Error('표의 inline CSS 선언을 읽을 수 없습니다.')
    let selected: { value: string; important: boolean } | undefined
    for (const node of root.first.nodes) {
      if (node.type === 'comment') continue
      if (node.type !== 'decl') throw new Error('표의 inline CSS에 선언 이외의 규칙이 있습니다.')
      if (cssIdentifier(node.prop) === 'width' && (!selected || !selected.important || node.important)) selected = { value: node.value, important: node.important }
    }
    if (selected) return widthValue(selected.value, false)
  }
  return widthAttribute === undefined ? { kind: 'absent' } : widthValue(widthAttribute, true)
}

/** Canonical declaration only; callers escape it when embedding an HTML attribute. */
export function officeTableWidthStyle(width: OfficeTableWidth): string {
  switch (width.kind) {
    case 'absent': return ''
    case 'auto': return 'width:auto'
    case 'unsupported': return `width:${width.value}`
    case 'percent':
      if (!Number.isFinite(width.value) || width.value < 0) throw new Error('표의 백분율 너비가 올바르지 않습니다.')
      return `width:${width.value}%`
    case 'absolute': {
      if (!Number.isSafeInteger(width.hwpUnits) || width.hwpUnits < 0) throw new Error('표의 절대 너비가 올바르지 않습니다.')
      const whole = Math.floor(width.hwpUnits / hwpUnitsPerPoint), fraction = width.hwpUnits % hwpUnitsPerPoint
      return `width:${whole}${fraction ? `.${String(fraction).padStart(2, '0').replace(/0$/, '')}` : ''}pt`
    }
  }
}

/** Only absolute, fully determined preferences can define fixed browser tracks.
 * Count observed boundaries before resolving: a few huge merged spans must not
 * allocate an array for every unobserved logical column. */
export function officeTableFixedLayout(columnCount: number, cells: readonly OfficeTableWidthCell[], options: WidthSources = {}, resolved?: OfficeTableWidthResolution): OfficeTableFixedLayout | null {
  const absolute = (width: OfficeTableWidth) => width.kind === 'absolute' || width.kind === 'absent'
  if ((options.table && !absolute(options.table)) || options.columns?.some(width => !absolute(width)) || cells.some(cell => !absolute(cell.width))) return null
  if (!Number.isSafeInteger(columnCount) || columnCount <= 0) throw new Error('표의 열 수가 올바르지 않습니다.')
  if (options.columns && options.columns.length > columnCount) throw new Error('표의 열 너비 개수가 열 수와 다릅니다.')
  let geometry = resolved
  if (!geometry) {
    const boundaries = new Set([0, columnCount])
    for (const cell of cells) {
      const end = cell.column + cell.columns
      if (!Number.isSafeInteger(cell.column) || !Number.isSafeInteger(end) || cell.column < 0 || end <= cell.column || end > columnCount) throw new Error('표의 셀 너비 구간이 올바르지 않습니다.')
      if (cell.width.kind === 'absolute') { boundaries.add(cell.column); boundaries.add(end) }
    }
    options.columns?.forEach((width, index) => { if (width.kind === 'absolute') { boundaries.add(index); boundaries.add(index + 1) } })
    if (boundaries.size !== columnCount + 1) return null
    const columns = options.columns && Array.from({ length: columnCount }, (_, index): OfficeTableWidth => options.columns![index] ?? { kind: 'absent' })
    geometry = resolveOfficeTableWidths(columnCount, cells, { ...options, columns })
  }
  if (geometry.kind !== 'unique' || geometry.widths.length !== columnCount) return null
  let total = 0
  for (const width of geometry.widths) {
    if (width <= 0 || !Number.isSafeInteger(width) || !Number.isSafeInteger(total + width)) return null
    total += width
  }
  return options.table?.kind === 'absolute' && options.table.hwpUnits !== total ? null : { width: total, widths: geometry.widths }
}

/** Cell widths alone are preferences under auto layout. Fixed tracks and zero
 * inter-cell spacing make the canonical absolute grid control browser layout. */
export function officeTableHtmlStyle(preferred: OfficeTableWidth, layout: OfficeTableFixedLayout | null): string {
  if (layout === null) return officeTableWidthStyle(preferred)
  return `${officeTableWidthStyle({ kind: 'absolute', hwpUnits: layout.width })};table-layout:fixed;border-collapse:collapse;border-spacing:0`
}

/** Derive exact boundary differences. A merged interval never invents its inner tracks.
 * Inconsistent source preferences remain distinct from a resolved output layout. */
export function resolveOfficeTableWidths(columnCount: number, cells: readonly OfficeTableWidthCell[], options: WidthSources = {}): OfficeTableWidthResolution {
  if (!Number.isSafeInteger(columnCount) || columnCount <= 0) throw new Error('표의 열 수가 올바르지 않습니다.')
  if (options.columns && options.columns.length !== columnCount) throw new Error('표의 열 너비 개수가 열 수와 다릅니다.')
  const edges: Edge[][] = Array.from({ length: columnCount + 1 }, () => [])
  function add(from: number, to: number, width: OfficeTableWidth): void {
    if (!Number.isSafeInteger(from) || !Number.isSafeInteger(to) || from < 0 || to <= from || to > columnCount) throw new Error('표의 셀 너비 구간이 올바르지 않습니다.')
    if (width.kind !== 'absolute') return
    if (!Number.isSafeInteger(width.hwpUnits) || width.hwpUnits < 0) throw new Error('표의 절대 너비가 올바르지 않습니다.')
    edges[from]!.push({ to, width: width.hwpUnits }); edges[to]!.push({ to: from, width: -width.hwpUnits })
  }
  if (options.table) add(0, columnCount, options.table)
  options.columns?.forEach((width, column) => add(column, column + 1, width))
  for (const cell of cells) add(cell.column, cell.column + cell.columns, cell.width)
  const owner = Array<number>(columnCount + 1).fill(-1), position = Array<number>(columnCount + 1).fill(0), conflicts = new Set<number>()
  let components = 0
  for (let root = 0; root <= columnCount; root++) {
    if (owner[root] !== -1) continue
    const component = components++, pending = [root]
    owner[root] = component
    for (let cursor = 0; cursor < pending.length; cursor++) {
      const from = pending[cursor]!
      for (const edge of edges[from]!) {
        const next = position[from]! + edge.width
        if (!Number.isSafeInteger(next)) { conflicts.add(component); continue }
        if (owner[edge.to] === -1) { owner[edge.to] = component; position[edge.to] = next; pending.push(edge.to) }
        else if (position[edge.to] !== next) conflicts.add(component)
      }
    }
  }
  const widths = Array.from({ length: columnCount }, (_, column) => {
    if (owner[column] !== owner[column + 1] || conflicts.has(owner[column]!)) return null
    const width = position[column + 1]! - position[column]!
    if (!Number.isSafeInteger(width) || width < 0) { conflicts.add(owner[column]!); return null }
    return width
  })
  if (conflicts.size) return { kind: 'conflicting', widths: widths.map((width, column) => conflicts.has(owner[column]!) ? null : width) }
  if (widths.every((width): width is number => width !== null)) return { kind: 'unique', widths }
  return { kind: 'partial', widths }
}
