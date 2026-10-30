import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type { ArtifactDraft, ArtifactPublication, ArtifactWorkspace } from '../../api/published-artifacts'
import { ArtifactComposer, type ArtifactPublicationOutcome, type ArtifactDraftRetention, type ArtifactDraftSnapshot } from './artifact-composer'

export function ArtifactImport({ workspaceRoot, draftRetention, isCurrent, onMutation, onSaved, onCancel }: {
  workspaceRoot: string;
  draftRetention: ArtifactDraftRetention;
  isCurrent: () => boolean; onMutation: (outcome: ArtifactPublicationOutcome) => void;
  onSaved: (publication: ArtifactPublication, workspace: ArtifactWorkspace) => void; onCancel: () => void;
}) {
  const [draft, setDraft] = useState<ArtifactDraftSnapshot & { key: number } | null>(null)
  const [message, setMessage] = useState('')
  const reading = useRef(0)
  const active = useRef(true)
  useEffect(() => () => { active.current = false; reading.current++ }, [])
  const read = async (files: FileList | readonly File[] | null) => {
    if (!files || !isCurrent()) return
    const key = ++reading.current
    if (files.length !== 1) { setMessage('문서 파일 하나를 선택해 주세요.'); return }
    const file = files[0]!
    const extension = file.name.split('.').at(-1)?.toLocaleLowerCase()
    if (extension !== 'html' && extension !== 'htm' && extension !== 'md' && extension !== 'markdown') {
      setMessage('HTML 또는 Markdown 파일을 선택해 주세요.'); return
    }
    setMessage('파일을 읽고 있습니다.')
    try {
      // Fatal decoding refuses a non-UTF-8 file rather than publishing replacement
      // characters. ignoreBOM preserves a source BOM in the exact stored body.
      const content = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(await file.arrayBuffer())
      if (!active.current || key !== reading.current || !isCurrent()) return
      const snapshot = { key, identity: {}, value: { title: file.name, summary: `${file.name} 파일에서 가져온 문서입니다.`,
        content, format: extension === 'html' || extension === 'htm' ? 'html' as const : 'markdown' as const } }
      if (draft) draftRetention.forget(draft.identity)
      draftRetention.remember(snapshot)
      setDraft(snapshot)
      setMessage('파일을 읽었습니다. 제목과 내용을 확인한 뒤 등록해 주세요.')
    } catch (error) {
      if (active.current && key === reading.current && isCurrent()) {
        setMessage(error instanceof Error ? error.message : '파일을 읽지 못했습니다.')
      }
    }
  }
  return html`<section aria-label="파일 가져오기" class="rounded-lg border border-[var(--color-border-default)]">
    ${draft ? null : html`<div class="space-y-3 p-6" onDragOver=${(event: DragEvent) => event.preventDefault()}
      onDrop=${(event: DragEvent) => { event.preventDefault(); void read(event.dataTransfer?.files ?? null) }}>
      <h2 class="m-0 text-lg">파일 가져오기</h2>
      <p>HTML이나 Markdown 파일 하나를 여기에 놓거나 선택해 주세요.</p>
      <input type="file" aria-label="가져올 문서 파일" accept=".html,.htm,.md,.markdown"
        onChange=${(event: Event) => { void read((event.target as HTMLInputElement).files) }} />
      <button type="button" onClick=${onCancel}>닫기</button>
    </div>`}
    ${message ? html`<p role="status" class="px-6">${message}</p>` : null}
    ${draft ? html`<${ArtifactComposer} key=${draft.key} initial=${draft.value} workspaceRoot=${workspaceRoot} isCurrent=${isCurrent}
      onMutation=${onMutation} onDraftChange=${(value: ArtifactDraft) => draftRetention.remember({ ...draft, value })}
      onSaved=${(publication: ArtifactPublication, workspace: ArtifactWorkspace) => { draftRetention.forget(draft.identity); onSaved(publication, workspace) }}
      onCancel=${() => { if (window.confirm('작성 중인 원고를 닫을까요? 저장하지 않은 내용은 사라집니다.')) { draftRetention.forget(draft.identity); onCancel() } }} />` : null}
  </section>`
}
