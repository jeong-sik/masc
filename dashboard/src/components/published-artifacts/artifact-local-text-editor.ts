import { html } from 'htm/preact'
import { useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks'
import { artifactHtmlTextEditor } from '../../lib/artifact-html-text'
import { downloadArtifactTextInput, replaceLocalArtifactText, selectLocalArtifactText, type ArtifactLocalTextInput } from '../../lib/artifact-local-text'
import { selectedArtifactText } from '../../lib/artifact-text-frame'

export function ArtifactLocalTextEditor({ content, projection, selection, disabled, isCurrent, onSelection, onApply }: {
  content: string; projection: object; selection: ArtifactLocalTextInput | null; disabled: boolean;
  isCurrent: () => boolean; onSelection: (selection: ArtifactLocalTextInput | null) => void; onApply: (content: string) => void;
}) {
  const frame = useRef<HTMLIFrameElement>(null)
  const rendered = useMemo(() => artifactHtmlTextEditor(content), [content])
  const [message, setMessage] = useState('')
  const dirty = selection !== null && selection.input !== selection.original
  useLayoutEffect(() => {
    const choose = (event: MessageEvent) => {
      if (disabled || !isCurrent() || event.source !== frame.current?.contentWindow) return
      const part = selectedArtifactText(rendered, event.data)
      if (!part || (dirty && !window.confirm('입력한 글을 버리고 다른 위치를 선택할까요?'))) return
      onSelection(selectLocalArtifactText(projection, part)); setMessage('')
    }
    window.addEventListener('message', choose)
    return () => window.removeEventListener('message', choose)
  }, [rendered, projection, disabled, dirty, isCurrent, onSelection])
  const apply = () => {
    if (!selection || disabled || !isCurrent()) return
    try { onApply(replaceLocalArtifactText(content, projection, selection)); setMessage('선택한 글을 원고에 반영했습니다.') }
    catch (error) { setMessage(error instanceof Error ? error.message : '글을 반영하지 못했습니다.') }
  }
  return html`<section aria-label="본문 화면 편집" class="space-y-3">
    <p class="text-sm">미리보기의 글·표 셀·차트 데이터 표를 눌러 고칠 수 있습니다. 입력한 뒤 ‘원고에 반영’을 눌러 주세요.</p>
    <iframe ref=${frame} title="글과 셀을 눌러 편집하는 미리보기" sandbox="allow-scripts" referrerPolicy="no-referrer"
      class="min-h-80 w-full border bg-white" srcDoc=${rendered.document} />
    ${selection ? html`<form class="space-y-2 border p-3" onSubmit=${(event: Event) => { event.preventDefault(); apply() }}>
      ${selection.projection !== projection ? html`<p role="alert">원본이 바뀌었습니다. 입력을 다운로드하거나 현재 위치를 다시 선택해 주세요.</p>` : null}
      <label class="block">선택한 글 또는 셀 값<textarea aria-label="선택한 글 또는 셀 값" value=${selection.input} disabled=${disabled}
        class="mt-2 block min-h-24 w-full border p-2 bg-[var(--color-bg-base)]"
        onInput=${(event: Event) => { if (!disabled && isCurrent()) onSelection({ ...selection, input: (event.target as HTMLTextAreaElement).value }) }} /></label>
      <div class="flex flex-wrap gap-4">
        <button type="submit" disabled=${disabled || !dirty}>원고에 반영</button>
        <button type="button" onClick=${() => downloadArtifactTextInput(selection)}>미반영 입력 다운로드</button>
        <button type="button" disabled=${disabled} onClick=${() => {
          if ((!dirty || window.confirm('아직 반영하지 않은 입력을 버릴까요?')) && isCurrent()) onSelection(null)
        }}>선택 취소</button>
      </div>
    </form>` : null}
    ${message ? html`<p role="status">${message}</p>` : null}
  </section>`
}
