import { html } from 'htm/preact'
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks'
import { artifactHtmlTextEditor, escapeArtifactHtmlText, selectedArtifactHtmlText } from '../../lib/artifact-html-text'
import { draftBase64, draftBytes, type ArtifactLiveSession, type ArtifactLiveState } from '../../lib/artifact-live-session'
import { replaceSharedSelection, resolveSharedSelection, restoreSharedDocument, selectSharedSource, sharedState } from '../../lib/artifact-shared-document'
import { artifactSentenceRecoveries, discardArtifactSentence, retainArtifactSentence, type ArtifactSentenceInput, type ArtifactSentenceRecovery } from '../../lib/artifact-sentence-recovery'
import { sameDraftTarget } from '../../api/artifact-draft-live'

type Sentence = ArtifactSentenceInput & { id: string; recoveredFrom: readonly string[] }

export function ArtifactHtmlEditor({ session, state, onPending }: {
  session: ArtifactLiveSession; state: ArtifactLiveState; onPending: (pending: boolean) => void;
}) {
  const frame = useRef<HTMLIFrameElement>(null)
  const [sentence, setSentence] = useState<Sentence | null>(null)
  const [message, setMessage] = useState('')
  const [persisted, setPersisted] = useState(true)
  const [recoveries, setRecoveries] = useState(() => artifactSentenceRecoveries(session.workspace, session.snapshot.view.draft.target.artifact_id))
  const applied = useRef(new Set<string>())
  const content = session.content
  const rendered = useMemo(() => {
    const editor = artifactHtmlTextEditor(content)
    const positions = editor.parts.map(part => selectSharedSource(session.doc, { anchor: part.start, head: part.end }))
    return { editor, positions }
  }, [session, content])
  const dirty = sentence !== null && sentence.input !== sentence.original
  const discard = (ids: readonly string[]) => {
    ids.forEach(discardArtifactSentence)
    setRecoveries(values => values.filter(record => !ids.includes(record.id)))
  }
  const preserve = (next: Sentence) => {
    if (next.input === next.original) { discard([next.id, ...next.recoveredFrom]); setPersisted(true); return }
    const record = retainArtifactSentence(next.id, session.workspace, session.snapshot.view.draft.target, next)
    setPersisted(record.persisted)
    if (record.persisted) discard(next.recoveredFrom)
  }
  const discardApplied = () => {
    if (applied.current.size === 0 || (session.snapshot.pending && !session.snapshot.recoveryPersisted)) return
    discard([...applied.current]); applied.current.clear()
  }
  useEffect(discardApplied, [state.pending, state.recoveryPersisted])
  useEffect(() => { onPending(dirty) }, [dirty, onPending])
  useEffect(() => () => { onPending(false); session.select(null) }, [onPending, session])
  useLayoutEffect(() => {
    const selected = (event: MessageEvent) => {
      if (event.source !== frame.current?.contentWindow) return
      const part = selectedArtifactHtmlText(rendered.editor, event.data)
      if (!part || (dirty && !window.confirm('아직 반영하지 않은 문장이 있습니다. 다른 문장을 열까요?'))) return
      const selection = rendered.positions[part.id]
      if (!selection) return
      if (sentence) discard([sentence.id, ...sentence.recoveredFrom])
      setSentence({ id: crypto.randomUUID(), recoveredFrom: [], expected: part.raw, original: part.text, selection, input: part.text,
        state: draftBase64(sharedState(session.doc)) }); setMessage('')
      session.select(resolveSharedSelection(session.doc, selection))
    }
    window.addEventListener('message', selected)
    return () => window.removeEventListener('message', selected)
  }, [session, rendered, dirty, sentence])
  useEffect(() => {
    if (!dirty) return
    const warn = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }
    window.addEventListener('beforeunload', warn)
    return () => window.removeEventListener('beforeunload', warn)
  }, [dirty])
  const apply = () => {
    if (!sentence || !dirty) return
    try {
      const selection = replaceSharedSelection(session.doc, sentence.selection, sentence.expected, escapeArtifactHtmlText(sentence.input))
      session.select(resolveSharedSelection(session.doc, selection))
      applied.current.add(sentence.id); sentence.recoveredFrom.forEach(id => applied.current.add(id))
      discardApplied()
      setSentence(null); setMessage('문장을 공유 원고에 반영했습니다.')
    } catch (error) { setMessage(error instanceof Error ? error.message : '문장을 반영하지 못했습니다.') }
  }
  const recover = (record: ArtifactSentenceRecovery) => {
    if (!sameDraftTarget(record.target, session.snapshot.view.draft.target)
      || (dirty && !window.confirm('입력 중인 문장을 닫고 복구 문장을 열까요?'))) return
    try {
      const state = draftBytes(record.state), checked = restoreSharedDocument(state)
      checked.destroy()
      if (sentence) discard([sentence.id, ...sentence.recoveredFrom].filter(id => id !== record.id))
      const next = { id: crypto.randomUUID(), recoveredFrom: [record.id], expected: record.expected, original: record.original,
        input: record.input, selection: record.selection, state: record.state }
      preserve(next); setSentence(next)
      session.recover(state)
      setMessage('선택 시점의 원고와 문장 입력을 복구했습니다. 문장을 확인한 뒤 반영해 주세요.')
    } catch (error) { setMessage(error instanceof Error ? error.message : '복구 원고를 읽지 못했습니다.') }
  }
  const download = (record: ArtifactSentenceRecovery) => {
    const url = URL.createObjectURL(new Blob([new TextEncoder().encode(record.input)], { type: 'text/plain;charset=utf-8' }))
    const anchor = document.createElement('a'); anchor.href = url; anchor.download = `artifact-sentence-${record.id}.txt`; anchor.click(); URL.revokeObjectURL(url)
  }
  return html`<section aria-label="HTML 문장 편집" class="flex min-h-0 flex-1 flex-col gap-3">
    <p class="m-0 text-sm">미리보기의 문장을 누르면 고칠 수 있습니다. 굵게 표시한 글처럼 서식이 나뉜 부분은 각각 선택해 주세요.</p>
    <p class="m-0 text-xs">입력한 문장은 ‘문장 반영’을 누르면 저장합니다. 편집 중에는 문서의 버튼·스크립트를 실행하지 않습니다.</p>
    ${!persisted && dirty ? html`<p role="alert">브라우저에 복구 문장을 저장하지 못했습니다. 이 탭을 닫기 전에 문장을 복사하거나 반영해 주세요.</p>` : null}
    ${recoveries.map(record => html`<details key=${record.id} class="border p-3">
      <summary>복구 문장 · ${new Date(record.at).toLocaleString()}</summary>
      <pre class="whitespace-pre-wrap">${record.input}</pre>
      <p>복구하면 선택 시점의 미전송 원고를 공유 원고에 합칩니다. 입력한 문장은 확인 후 따로 반영해 주세요.</p>
      <button type="button" onClick=${() => download(record)}>복구 문장 다운로드</button>
      <button type="button" disabled=${!sameDraftTarget(record.target, session.snapshot.view.draft.target)} onClick=${() => recover(record)}>선택 원고와 문장 입력 복구</button>
      ${!sameDraftTarget(record.target, session.snapshot.view.draft.target) ? html`<p>공유 원고의 세대가 달라 문장을 다운로드할 수만 있습니다.</p>` : null}
    </details>`)}
    <iframe ref=${frame} title="문장을 눌러 편집하는 미리보기" sandbox="allow-scripts" referrerPolicy="no-referrer"
      class="min-h-80 w-full flex-1 border bg-white" srcDoc=${rendered.editor.document} />
    ${sentence ? html`<form class="space-y-2 border p-3" onSubmit=${(event: Event) => { event.preventDefault(); apply() }}>
      <label class="block">선택한 문장
        <textarea aria-label="선택한 문장" class="mt-2 block min-h-24 w-full border bg-[var(--color-bg-surface)] p-2"
          value=${sentence.input} onInput=${(event: Event) => {
            const next = { ...sentence, input: (event.target as HTMLTextAreaElement).value }
            preserve(next); setSentence(next)
          }} />
      </label>
      <div class="flex gap-4">
        <button type="submit" disabled=${!dirty || state.connection !== 'connected'}>문장 반영</button>
        <button type="button" onClick=${() => {
          if (!dirty || window.confirm('아직 반영하지 않은 문장을 닫을까요?')) { discard([sentence.id, ...sentence.recoveredFrom]); setSentence(null); session.select(null) }
        }}>선택 닫기</button>
      </div>
    </form>` : null}
    ${message ? html`<p role="status">${message}</p>` : null}
  </section>`
}
