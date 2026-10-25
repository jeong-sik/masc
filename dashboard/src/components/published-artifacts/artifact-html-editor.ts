import { html } from 'htm/preact'
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks'
import { artifactHtmlTextEditor, escapeArtifactHtmlText, selectedArtifactHtmlText, type ArtifactHtmlText } from '../../lib/artifact-html-text'
import type { ArtifactLiveSession, ArtifactLiveState } from '../../lib/artifact-live-session'
import { replaceSharedSelection, resolveSharedSelection, selectSharedSource, type SharedSelection } from '../../lib/artifact-shared-document'

type Sentence = { part: ArtifactHtmlText; selection: SharedSelection; input: string }

export function ArtifactHtmlEditor({ session, state, onPending }: {
  session: ArtifactLiveSession; state: ArtifactLiveState; onPending: (pending: boolean) => void;
}) {
  const frame = useRef<HTMLIFrameElement>(null)
  const [sentence, setSentence] = useState<Sentence | null>(null)
  const [message, setMessage] = useState('')
  const content = session.content
  const rendered = useMemo(() => {
    const editor = artifactHtmlTextEditor(content)
    const positions = editor.parts.map(part => selectSharedSource(session.doc, { anchor: part.start, head: part.end }))
    return { editor, positions }
  }, [session, content])
  const dirty = sentence !== null && sentence.input !== sentence.part.text
  useEffect(() => { onPending(dirty) }, [dirty, onPending])
  useEffect(() => () => { onPending(false); session.select(null) }, [onPending, session])
  useLayoutEffect(() => {
    const selected = (event: MessageEvent) => {
      if (event.source !== frame.current?.contentWindow) return
      const part = selectedArtifactHtmlText(rendered.editor, event.data)
      if (!part || (dirty && !window.confirm('아직 반영하지 않은 문장이 있습니다. 다른 문장을 열까요?'))) return
      const selection = rendered.positions[part.id]
      if (!selection) return
      setSentence({ part, selection, input: part.text }); setMessage('')
      session.select(resolveSharedSelection(session.doc, selection))
    }
    window.addEventListener('message', selected)
    return () => window.removeEventListener('message', selected)
  }, [session, rendered, dirty])
  useEffect(() => {
    if (!dirty) return
    const warn = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }
    window.addEventListener('beforeunload', warn)
    return () => window.removeEventListener('beforeunload', warn)
  }, [dirty])
  const apply = () => {
    if (!sentence || !dirty) return
    try {
      const selection = replaceSharedSelection(session.doc, sentence.selection, sentence.part.raw, escapeArtifactHtmlText(sentence.input))
      session.select(resolveSharedSelection(session.doc, selection))
      setSentence(null); setMessage('문장을 공유 원고에 반영했습니다.')
    } catch (error) { setMessage(error instanceof Error ? error.message : '문장을 반영하지 못했습니다.') }
  }
  return html`<section aria-label="HTML 문장 편집" class="flex min-h-0 flex-1 flex-col gap-3">
    <p class="m-0 text-sm">미리보기의 문장을 누르면 고칠 수 있습니다. 굵게 표시한 글처럼 서식이 나뉜 부분은 각각 선택해 주세요.</p>
    <p class="m-0 text-xs">입력한 문장은 ‘문장 반영’을 누르면 저장합니다. 편집 중에는 문서의 버튼·스크립트를 실행하지 않습니다.</p>
    <iframe ref=${frame} title="문장을 눌러 편집하는 미리보기" sandbox="allow-scripts" referrerPolicy="no-referrer"
      class="min-h-80 w-full flex-1 border bg-white" srcDoc=${rendered.editor.document} />
    ${sentence ? html`<form class="space-y-2 border p-3" onSubmit=${(event: Event) => { event.preventDefault(); apply() }}>
      <label class="block">선택한 문장
        <textarea aria-label="선택한 문장" class="mt-2 block min-h-24 w-full border bg-[var(--color-bg-surface)] p-2"
          value=${sentence.input} onInput=${(event: Event) => setSentence(value => value && ({ ...value, input: (event.target as HTMLTextAreaElement).value }))} />
      </label>
      <div class="flex gap-4">
        <button type="submit" disabled=${!dirty || state.connection !== 'connected'}>문장 반영</button>
        <button type="button" onClick=${() => {
          if (!dirty || window.confirm('아직 반영하지 않은 문장을 닫을까요?')) { setSentence(null); session.select(null) }
        }}>선택 닫기</button>
      </div>
    </form>` : null}
    ${message ? html`<p role="status">${message}</p>` : null}
  </section>`
}
