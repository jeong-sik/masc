import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { currentStoredTokenRevision } from '../../api/core'
import { fetchPublishedArtifact, type PublishedArtifact, type ArtifactDocument } from '../../api/published-artifacts'
import { artifactHtmlDocument } from './artifact-reader'

type Preview = { key: string; kind: 'ready'; document: ArtifactDocument }
  | { key: string; kind: 'error'; message: string }

// Mounted only by an explicit preview action. Inventory refresh never reads
// every body or executes the reports' scripts in the background.
export function ArtifactPreview({ artifact, authRevision }: {
  artifact: PublishedArtifact; authRevision: number
}) {
  const key = JSON.stringify([authRevision, artifact.id, artifact.revision])
  const [result, setResult] = useState<Preview | null>(null)
  useEffect(() => {
    const controller = new AbortController()
    void fetchPublishedArtifact(artifact.id, String(artifact.revision), controller.signal).then(document => {
      if (!controller.signal.aborted && currentStoredTokenRevision() === authRevision) {
        setResult({ key, kind: 'ready', document })
      }
    }, error => {
      if (!controller.signal.aborted && currentStoredTokenRevision() === authRevision) {
        setResult({ key, kind: 'error', message: error instanceof Error ? error.message : '미리보기를 불러오지 못했습니다.' })
      }
    })
    return () => controller.abort()
  }, [key, artifact.id, artifact.revision, authRevision])
  const current = result?.key === key ? result : null
  if (!current) return html`<p role="status" class="p-3 text-sm">미리보기를 불러오고 있습니다.</p>`
  if (current.kind === 'error') return html`<p role="alert" class="p-3 text-sm">${current.message}</p>`
  return html`
    <figure class="m-0 border-t border-[var(--color-border-default)]">
      <iframe title=${`${artifact.title} 빠른 미리보기`} sandbox="" referrerPolicy="no-referrer" tabIndex=${-1}
        class="pointer-events-none h-64 w-full border-0 bg-white"
        srcDoc=${artifactHtmlDocument(current.document.content, false)} />
      <figcaption class="p-2 text-xs text-[var(--color-fg-muted)]">HTML · 이미지 포함 미리보기 · 전체 화면에서 상호작용할 수 있습니다.</figcaption>
    </figure>`
}
