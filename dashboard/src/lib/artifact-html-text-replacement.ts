import { defaultTreeAdapter as tree, parse, type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import { escapeArtifactHtmlText } from './artifact-html-text'
import { officeChartAttribute, officeChartFromFigure } from './artifact-office-chart'
import { checkOfficeText } from './artifact-office-text'

export type ArtifactHtmlTextEdit = Readonly<{ start: number; end: number; expected: string; input: string }>

function charts(source: string): Nodes.Element[] {
  const result: Nodes.Element[] = []
  const visit = (parent: Nodes.ParentNode) => {
    for (const node of parent.childNodes) if (tree.isElementNode(node)) {
      if (node.attrs.some(attr => attr.name === officeChartAttribute)) result.push(node)
      visit(node)
    }
  }
  visit(parse(source, { sourceCodeLocationInfo: true }))
  return result
}

// Prepare one visual text edit before a local draft or shared Y.Text is changed.
// Raw source edits do not use this HTML-specific operation.
export function replaceArtifactHtmlText(content: string, edit: ArtifactHtmlTextEdit): Readonly<{ content: string; replacement: string }> {
  if (!Number.isSafeInteger(edit.start) || !Number.isSafeInteger(edit.end) || edit.start < 0 || edit.end < edit.start
    || edit.end > content.length || content.slice(edit.start, edit.end) !== edit.expected) {
    throw new Error('선택한 내용이 바뀌었습니다. 현재 내용을 읽고 다시 편집해 주세요.')
  }
  checkOfficeText(edit.input)
  const touched = charts(content).filter(node => {
    const location = node.sourceCodeLocation
    return location && location.startOffset <= edit.start && location.endOffset >= edit.end
  })
  const replacement = escapeArtifactHtmlText(edit.input)
  const result = content.slice(0, edit.start) + replacement + content.slice(edit.end)
  if (touched.length) {
    const candidates = charts(result)
    for (const original of touched) {
      const candidate = candidates.find(node => node.sourceCodeLocation?.startOffset === original.sourceCodeLocation!.startOffset)
      if (!candidate) throw new Error('선택한 차트를 현재 원고에서 찾지 못했습니다.')
      // The same parser checks exact numbers, blanks and chart metadata in both editors.
      officeChartFromFigure(candidate)
    }
  }
  return { content: result, replacement }
}
