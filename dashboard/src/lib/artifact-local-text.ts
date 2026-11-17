import { defaultTreeAdapter as tree, parse, type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import { escapeArtifactHtmlText } from './artifact-html-text'
import { officeChartAttribute, officeChartFromFigure } from './artifact-office-chart'
import { checkOfficeText } from './artifact-office-text'
import type { ArtifactTextPart } from './artifact-text-frame'

// This is an unapplied selection form, never a second document or wire field.
export type ArtifactLocalTextInput = Readonly<{
  projection: object; start: number; end: number; expected: string; original: string; input: string;
}>

export function selectLocalArtifactText(projection: object, part: ArtifactTextPart): ArtifactLocalTextInput {
  return { projection, start: part.start, end: part.end, expected: part.raw, original: part.text, input: part.text }
}

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

export function replaceLocalArtifactText(content: string, projection: object, selection: ArtifactLocalTextInput): string {
  if (projection !== selection.projection || selection.start < 0 || selection.end < selection.start
    || selection.end > content.length || content.slice(selection.start, selection.end) !== selection.expected) {
    throw new Error('원본이 바뀌었습니다. 입력은 보관했습니다. 현재 위치를 다시 선택해 주세요.')
  }
  checkOfficeText(selection.input)
  const touched = charts(content).filter(node => {
    const location = node.sourceCodeLocation
    return location && location.startOffset <= selection.start && location.endOffset >= selection.end
  })
  const result = content.slice(0, selection.start) + escapeArtifactHtmlText(selection.input) + content.slice(selection.end)
  if (touched.length) {
    const candidates = charts(result)
    for (const original of touched) {
      const candidate = candidates.find(node => node.sourceCodeLocation?.startOffset === original.sourceCodeLocation!.startOffset)
      if (!candidate) throw new Error('선택한 차트를 현재 원고에서 찾지 못했습니다.')
      // The existing chart parser validates exact numbers, blanks and metadata.
      officeChartFromFigure(candidate)
    }
  }
  return result
}

export function downloadArtifactTextInput(selection: ArtifactLocalTextInput): void {
  const url = URL.createObjectURL(new Blob([new TextEncoder().encode(selection.input)], { type: 'text/plain;charset=utf-8' }))
  try {
    const anchor = document.createElement('a')
    anchor.href = url; anchor.download = 'artifact-unapplied-text.txt'; anchor.click()
  } finally { URL.revokeObjectURL(url) }
}
