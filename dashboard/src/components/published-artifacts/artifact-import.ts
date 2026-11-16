import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type { ArtifactDraft, ArtifactPublication, ArtifactWorkspace } from '../../api/published-artifacts'
import { ArtifactComposer, type ArtifactPublicationOutcome, type ArtifactDraftRetention, type ArtifactDraftSnapshot } from './artifact-composer'

type ReadFeedback = { kind: 'reading' } | { kind: 'message'; message: string }

export function ArtifactImport({ workspaceRoot, draftRetention, isCurrent, onMutation, onSaved, onCancel }: {
  workspaceRoot: string;
  draftRetention: ArtifactDraftRetention;
  isCurrent: () => boolean; onMutation: (outcome: ArtifactPublicationOutcome) => void;
  onSaved: (publication: ArtifactPublication, workspace: ArtifactWorkspace) => void; onCancel: () => void;
}) {
  const [draft, setDraft] = useState<ArtifactDraftSnapshot & { key: number } | null>(null)
  const [feedback, setFeedback] = useState<ReadFeedback>({ kind: 'message', message: '' })
  const message = feedback.kind === 'reading' ? '파일을 읽고 있습니다.' : feedback.message
  const setMessage = (message: string) => setFeedback({ kind: 'message', message })
  const reading = useRef(0)
  const active = useRef(true)
  const conversion = useRef<AbortController | null>(null)
  useEffect(() => {
    active.current = true
    return () => { active.current = false; reading.current++; conversion.current?.abort() }
  }, [workspaceRoot])
  const stopRead = () => {
    reading.current++
    conversion.current?.abort()
    conversion.current = null
  }
  const cancelRead = () => { stopRead(); setMessage('파일 가져오기를 취소했습니다.') }
  const close = () => { stopRead(); setMessage(''); onCancel() }
  const read = async (files: FileList | readonly File[] | null) => {
    if (!files || !isCurrent()) return
    const key = ++reading.current
    conversion.current?.abort()
    conversion.current = null
    const current = () => active.current && key === reading.current && isCurrent()
    if (files.length !== 1) { setMessage('문서 파일 하나를 선택해 주세요.'); return }
    const file = files[0]!
    const extension = file.name.split('.').at(-1)?.toLocaleLowerCase()
    if (!['html', 'htm', 'md', 'markdown', 'docx', 'hwpx', 'hwp'].includes(extension ?? '')) {
      setMessage('HWP, HWPX, DOCX, HTML 또는 Markdown 파일을 선택해 주세요. .doc 파일은 DOCX로 저장한 뒤 가져올 수 있습니다.'); return
    }
    setFeedback({ kind: 'reading' })
    try {
      let content: string, notices: readonly string[] = []
      if (extension === 'docx' || extension === 'hwpx' || extension === 'hwp') {
        const { officeImportLimits } = await import('../../lib/artifact-office-xml')
        if (!current()) return
        if (file.size > officeImportLimits.inputBytes) throw new Error('가져올 문서는 32 MiB 이하여야 합니다.')
        let result: { content: string; notices: readonly string[] }
        if (extension === 'hwp') {
          const { importArtifactHwp } = await import('../../lib/artifact-hwp-import')
          if (!current()) return
          const controller = new AbortController()
          conversion.current = controller
          const data = await file.arrayBuffer()
          if (!current()) return
          result = await importArtifactHwp(data, controller.signal)
        } else {
          const convert = extension === 'docx' ? (await import('../../lib/artifact-docx-import')).importArtifactDocx
            : (await import('../../lib/artifact-hwpx-import')).importArtifactHwpx
          if (!current()) return
          const data = await file.arrayBuffer()
          if (!current()) return
          result = await convert(data)
        }
        content = result.content; notices = result.notices
      } else {
        // Fatal decoding preserves the exact UTF-8 source, including its BOM.
        content = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(await file.arrayBuffer())
      }
      if (!current()) return
      conversion.current = null
      const snapshot = { key, identity: {}, value: { title: file.name, summary: `${file.name} 파일에서 가져온 문서입니다.`,
        content, format: extension === 'md' || extension === 'markdown' ? 'markdown' as const : 'html' as const } }
      if (draft) draftRetention.forget(draft.identity)
      draftRetention.remember(snapshot)
      setDraft(snapshot)
      setMessage('파일을 읽었습니다. 제목과 내용을 확인한 뒤 등록해 주세요. ' + notices.join(' '))
    } catch (error) {
      if (current()) {
        conversion.current = null
        setMessage(error instanceof Error ? error.message : '파일을 읽지 못했습니다.')
      }
    }
  }
  return html`<section aria-label="파일 가져오기" class="rounded-lg border border-[var(--color-border-default)]">
    ${draft ? null : html`<div class="space-y-3 p-6" onDragOver=${(event: DragEvent) => event.preventDefault()}
      onDrop=${(event: DragEvent) => { event.preventDefault(); void read(event.dataTransfer?.files ?? null) }}>
      <h2 class="m-0 text-lg">파일 가져오기</h2>
      <p>HWP, HWPX, DOCX, HTML 또는 Markdown 파일 하나를 여기에 놓거나 선택해 주세요.</p>
      <p>문서의 글·병합 표·차트 데이터를 가져옵니다. 원본의 글꼴과 페이지 배치는 달라질 수 있습니다.</p>
      <input type="file" aria-label="가져올 문서 파일" accept=".hwp,.hwpx,.docx,.html,.htm,.md,.markdown"
        onChange=${(event: Event) => {
          const input = event.currentTarget as HTMLInputElement, files = Array.from(input.files ?? [])
          input.value = ''
          void read(files)
        }} />
      ${feedback.kind === 'reading' ? html`<button type="button" onClick=${cancelRead}>가져오기 취소</button>` : null}
      <button type="button" onClick=${close}>닫기</button>
    </div>`}
    ${message ? html`<p role="status" class="px-6">${message}</p>` : null}
    ${draft ? html`<${ArtifactComposer} key=${draft.key} initial=${draft.value} workspaceRoot=${workspaceRoot} isCurrent=${isCurrent}
      onMutation=${onMutation} onDraftChange=${(value: ArtifactDraft) => draftRetention.remember({ ...draft, value })}
      onRelease=${() => draftRetention.release(draft.identity)}
      onSaved=${(publication: ArtifactPublication, workspace: ArtifactWorkspace) => { draftRetention.forget(draft.identity); onSaved(publication, workspace) }}
      onCancel=${() => { if (window.confirm('작성 중인 원고를 닫을까요? 저장하지 않은 내용은 사라집니다.')) { draftRetention.forget(draft.identity); onCancel() } }} />` : null}
  </section>`
}
