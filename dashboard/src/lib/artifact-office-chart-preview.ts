import { defaultTreeAdapter as tree, parseFragment, type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import { officeChartAttribute, officeChartFromFigure, type OfficeChart } from './artifact-office-chart'
import { officeHtmlText } from './artifact-office-text'

const width = 640, height = 360, left = 72, top = 24, plotWidth = 540, plotHeight = 240
const labelSize = 12
const palette = ['#2563eb', '#059669', '#d97706', '#9333ea', '#dc2626', '#0891b2']
const colour = (index: number): string => palette[index % palette.length]!
const label = (x: number, y: number, value: string, anchor = 'middle'): string =>
  `<text x="${x}" y="${y}" text-anchor="${anchor}" font-size="${labelSize}" fill="#1f2937">${officeHtmlText(value)}</text>`

function chartSvg(chart: OfficeChart): string {
  const viewWidth = chart.type === 'pie' ? plotHeight + top * 2 : width
  const viewHeight = chart.type === 'pie' ? plotHeight + top * 2 : height
  let low = 0, high = 0
  for (const series of chart.series) for (const value of series.values) if (value !== null) { low = Math.min(low, value); high = Math.max(high, value) }
  const extent = high === low ? 1 : high - low
  const y = (value: number): number => top + plotHeight * (high - value) / extent
  const x = (value: number): number => left + plotWidth * (value - low) / extent
  const count = chart.categories.length, seriesCount = chart.series.length, shapes: string[] = []
  if (chart.type === 'pie') {
    const values = chart.series[0]!.values, total = values.reduce<number>((sum, value) => sum + (value ?? 0), 0)
    if (!Number.isFinite(total)) throw new Error('차트 합계가 표현 가능한 숫자 범위를 넘습니다.')
    const cx = viewWidth / 2, cy = top + plotHeight / 2, radius = plotHeight / 2
    let angle = -Math.PI / 2
    values.forEach((value, index) => {
      if (value === null || value === 0 || total === 0) return
      const next = angle + value / total * Math.PI * 2
      const title = `<title>${officeHtmlText(chart.categories[index]!)}: ${value}</title>`
      if (value === total) shapes.push(`<circle cx="${cx}" cy="${cy}" r="${radius}" fill="${colour(index)}">${title}</circle>`)
      else shapes.push(`<path d="M${cx},${cy} L${cx + radius * Math.cos(angle)},${cy + radius * Math.sin(angle)} A${radius},${radius} 0 ${next - angle > Math.PI ? 1 : 0},1 ${cx + radius * Math.cos(next)},${cy + radius * Math.sin(next)} Z" fill="${colour(index)}">${title}</path>`)
      angle = next
    })
  } else if (chart.type === 'bar') {
    const band = plotHeight / count, bar = band * 0.8 / seriesCount
    chart.series.forEach((series, seriesIndex) => series.values.forEach((value, index) => {
      if (value === null) return
      shapes.push(`<rect x="${Math.min(x(0), x(value))}" y="${top + band * index + band * 0.1 + bar * seriesIndex}" width="${Math.abs(x(value) - x(0))}" height="${bar}" fill="${colour(seriesIndex)}"><title>${officeHtmlText(series.name)}: ${value}</title></rect>`)
    }))
    chart.categories.forEach((category, index) => shapes.push(label(left - 8, top + band * (index + 0.5), category, 'end')))
  } else {
    const band = plotWidth / count, bar = band * 0.8 / seriesCount
    chart.series.forEach((series, seriesIndex) => {
      let path = '', connected = false
      series.values.forEach((original, index) => {
        const value = original === null && chart.emptyValues === 'zero' ? 0 : original
        if (value === null) { if (chart.emptyValues !== 'connect') connected = false; return }
        const pointX = left + band * (index + 0.5)
        if (chart.type === 'column') shapes.push(`<rect x="${left + band * index + band * 0.1 + bar * seriesIndex}" y="${Math.min(y(0), y(value))}" width="${bar}" height="${Math.abs(y(value) - y(0))}" fill="${colour(seriesIndex)}"><title>${officeHtmlText(series.name)}: ${value}</title></rect>`)
        else {
          path += `${connected ? 'L' : 'M'}${pointX},${y(value)} `; connected = true
          shapes.push(`<circle cx="${pointX}" cy="${y(value)}" r="3" fill="${colour(seriesIndex)}"><title>${officeHtmlText(series.name)}: ${value}</title></circle>`)
        }
      })
      if (path) shapes.push(`<path d="${path}" fill="none" stroke="${colour(seriesIndex)}" stroke-width="2"/>`)
    })
    chart.categories.forEach((category, index) => shapes.push(label(left + band * (index + 0.5), top + plotHeight + 18, category)))
  }
  const legend = chart.type === 'pie' ? chart.categories : chart.series.map(series => series.name)
  const legendY = top + plotHeight + 44
  if (chart.type !== 'pie') legend.forEach((name, index) => shapes.push(label(left + index * plotWidth / legend.length, legendY, name, 'start')))
  const axis = chart.type === 'pie' ? '' : `<path d="M${left},${top}V${top + plotHeight}H${left + plotWidth}" fill="none" stroke="#9ca3af"/>`
  const minimumWidth = chart.type === 'pie' ? '' : `min-width:${width}px;`
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${viewWidth} ${viewHeight}" role="img" aria-label="${officeHtmlText(chart.title || '차트')}" style="display:block;width:100%;${minimumWidth}max-height:24rem"><title>${officeHtmlText(chart.title || '차트')}</title>${axis}${shapes.join('')}</svg>`
}

function previews(document: Nodes.Document): { node: Nodes.Element; markup: string }[] {
  const output: { node: Nodes.Element; markup: string }[] = []
  const visit = (parent: Nodes.ParentNode): void => {
    for (const node of parent.childNodes) if (tree.isElementNode(node)) {
      if (node.tagName === 'figure' && node.attrs.some(attr => attr.name === officeChartAttribute)) {
        try {
          const chart = officeChartFromFigure(node)
          if (chart) {
            const legend = chart.type === 'pie' ? `<div style="display:flex;flex-wrap:wrap;gap:.5em 1em;font:${labelSize}px sans-serif;color:#1f2937">${chart.categories.map((name, index) => `<span style="display:inline-flex;align-items:center;gap:.5em"><span aria-hidden="true" style="display:inline-block;width:.75em;height:.75em;background:${colour(index)}"></span>${officeHtmlText(name)}</span>`).join('')}</div>` : ''
            output.push({ node, markup: `<div style="max-width:100%;overflow-x:auto">${chartSvg(chart)}</div>${legend}` })
          }
        }
        catch (error) { output.push({ node, markup: `<p role="alert">${officeHtmlText(error instanceof Error ? error.message : '차트 데이터를 읽지 못했습니다.')}</p>` }) }
      } else visit(node)
    }
  }
  visit(document)
  return output
}

/** Insertions apply only to a rendering; the original source remains unchanged. */
export function officeChartPreviewInsertions(document: Nodes.Document): { at: number; text: string }[] {
  return previews(document).flatMap(({ node, markup }) => node.sourceCodeLocation?.startTag
    ? [{ at: node.sourceCodeLocation.startTag.endOffset, text: markup }] : [])
}

/** Add projections before text bindings are generated from the original source locations. */
export function addOfficeChartPreviews(document: Nodes.Document): void {
  for (const { node, markup } of previews(document)) {
    const first = node.childNodes[0]
    for (const child of [...parseFragment(markup).childNodes]) {
      tree.detachNode(child)
      if (first) tree.insertBefore(node, child, first); else tree.appendChild(node, child)
    }
  }
}
