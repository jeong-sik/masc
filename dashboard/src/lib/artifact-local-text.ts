import { replaceArtifactHtmlText, type ArtifactHtmlTextEdit } from './artifact-html-text-replacement'
import type { ArtifactTextPart } from './artifact-text-frame'

// This is an unapplied selection form, never a second document or wire field.
export type ArtifactLocalTextInput = ArtifactHtmlTextEdit & Readonly<{ projection: object; original: string }>

export function selectLocalArtifactText(projection: object, part: ArtifactTextPart): ArtifactLocalTextInput {
  return { projection, start: part.start, end: part.end, expected: part.raw, original: part.text, input: part.text }
}

export function replaceLocalArtifactText(content: string, projection: object, selection: ArtifactLocalTextInput): string {
  if (projection !== selection.projection) {
    throw new Error('원본이 바뀌었습니다. 입력은 보관했습니다. 현재 위치를 다시 선택해 주세요.')
  }
  return replaceArtifactHtmlText(content, selection).content
}

export function downloadArtifactTextInput(selection: ArtifactLocalTextInput): void {
  const url = URL.createObjectURL(new Blob([new TextEncoder().encode(selection.input)], { type: 'text/plain;charset=utf-8' }))
  try {
    const anchor = document.createElement('a')
    anchor.href = url; anchor.download = 'artifact-unapplied-text.txt'; anchor.click()
  } finally { URL.revokeObjectURL(url) }
}
